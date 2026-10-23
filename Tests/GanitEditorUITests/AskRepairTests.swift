import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@testable import GanitEditorUI

@MainActor
@Suite(.serialized)
struct AskRepairTests {
  private static var windows: [NSWindow] = []
  private let source = "Add two and three."

  private func editor() async throws -> SheetEditorViewController {
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
    let editor = SheetEditorViewController(text: source, context: context)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return editor
  }

  private func proposal(_ editor: SheetEditorViewController, source: String) async throws -> Data {
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[0].id)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: source)], bindings: [],
      literals: try zip(["2", "3"], ["two", "three"]).map { number, word in
        SuggestionLiteral(
          text: number,
          evidence: try #require(evidence.first { $0.text == word && $0.kind == "literal" }?.handle)
        )
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ], assumptions: [], summary: "Add the supplied numbers.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
  }

  private func configure(
    _ editor: SheetEditorViewController, steps: [AskRepairTransport.Step],
    repairs: Int = 2, clock: SuggestionClock = .continuous,
    responseTimeout: TimeInterval = AssistantSettings.defaultResponseTimeout
  ) -> AskRepairTransport {
    let transport = AskRepairTransport(steps)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport, clock: clock),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!,
        model: "synthetic", repairAttempts: repairs, responseTimeout: responseTimeout))
    return transport
  }

  private func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }

  @Test(arguments: [
    ProviderErrorCategory.authentication, .model, .parameter, .rateLimit, .server, .contextLimit,
  ])
  func providerFailuresReachTheUserWithoutSchemaRepair(_ category: ProviderErrorCategory)
    async throws
  {
    let editor = try await editor()
    let transport = configure(
      editor, steps: [.failure(.provider(ProviderFailure(status: 200, category: category)))])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    guard case .provider(let failure) = session.failure else {
      Issue.record("Expected a provider failure card")
      return
    }
    #expect(failure.category == category)
    #expect(session.message == ProviderErrorMessages.message(for: category))
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(session.automaticRepairs == 0)
    #expect(await transport.bodies().count == 1)
    #expect(editor.sheet.text == source)
  }

  @Test func anUnknownFunctionIsRepairedBeforeAnyProposalAppears() async throws {
    let editor = try await editor()
    let invalid = try await proposal(editor, source: "mortgage(2, 3)")
    let valid = try await proposal(editor, source: "2 + 3")
    let transport = configure(editor, steps: [.reply(invalid), .pending])
    let session = editor.suggestionSession
    session.prepare(instruction: "add the numbers", autoSend: true)
    await transport.waitForRequests(2)
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(session.automaticRepairs == 1)
    #expect(session.repairNotice == "Ganit asked the model to fix its first attempt.")
    #expect(session.message == "Ganit is checking…")
    #expect(editor.sheet.text == source)
    let repairBody = await transport.bodies()[1]
    #expect(String(decoding: repairBody, as: UTF8.self).contains("unknownFunction"))
    await transport.complete(valid)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement == "2 + 3")
    #expect(session.checkedFooter == "Ganit checked these lines · 1 automatic repair")
    #expect(session.rejectedInspection?.contains("mortgage(2, 3)") == true)
    #expect(editor.sheet.text == source)
  }

  @Test func anEngineFailureShowsNativeDiagnosticsAndOnlyNativeAlternatives() async throws {
    let editor = try await editor()
    let reply = try await proposal(editor, source: "mortgage(2, 3)")
    _ = configure(editor, steps: [.reply(reply)], repairs: 0)
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    guard case .rejectedByEngine(let failure) = session.failure else {
      Issue.record("Expected a native failure card")
      return
    }
    guard case .evaluationFailure(let error) = failure.engineResult else {
      Issue.record("Expected the native error")
      return
    }
    #expect(error.code == .unknownFunction)
    #expect(!failure.ranges.isEmpty)
    #expect(session.message.lowercased().contains("function"))
    #expect(session.nativeFunctionAlternatives == ["pmt", "fv", "pv"])
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(
      session.rejectedInspection?.hasPrefix("Ganit rejected this reply. It cannot be applied.")
        == true)
    let controls = buttons(editor.view)
    #expect(controls.contains { $0.title == "Show what the model meant" })
    #expect(controls.contains { $0.title == "Edit words" })
    #expect(controls.contains { $0.title == "Retry" })
    #expect(!controls.contains { $0.title.hasPrefix("Apply") })
    #expect(editor.sheet.text == source)
  }

  @Test func malformedOutputCanBeRepairedWithoutRenderingTheRejectedReply() async throws {
    let editor = try await editor()
    let valid = try await proposal(editor, source: "2 + 3")
    let transport = configure(
      editor, steps: [.reply(Data("The answer is five.".utf8)), .pending])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await transport.waitForRequests(2)
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(session.automaticRepairs == 1)
    #expect(session.rejectedSource == "The answer is five.")
    #expect(session.message == "Ganit is checking…")
    #expect(!buttons(editor.view).contains { $0.title.hasPrefix("Apply") })
    await transport.complete(valid)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement == "2 + 3")
    #expect(session.automaticRepairs == 1)
    #expect(editor.sheet.text == source)
  }

  @Test func malformedOutputShowsASeparateRejectedReplyAndRetrySendsANewJob() async throws {
    let editor = try await editor()
    let valid = try await proposal(editor, source: "2 + 3")
    let transport = configure(
      editor, steps: [.reply(Data("Use a calculator for this.".utf8)), .reply(valid)], repairs: 0)
    let session = editor.suggestionSession
    session.prepare(instruction: "add these", autoSend: true)
    await session.waitUntilIdle()
    guard case .notGanitSource = session.failure else {
      Issue.record("Expected a source failure card")
      return
    }
    #expect(session.message == "Ganit could not turn the reply into Ganit source.")
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(session.rejectedInspection?.contains("Use a calculator for this.") == true)
    let retry = try #require(buttons(editor.view).first { $0.title == "Retry" })
    retry.performClick(nil)
    await session.waitUntilIdle()
    #expect(await transport.bodies().count == 2)
    #expect(session.failure == nil)
    #expect(session.automaticRepairs == 0)
    #expect(session.canApply)
    #expect(editor.sheet.text == source)
  }

  @Test func aDeadlineShowsTheProviderHostAndIgnoresTheLateReply() async throws {
    let editor = try await editor()
    let valid = try await proposal(editor, source: "2 + 3")
    let clock = AskRepairClock()
    // The wait is the one under test, so the clock knows it too.
    let transport = configure(editor, steps: [.pending], clock: clock.clock, responseTimeout: 30)
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await transport.waitForRequests(1)
    await clock.waitForSleeper()
    clock.advance(to: 30)
    await session.waitUntilIdle()
    guard case .unreachable = session.failure else {
      Issue.record("Expected a connection failure card")
      return
    }
    #expect(session.message == "Ganit could not reach fixture.invalid.")
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(session.automaticRepairs == 0)
    await transport.complete(valid)
    #expect(!session.canApply)
    #expect(editor.sheet.text == source)
  }

  @Test func anUnsupportedReplyShowsTheNoUsefulAnswerCard() async throws {
    let editor = try await editor()
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "unsupported", "reason": "I cannot do that.",
    ])
    _ = configure(editor, steps: [.reply(reply)])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    guard case .noUsefulAnswer = session.failure else {
      Issue.record("Expected a useful-answer failure card")
      return
    }
    #expect(session.message == "The model did not answer in a way Ganit could use.")
    #expect(session.preview == nil)
    #expect(!session.canApply)
  }
}

