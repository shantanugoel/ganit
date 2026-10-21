import AppKit
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol

public struct SheetSuggestionConfiguration: Sendable {
  public let coordinator: SuggestionCoordinator
  public let settings: AssistantSettings
  public init(coordinator: SuggestionCoordinator, settings: AssistantSettings) {
    self.coordinator = coordinator
    self.settings = settings
  }
}

/// UI state is temporary. Only Apply can change the document source.
@MainActor
package final class SheetSuggestionSession {
  private weak var editor: SheetEditorViewController?
  private let document = UUID()
  private var revision = 0
  private var task: Task<Void, Never>?
  private var job: SuggestionJob?
  private var configuration: SheetSuggestionConfiguration?
  private var snapshot: AssistanceSnapshot?
  private var target: [LineID]?
  private var taskNotes: [String] = []
  private var retry = false
  private var userRevisedInputs = false
  package var didChange: () -> Void = {}
  package private(set) var isVisible = false
  package private(set) var instruction = ""
  package private(set) var state: SuggestionJobState = .idle
  package private(set) var message = ""
  package private(set) var preview: AssistanceCheckedCandidate?
  package private(set) var proposals: [AssistanceCheckedCandidate] = []
  package private(set) var clarification: SuggestionClarification?
  package private(set) var requestedContext: [AssistanceSymbol] = []
  package private(set) var requestBodies: [Data] = []
  package private(set) var preparedBody: Data?
  package private(set) var choices: [String: String] = [:]
  package private(set) var assumptions: Set<String> = []
  private var included: Set<String> = []
  private var selected: SuggestionCandidate?
  package var canSend: Bool { state == .idle && snapshot != nil && preparedBody != nil }
  package var canApply: Bool { state == .ready && preview?.isApplicable == true }
  package var availableChoices: [AssistanceChoice] {
    proposals.first { $0.candidate.id == selected?.id }?.choices ?? []
  }
  package var isRunning: Bool {
    [.preparing, .requesting, .repairing, .checking, .needsContext].contains(state)
  }

  package init(editor: SheetEditorViewController) { self.editor = editor }

  /// Opens the Ask bar on a target. `instruction` is what the reader typed; it
  /// travels as a task note, so the model reads it and Ganit never parses it.
  /// `autoSend` is the ⏎ path: prepare the scope and send it in one gesture.
  package func prepare(retry: Bool = false, instruction: String = "", autoSend: Bool = false) {
    dismiss()
    self.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    taskNotes = self.instruction.isEmpty ? [] : [self.instruction]
    included = []
    choices = [:]
    assumptions = []
    proposals = []
    preview = nil
    selected = nil
    clarification = nil
    requestedContext = []
    requestBodies = []
    preparedBody = nil
    self.retry = retry
    userRevisedInputs = false
    isVisible = true
    guard let editor, let configuration = editor.suggestionConfiguration,
      configuration.settings.isReady
    else {
      update(.failed, localized("ask.noProvider", "Set up a provider in Assistant settings."))
      return
    }
    // An explicit request commits the composition before taking a snapshot.
    if editor.textView.hasMarkedText() { editor.textView.unmarkText() }
    guard !editor.textView.hasMarkedText(), let target = editor.suggestionTargets else {
      update(
        .failed,
        localized(
          "ask.badTarget",
          "Select complete source lines. Table targets need a separate scope."))
      return
    }
    self.configuration = configuration
    self.target = target
    update(.preparing, localized("ask.preparing", "Read the lines you selected."))
    let version = revision
    task = Task { [weak self] in
      do {
        var snapshot = try await editor.suggestionSnapshot(targets: target)
        for note in self?.taskNotes ?? [] { snapshot = try snapshot.addingTaskNote(note) }
        guard let self, self.revision == version, snapshot.source.text == editor.sheet.text else {
          return
        }
        self.snapshot = snapshot
        self.preparedBody = try SuggestionWireRequest(
          settings: configuration.settings, context: snapshot.permittedContext()
        ).body
        if autoSend {
          // send() only accepts an idle job, so the scope has to be reported ready
          // first even when nobody will see the intermediate state.
          self.update(.idle, Self.contextSummary(snapshot, model: configuration.settings.model))
          self.send()
          return
        }
        self.update(.idle, Self.contextSummary(snapshot, model: configuration.settings.model))
      } catch {
        guard let self, self.revision == version else { return }
        self.update(
          .failed,
          localized(
            "ask.tooLarge",
            "That is too much for one Ask. Select fewer lines and try again."))
      }
    }
  }

  /// Names what is about to leave the Mac, in the same words the disclosure uses.
  /// Every specifier is positional: one that is not, sitting after ones that are,
  /// reuses the previous argument and reads an `Int` as an object.
  private static func contextSummary(_ snapshot: AssistanceSnapshot, model: String) -> String {
    String(
      format: localized(
        "ask.ready",
        "Ready to send %1$d line(s), %2$d source record(s), and these calculation settings to %3$@. Open Context to see them."
      ),
      snapshot.targetLines.count, snapshot.inventory.filter(\.matchesTarget).count, model)
  }

  /// Only this explicit action grants permission for the frozen context.
  package func send() {
    guard canSend, let configuration, let snapshot, let editor,
      snapshot.source.text == editor.sheet.text
    else { return }
    let version = revision
    preparedBody = nil
    update(.requesting, localized("ask.requesting", "Ganit is asking…"))
    task = Task { [weak self] in
      let job = await configuration.coordinator.start(
        SuggestionJobInput(
          document: self?.document ?? UUID(), snapshot: snapshot,
          settings: configuration.settings,
          permission: SuggestionPermission(contextAccepted: true),
          includedRecords: self?.included ?? [], choices: self?.choices ?? [:],
          approvedAssumptions: self?.assumptions ?? [], retry: self?.retry ?? false,
          userRevisedInputs: self?.userRevisedInputs ?? false),
        observer: { [weak self] event in await self?.receive(event, version: version) })
      guard let self, self.revision == version else {
        await configuration.coordinator.cancel(job.id)
        return
      }
      self.job = job
      let outcome = await job.result.value
      guard self.revision == version, self.snapshot?.source.text == self.editor?.sheet.text else {
        return
      }
      self.job = nil
      switch outcome {
      case .proposal(let candidates):
        self.proposals = candidates
        self.selectProposal(0)
      case .clarify(let value):
        self.clarification = value
        self.update(.needsChoice, value.question)
      case .unsupported(let reason): self.update(.failed, reason)
      case .failed(let failure): self.update(.failed, Self.failureMessage(failure))
      case .paused: self.update(.paused, localized("ask.paused", "Ask is paused."))
      case .stale:
        self.update(
          .stale, localized("ask.stale", "The sheet changed under this proposal. Ask again."))
      case .cancelled: self.update(.cancelled, localized("ask.stopped", "Ask stopped."))
      case .dismissed: self.dismiss()
      }
    }
  }

  private func receive(_ event: SuggestionJobEvent, version: Int) {
    guard revision == version, isVisible else { return }
    switch event {
    case .state(let state): self.state = state
    case .requestBody(let body): requestBodies.append(body)
    case .includeContext(let records, let reason):
      requestedContext = records
      message = reason
    }
    didChange()
  }

  package func includeContext() {
    guard state == .needsContext, let job, let configuration else { return }
    let handles = Set(requestedContext.map(\.handle))
    included.formUnion(handles)
    requestedContext = []
    update(.repairing, localized("ask.includingContext", "Sending the records you included."))
    Task { await configuration.coordinator.includeContext(job: job.id, handles: handles) }
  }

  package func selectProposal(_ index: Int) {
    guard proposals.indices.contains(index) else { return }
    selected = proposals[index].candidate
    preview = proposals[index]
    choices = [:]
    assumptions = []
    update(
      preview!.isApplicable ? .ready : .needsChoice, Self.checkedMessage)
  }

  package func choose(_ id: String, option: String) {
    choices[id] = option
    recheck()
  }

  package func approve(_ id: String, approved: Bool) {
    if approved { assumptions.insert(id) } else { assumptions.remove(id) }
    recheck()
  }

  private func recheck() {
    guard let editor, let scheduler = editor.scheduler, let snapshot, let selected else { return }
    task?.cancel()
    revision += 1
    let version = revision
    update(.checking, localized("ask.checking", "Ganit is checking…"))
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await scheduler.checkSuggestion(
          selected, snapshot: snapshot,
          handles: self.included, choices: self.choices, assumptions: self.assumptions,
          userRevisedInputs: self.userRevisedInputs)
        guard self.revision == version else { return }
        self.preview = result
        self.update(result.isApplicable ? .ready : .needsChoice, Self.checkedMessage)
      } catch {
        guard self.revision == version else { return }
        self.preview = nil
        self.update(
          .needsChoice,
          localized(
            "ask.choiceUnsatisfied",
            "This expression does not satisfy that choice. Change the words and ask again."))
      }
    }
  }

  package func submitClarification(_ answer: String, revisesInputs: Bool = false) {
    guard let editor, let target, let configuration, clarification != nil,
      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    revision += 1
    let version = revision
    clarification = nil
    taskNotes.append(answer)
    userRevisedInputs = userRevisedInputs || revisesInputs
    update(.preparing, localized("ask.preparingRevised", "Preparing the revised Ask."))
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var snapshot = try await editor.suggestionSnapshot(targets: target)
        for note in self.taskNotes { snapshot = try snapshot.addingTaskNote(note) }
        guard self.revision == version, snapshot.source.text == editor.sheet.text else { return }
        self.snapshot = snapshot
        self.preparedBody = try SuggestionWireRequest(
          settings: configuration.settings,
          context: SuggestionRequestContext.data(
            snapshot: snapshot, including: self.included,
            choices: self.choices, userRevisedInputs: self.userRevisedInputs)
        ).body
        self.update(
          .idle,
          Self.contextSummary(snapshot, model: configuration.settings.model)
            + " "
            + localized("ask.reviewNote", "Your added words are listed in Context."))
      } catch {
        guard self.revision == version else { return }
        self.update(
          .failed,
          localized("ask.revisedTooLarge", "That revised Ask is too large, or the sheet changed."))
      }
    }
  }

  package func apply() {
    guard canApply, let editor, let scheduler = editor.scheduler,
      let target, let selected, let original = snapshot
    else { return }
    let version = revision
    update(.checking, localized("ask.checkingBeforeApply", "Ganit is checking the sheet again…"))
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var fresh = try await editor.suggestionSnapshot(targets: target)
        guard original.source.text == fresh.source.text else {
          self.invalidate()
          return
        }
        for note in self.taskNotes { fresh = try fresh.addingTaskNote(note) }
        let edit = try await scheduler.prepareSuggestion(
          selected, snapshot: fresh,
          handles: self.included, choices: self.choices, assumptions: self.assumptions,
          userRevisedInputs: self.userRevisedInputs)
        guard self.revision == version, fresh.source.text == editor.sheet.text,
          !editor.textView.hasMarkedText()
        else { return }
        if let old = self.preview, old.result != edit.checked.result {
          self.snapshot = fresh
          self.preview = edit.checked
          self.update(
            edit.checked.isApplicable ? .ready : .needsChoice,
            localized(
              "ask.previewChanged",
              "The local preview changed. Review the current result before Apply."))
          return
        }
        try editor.applySuggestionEdit(edit)
        self.isVisible = false
        self.update(.applied, localized("ask.applied", "Applied."))
      } catch {
        guard self.revision == version else { return }
        self.update(
          .stale,
          localized(
            "ask.applyStale",
            "This proposal no longer passes the local checks. Ask again."))
      }
    }
  }

  package func editRequest() {
    guard let editor, let target,
      let first = editor.sheet.lines.first(where: { $0.id == target.first }),
      let last = editor.sheet.lines.first(where: { $0.id == target.last })
    else {
      dismiss()
      return
    }
    let text = editor.sheet.text
    let lower = text.utf8.index(text.utf8.startIndex, offsetBy: first.range.lowerBound)
    let upper = text.utf8.index(text.utf8.startIndex, offsetBy: last.range.upperBound)
    dismiss()
    editor.textView.setSelectedRange(NSRange(lower..<upper, in: text))
    editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
    editor.view.window?.makeFirstResponder(editor.textView)
  }

  package func invalidate() {
    revision += 1
    task?.cancel()
    if let job, let configuration {
      job.cancel()
      Task { await configuration.coordinator.cancel(job.id) }
    }
    job = nil
    snapshot = nil
    preparedBody = nil
    preview = nil
    proposals = []
    clarification = nil
    requestedContext = []
    if isVisible {
      update(.stale, localized("ask.stale", "The sheet changed under this proposal. Ask again."))
    }
  }

  package func dismiss() {
    invalidate()
    isVisible = false
    update(.dismissed, "")
  }

  package func waitUntilIdle() async {
    while let current = task {
      await current.value
      if current == task { return }
    }
  }

  private func update(_ state: SuggestionJobState, _ message: String) {
    self.state = state
    self.message = message
    didChange()
  }

  private static var checkedMessage: String {
    localized("ask.checked", "Ganit checked these lines. Review them before Apply.")
  }

  private static func failureMessage(_ failure: SuggestionJobFailure) -> String {
    switch failure {
    case .deadline:
      localized("ask.failed.deadline", "That took too long. Ask again or ask about fewer lines.")
    case .providerBusy:
      localized("ask.failed.busy", "Another Ask is already running for this provider.")
    case .providerNotReady:
      localized("ask.noProvider", "Set up a provider in Assistant settings.")
    case .permissionRequired:
      localized("ask.failed.permission", "Review what would be sent before sending it.")
    case .contextLimit:
      localized("ask.failed.contextLimit", "That is too much for one Ask. Select fewer lines.")
    case .contextDenied:
      localized("ask.failed.contextDenied", "The extra source records were not included.")
    case .requestLimit:
      localized(
        "ask.failed.requestLimit", "Ganit asked the model to fix its answer too many times.")
    case .repeatedCandidate:
      localized(
        "ask.failed.repeated", "The model gave the same answer that Ganit already rejected.")
    case .repeatedFailure:
      localized(
        "ask.failed.repeatedFailure", "The model kept giving an answer Ganit could not use.")
    case .validation:
      localized(
        "ask.failed.validation",
        "The model did not answer in a way Ganit could use. Try different words.")
    case .transport:
      localized("ask.failed.transport", "Ganit could not reach the provider.")
    case .schema:
      localized("ask.failed.schema", "The reply was not something Ganit could read.")
    }
  }
}
