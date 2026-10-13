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
  private var target: LineID?
  private var taskNotes: [String] = []
  private var retry = false
  package var didChange: () -> Void = {}
  package private(set) var isVisible = false
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

  package func prepare(retry: Bool = false) {
    dismiss()
    taskNotes = []
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
    isVisible = true
    guard let editor, let configuration = editor.suggestionConfiguration,
      configuration.settings.isReady
    else {
      update(.failed, "Set up a provider in Assistant settings.")
      return
    }
    // An explicit request commits the composition before taking a snapshot.
    if editor.textView.hasMarkedText() { editor.textView.unmarkText() }
    guard !editor.textView.hasMarkedText(), let target = editor.suggestionTarget else {
      update(.failed, "Select one source line. Paragraph and table targets need a separate scope.")
      return
    }
    self.configuration = configuration
    self.target = target
    update(.preparing, "Prepare the source scope.")
    let version = revision
    task = Task { [weak self] in
      do {
        let snapshot = try await editor.suggestionSnapshot(target: target)
        guard let self, self.revision == version, snapshot.source.text == editor.sheet.text else {
          return
        }
        self.snapshot = snapshot
        self.preparedBody = try SuggestionWireRequest(
          settings: configuration.settings, context: snapshot.permittedContext()
        ).body
        self.update(
          .idle,
          "Send the selected source, attached notes, matching declarations, and calculation settings to the provider. Review Context before you send."
        )
      } catch {
        guard let self, self.revision == version else { return }
        self.update(.failed, "The source scope cannot be prepared. Select a smaller target.")
      }
    }
  }

  /// Only this explicit action grants permission for the frozen context.
  package func send() {
    guard canSend, let configuration, let snapshot, let editor,
      snapshot.source.text == editor.sheet.text
    else { return }
    let version = revision
    preparedBody = nil
    update(.requesting, "Request an expression.")
    task = Task { [weak self] in
      let job = await configuration.coordinator.start(
        SuggestionJobInput(
          document: self?.document ?? UUID(), snapshot: snapshot,
          settings: configuration.settings,
          permission: SuggestionPermission(contextAccepted: true),
          includedRecords: self?.included ?? [], choices: self?.choices ?? [:],
          approvedAssumptions: self?.assumptions ?? [], retry: self?.retry ?? false),
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
      case .paused: self.update(.paused, "Automatic suggestions paused.")
      case .stale: self.update(.stale, "The source scope changed. Request a new suggestion.")
      case .cancelled: self.update(.cancelled, "The request stopped.")
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
    update(.repairing, "Send the included source records.")
    Task { await configuration.coordinator.includeContext(job: job.id, handles: handles) }
  }

  package func selectProposal(_ index: Int) {
    guard proposals.indices.contains(index) else { return }
    selected = proposals[index].candidate
    preview = proposals[index]
    choices = [:]
    assumptions = []
    update(
      preview!.isApplicable ? .ready : .needsChoice,
      "Arithmetic checked. Review the interpretation and source edit.")
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
    update(.checking, "Check the selected interpretation.")
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await scheduler.checkSuggestion(
          selected, snapshot: snapshot,
          handles: self.included, choices: self.choices, assumptions: self.assumptions)
        guard self.revision == version else { return }
        self.preview = result
        self.update(
          result.isApplicable ? .ready : .needsChoice,
          "Arithmetic checked. Review the interpretation and source edit.")
      } catch {
        guard self.revision == version else { return }
        self.preview = nil
        self.update(
          .needsChoice,
          "This expression does not satisfy that choice. Edit the request and ask for a new expression."
        )
      }
    }
  }

  package func submitClarification(_ answer: String) {
    guard let editor, let target, let configuration, clarification != nil,
      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    revision += 1
    let version = revision
    clarification = nil
    taskNotes.append(answer)
    update(.preparing, "Prepare the revised request.")
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var snapshot = try await editor.suggestionSnapshot(target: target)
        for note in self.taskNotes { snapshot = try snapshot.addingTaskNote(note) }
        guard self.revision == version, snapshot.source.text == editor.sheet.text else { return }
        self.snapshot = snapshot
        self.preparedBody = try SuggestionWireRequest(
          settings: configuration.settings,
          context: snapshot.permittedContext(including: self.included)
        ).body
        self.update(.idle, "Review the added task note in Context, then send the new request.")
      } catch {
        guard self.revision == version else { return }
        self.update(.failed, "The revised request is too large or its source changed.")
      }
    }
  }

  package func apply() {
    guard canApply, let editor, let scheduler = editor.scheduler,
      let target, let selected, let original = snapshot
    else { return }
    let version = revision
    update(.checking, "Check the current source before Apply.")
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var fresh = try await editor.suggestionSnapshot(target: target)
        guard original.source.text == fresh.source.text else {
          self.invalidate()
          return
        }
        for note in self.taskNotes { fresh = try fresh.addingTaskNote(note) }
        let edit = try await scheduler.prepareSuggestion(
          selected, snapshot: fresh,
          handles: self.included, choices: self.choices, assumptions: self.assumptions)
        guard self.revision == version, fresh.source.text == editor.sheet.text,
          !editor.textView.hasMarkedText()
        else { return }
        if let old = self.preview, old.result != edit.checked.result {
          self.snapshot = fresh
          self.preview = edit.checked
          self.update(
            edit.checked.isApplicable ? .ready : .needsChoice,
            "The local preview changed. Review the current result before Use Expression.")
          return
        }
        try editor.applySuggestionEdit(edit)
        self.isVisible = false
        self.update(.applied, "Expression applied.")
      } catch {
        guard self.revision == version else { return }
        self.update(.stale, "The edit no longer passes the local checks. Request a new suggestion.")
      }
    }
  }

  package func editRequest() {
    guard let editor, let target,
      let line = editor.sheet.lines.first(where: { $0.id == target })
    else {
      dismiss()
      return
    }
    let text = editor.sheet.text
    let lower = text.utf8.index(text.utf8.startIndex, offsetBy: line.range.lowerBound)
    let upper = text.utf8.index(text.utf8.startIndex, offsetBy: line.range.upperBound)
    dismiss()
    editor.textView.setSelectedRange(NSRange(lower..<upper, in: text))
    editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
    editor.view.window?.makeFirstResponder(editor.textView)
  }

  package func invalidate() {
    revision += 1
    task?.cancel()
    if let job, let configuration {
      Task { await configuration.coordinator.cancel(job.id) }
    }
    job = nil
    snapshot = nil
    preparedBody = nil
    preview = nil
    proposals = []
    clarification = nil
    requestedContext = []
    if isVisible { update(.stale, "The source scope changed. Request a new suggestion.") }
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

  private static func failureMessage(_ failure: SuggestionJobFailure) -> String {
    switch failure {
    case .deadline: "The request reached its deadline. Retry or edit the request."
    case .providerBusy: "Another manual request is active for this provider."
    case .providerNotReady: "Set up a provider in Assistant settings."
    case .permissionRequired: "Review the source scope before sending a request."
    case .contextLimit: "The source scope is too large. Select a smaller target."
    case .contextDenied: "The requested source records were not included."
    default:
      "The provider did not return an expression that passes the local checks. Retry or edit the request."
    }
  }
}