private actor AskRepairTransport: SuggestionTransport {
  enum Step: Sendable {
    case reply(Data)
    case failure(SuggestionTransportError)
    case pending
  }
  private var steps: [Step]
  private var requests: [Data] = []
  private var pending: CheckedContinuation<Data, any Error>?
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  init(_ steps: [Step]) { self.steps = steps }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    requests.append(request.body)
    let ready = waiters.filter { requests.count >= $0.0 }
    waiters.removeAll { requests.count >= $0.0 }
    for waiter in ready { waiter.1.resume() }
    switch steps.removeFirst() {
    case .reply(let data): return data
    case .failure(let error): throw error
    case .pending: return try await withCheckedThrowingContinuation { pending = $0 }
    }
  }
  func bodies() -> [Data] { requests }
  func complete(_ data: Data) {
    pending?.resume(returning: data)
    pending = nil
  }
  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
}

private final class AskRepairClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
  private var cancelled: Set<UUID> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var clock: SuggestionClock {
    SuggestionClock(
      now: { self.lock.withLock { self.time } }, sleepUntil: { try await self.sleep(until: $0) })
  }
  private func sleep(until deadline: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        lock.withLock {
          if cancelled.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
          }
          if time >= deadline {
            continuation.resume()
            return
          }
          sleepers[id] = (deadline, continuation)
          let ready = waiters
          waiters = []
          for waiter in ready { waiter.resume() }
        }
      }
    } onCancel: {
      self.lock.withLock {
        if let sleeper = self.sleepers.removeValue(forKey: id) {
          sleeper.1.resume(throwing: CancellationError())
        } else {
          self.cancelled.insert(id)
        }
      }
    }
  }
  func waitForSleeper() async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if !sleepers.isEmpty { continuation.resume() } else { waiters.append(continuation) }
      }
    }
  }
  func advance(to value: TimeInterval) {
    lock.withLock {
      time = value
      let ready = sleepers.filter { $0.value.0 <= value }
      for (id, sleeper) in ready {
        sleepers.removeValue(forKey: id)
        sleeper.1.resume()
      }
    }
  }
}
