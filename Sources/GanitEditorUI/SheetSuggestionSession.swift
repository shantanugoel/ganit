import AppKit
import GanitAssistance
import GanitData
import GanitEngine
import GanitFormatting
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
  private var invalidationTask: Task<Void, Never>?
  private var revision = 0
  private var task: Task<Void, Never>?
  private var job: SuggestionJob?
  private var configuration: SheetSuggestionConfiguration?
  private var snapshot: AssistanceSnapshot?
  private var target: [LineID]?
  private var taskNotes: [String] = []
  private var retry = false
  private(set) var forceModel = false
  private(set) var allowsExplanation = false
  /// True when the reader's own words were a question Ganit could not answer.
  private(set) var allowsExplanationRequested = false
  private var userRevisedInputs = false
  package var didChange: () -> Void = {}
  package private(set) var isVisible = false
  package private(set) var instruction = ""
  package private(set) var continuousAsk = UUID()
  package private(set) var clarificationCount = 0
  package var originalWording: String {
    instruction.isEmpty ? snapshot?.targetText ?? "" : instruction
  }
  package private(set) var state: SuggestionJobState = .idle
  package private(set) var message = ""
  package private(set) var failure: AskFailure?
  package private(set) var rejectedSource: String?
  package private(set) var rejection: AssistanceValidationFailure?
  package private(set) var automaticRepairs = 0
  package var repairNotice: String? {
    guard automaticRepairs > 0 else { return nil }
    return localized("ask.repairNotice", "Ganit asked the model to fix its first attempt.")
  }
  package var checkedFooter: String {
    guard automaticRepairs > 0 else { return Self.checkedMessage }
    return String(
      format: automaticRepairs == 1
        ? localized("ask.checkedOneRepair", "Ganit checked these lines · %1$d automatic repair")
        : localized("ask.checkedRepairs", "Ganit checked these lines · %1$d automatic repairs"),
      automaticRepairs)
  }
  package var rejectedInspection: String? {
    rejectedSource.map {
      localized("ask.rejectedInspection", "Ganit rejected this reply. It cannot be applied.")
        + "\n\n" + $0
    }
  }
  package var nativeFunctionAlternatives: [String] {
    guard let failure, case .rejectedByEngine(let validation) = failure,
      case .evaluationFailure(let error) = validation.engineResult,
      error.code == .unknownFunction,
      rejectedSource?.lowercased().contains("mortgage") == true
    else { return [] }
    // Use only names in the catalog that was sent for this job.
    guard let body = requestBodies.first,
      let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let messages = payload["messages"] as? [[String: Any]],
      let text = messages.last?["content"] as? String,
      let data = text.data(using: .utf8),
      let context = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let catalog = context["catalog"] as? [String: Any],
      let functions = catalog["functions"] as? [[String: Any]]
    else { return [] }
    let names = Set(functions.compactMap { $0["name"] as? String })
    return ["pmt", "fv", "pv"].filter { names.contains($0) }
  }
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
  package private(set) var omittedLines: Set<Int> = []
  package var proposalLines: [String] {
    guard let selected, let snapshot else { return [] }
    let rows = SheetSource(selected.edits[0].replacement).lines
    return (0..<max(rows.count, snapshot.targetLines.count)).map { index in
      rows.indices.contains(index)
        ? rows[index].text
        : localized("ask.removeLine", "Remove: ") + snapshot.targetLines[index].text
    }
  }
  package var checkedLines: [(source: String, result: EngineValue?)] {
    guard let preview, let snapshot,
      let start = preview.evaluation.lines.firstIndex(where: { $0.id == snapshot.target.id })
    else { return [] }
    let rows = SheetSource(preview.candidate.edits[0].replacement).lines
    return rows.enumerated().map { index, row in
      let result = preview.evaluation.lines[start + index].result
      if case .value(let value) = result { return (row.text, value) }
      return (row.text, nil)
    }
  }
  package var canSend: Bool { state == .idle && snapshot != nil && preparedBody != nil }
  package var canApply: Bool { state == .ready && preview?.isApplicable == true }
  package var availableChoices: [AssistanceChoice] {
    preview?.choices ?? []
  }
  package var isRunning: Bool {
    [.preparing, .requesting, .repairing, .checking, .needsContext].contains(state)
  }

  package init(editor: SheetEditorViewController) { self.editor = editor }

  /// Opens the Ask bar on a target. `instruction` is what the reader typed; it
  /// travels as a task note, so the model reads it and Ganit never parses it.
  /// `autoSend` is the ⏎ path: prepare the scope and send it in one gesture.
  package func prepare(
    retry: Bool = false, instruction: String = "", autoSend: Bool = false,
    forceModel: Bool = false, allowsExplanation: Bool = false
  ) {
    guard editor?.suggestionConfiguration?.settings.isReady == true else {
      dismiss()
      return
    }
    var allowsExplanation = allowsExplanation
    var forceModel = forceModel
    var askedForExplanation = false
    if autoSend && !forceModel,
      SheetEditorViewController.isLocalExplanationQuestion(instruction)
    {
      switch editor?.showLocalExplanation(instruction: instruction) ?? .unavailable {
      case .shown:
        return
      case .pending:
        // The card would be drawn from a stale evaluation and a request would
        // be a guess, so neither happens: the reader asks again when asked to.
        dismiss()
        self.instruction = instruction
        isVisible = true
        update(
          .failed,
          localized(
            "ask.explanation.wait",
            "Ganit cannot explain this line yet. Wait for calculation to finish, then ask again."))
        return
      case .unavailable:
        // Ganit has nothing to say about this target. The reader asked a
        // question, so the model may answer it in prose.
        askedForExplanation = true
        allowsExplanation = true
        forceModel = true
      }
    }
    let continuesAsk = retry && isVisible
    let previousNotes = taskNotes
    let previousIncluded = included
    let previousChoices = choices
    let previousAssumptions = assumptions
    let previousRevision = userRevisedInputs
    dismiss()
    if !continuesAsk {
      continuousAsk = UUID()
      clarificationCount = 0
    }
    self.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    taskNotes = continuesAsk ? previousNotes : self.instruction.isEmpty ? [] : [self.instruction]
    included = continuesAsk ? previousIncluded : []
    choices = continuesAsk ? previousChoices : [:]
    assumptions = continuesAsk ? previousAssumptions : []
    proposals = []
    preview = nil
    selected = nil
    clarification = nil
    requestedContext = []
    requestBodies = []
    preparedBody = nil
    failure = nil
    rejectedSource = nil
    rejection = nil
    automaticRepairs = 0
    self.allowsExplanation = allowsExplanation
    self.forceModel = forceModel
    self.allowsExplanationRequested = askedForExplanation
    self.retry = retry
    userRevisedInputs = continuesAsk && previousRevision
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
        let body = try await SuggestionRequestContext.requestBody(
          settings: configuration.settings, snapshot: snapshot, including: self.included,
          choices: self.choices, userRevisedInputs: self.userRevisedInputs,
          allowsExplanation: self.allowsExplanation, allowsAnswer: !self.allowsExplanation)
        guard self.revision == version, snapshot.source.text == editor.sheet.text else { return }
        self.snapshot = snapshot
        self.preparedBody = body
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
    if !forceModel, SheetEditorViewController.isLocalExplanationQuestion(instruction) {
      prepare(instruction: instruction, autoSend: true)
      return
    }
    guard canSend, let configuration, let snapshot, let editor,
      snapshot.source.text == editor.sheet.text
    else { return }
    let version = revision
    preparedBody = nil
    update(.requesting, localized("ask.requesting", "Ganit is asking…"))
    task = Task { [weak self] in
      await self?.invalidationTask?.value
      let job = await configuration.coordinator.start(
        SuggestionJobInput(
          document: editor.suggestionDocumentID, snapshot: snapshot,
          settings: configuration.settings,
          permission: SuggestionPermission(contextAccepted: true),
          includedRecords: self?.included ?? [], choices: self?.choices ?? [:],
          approvedAssumptions: self?.assumptions ?? [], retry: self?.retry ?? false,
          allowsExplanation: self?.allowsExplanation ?? false,
          userRevisedInputs: self?.userRevisedInputs ?? false,
          allowsAnswer: !(self?.allowsExplanation ?? false)),
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
      case .answer(let text):
        self.dismiss()
        guard let target = self.target?.first else { return }
        editor.showModelAnswer(text, target: target, model: configuration.settings.model)
      case .explanation(let text):
        self.dismiss()
        guard let target = self.target?.first else { return }
        let model = configuration.settings.model
        editor.showModelExplanation(text, target: target, model: model)
      case .proposal(let candidates):
        self.proposals = candidates
        self.selectProposal(0)
      case .clarify(let value):
        guard self.clarificationCount < 2 else {
          self.reportFailure(.noUsefulAnswer)
          return
        }
        self.clarificationCount += 1
        self.clarification = value
        self.update(.needsChoice, value.question)
      case .unsupported:
        self.reportFailure(self.failure ?? .noUsefulAnswer)
      case .failed(let failure):
        if let classified = self.failure {
          self.reportFailure(classified)
        } else {
          self.update(.failed, Self.failureMessage(failure))
        }
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
    case .state(let state):
      self.state = state
      if state == .checking || state == .repairing {
        message = localized("ask.checking", "Ganit is checking…")
      }
    case .failure(let failure): reportFailure(failure)
    case .rejectedReply(let source):
      rejectedSource = String(source.prefix(16_384))
      if source.count > 16_384 {
        rejectedSource? +=
          "\n\n" + localized("ask.replyShortened", "The reply was shortened for display.")
      }
      rejection = nil
    case .rejectedCandidate(let source, let failure):
      rejectedSource = source
      rejection = failure
    case .repairStarted(let count): automaticRepairs = count
    case .requestBody(let body): requestBodies.append(body)
    case .includeContext(let records, let reason):
      requestedContext = records
      message = reason
    }
    didChange()
  }

  private func reportFailure(_ failure: AskFailure) {
    self.failure = failure
    preview = nil
    proposals = []
    selected = nil
    clarification = nil
    let message: String
    switch failure {
    case .notGanitSource:
      message = localized(
        "ask.failure.notSource", "Ganit could not turn the reply into Ganit source.")
    case .modelSuppliedNumbers:
      message = localized(
        "ask.failure.numbers",
        "The model put numbers in its words. Ganit does the calculating, so ask about intent or wording instead."
      )
    case .answerNotApplicable:
      message = localized(
        "ask.failure.answerNotApplicable",
        "This line needs a calculation Ganit can check, not a spoken answer. Ask Ganit to fix it instead."
      )
    case .explanationNotRequested:
      message = localized(
        "ask.failure.explanationNotRequested",
        "The model explained a line you had not asked it to explain. Ask about that line, or select it and ask again."
      )
    case .rejectedByEngine(let validation):
      let formatter = DiagnosticFormatter(
        localeIdentifier: snapshot?.context.localeIdentifier ?? "en-US")
      switch validation.engineResult {
      case .evaluationFailure(let error): message = formatter.format(error).message
      case .syntaxFailure(let diagnostics):
        message = diagnostics.first.map { formatter.format($0).message } ?? validation.message
      default: message = validation.message
      }
    case .provider(let failure):
      message = ProviderErrorMessages.message(for: failure.category)
    case .unreachable:
      message = String(
        format: localized("ask.failure.unreachable", "Ganit could not reach %1$@."),
        configuration?.settings.endpoint.host ?? localized("ask.provider", "the provider"))
    case .noUsefulAnswer:
      message = localized(
        "ask.failure.noUsefulAnswer", "The model did not answer in a way Ganit could use.")
    }
    update(.failed, message)
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
    omittedLines = []
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

  package func includeLine(_ index: Int, included: Bool) {
    guard proposalLines.indices.contains(index) else { return }
    if included { omittedLines.remove(index) } else { omittedLines.insert(index) }
    choices = [:]
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
          userRevisedInputs: self.userRevisedInputs, omittedLines: self.omittedLines)
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
            "These selected lines do not pass the local checks. Select more lines or ask again."))
      }
    }
  }

  package func submitClarification(
    _ answer: String, revisesInputs: Bool = false, autoSend: Bool = false
  ) {
    guard let editor, let target, let configuration, clarification != nil,
      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let permittedRecords = Set(snapshot?.inventory.filter(\.matchesTarget).map(\.handle) ?? [])
      .union(included)
    revision += 1
    let version = revision
    clarification = nil
    taskNotes.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
    userRevisedInputs = userRevisedInputs || revisesInputs
    update(.preparing, localized("ask.preparingRevised", "Preparing the revised Ask."))
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var snapshot = try await editor.suggestionSnapshot(targets: target)
        for note in self.taskNotes { snapshot = try snapshot.addingTaskNote(note) }
        guard self.revision == version, snapshot.source.text == editor.sheet.text else { return }
        let body = try await SuggestionRequestContext.requestBody(
          settings: configuration.settings, snapshot: snapshot, including: self.included,
          choices: self.choices, userRevisedInputs: self.userRevisedInputs,
          allowsExplanation: self.allowsExplanation, allowsAnswer: !self.allowsExplanation)
        guard self.revision == version, snapshot.source.text == editor.sheet.text else { return }
        self.snapshot = snapshot
        self.preparedBody = body
        let addsSource = !Set(snapshot.inventory.filter(\.matchesTarget).map(\.handle))
          .isSubset(of: permittedRecords)
        self.update(
          .idle,
          Self.contextSummary(snapshot, model: configuration.settings.model)
            + " "
            + (addsSource
              ? localized(
                "ask.reviewAddedSource",
                "Your answer adds source records. Open Context before you send.")
              : localized("ask.reviewNote", "Your added words are listed in Context.")))
        if autoSend && !addsSource { self.send() }
      } catch {
        guard self.revision == version else { return }
        self.update(
          .failed,
          localized("ask.revisedTooLarge", "That revised Ask is too large, or the sheet changed."))
      }
    }
  }

  package func rephraseClarification() {
    guard clarification != nil else { return }
    clarification = nil
    preparedBody = nil
    update(.idle, localized("ask.rephrase", "Change your original words, then press Return."))
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
          userRevisedInputs: self.userRevisedInputs, omittedLines: self.omittedLines,
          assumptionModel: self.configuration?.settings.model ?? "AI")
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
        editor.view.window?.makeFirstResponder(editor.textView)
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

  package func invalidate(documentChanged: Bool = true) {
    if documentChanged { editor?.dismissExplanation() }
    if documentChanged, let configuration, let editor {
      let document = editor.suggestionDocumentID
      let prior = invalidationTask
      invalidationTask = Task {
        await prior?.value
        await configuration.coordinator.invalidate(document: document)
      }
    }
    revision += 1
    task?.cancel()
    if let job, let configuration {
      job.cancel()
      Task { await configuration.coordinator.cancel(job.id) }
    }
    job = nil
    failure = nil
    rejectedSource = nil
    rejection = nil
    automaticRepairs = 0
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
    invalidate(documentChanged: false)
    isVisible = false
    update(.dismissed, "")
    editor?.view.window?.makeFirstResponder(editor?.textView)
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
    case .providerFailure:
      ProviderErrorMessages.message(for: .unknown)
    case .transport:
      localized("ask.failed.transport", "Ganit could not reach the provider.")
    case .schema:
      localized("ask.failed.schema", "The reply was not something Ganit could read.")
    }
  }
}
