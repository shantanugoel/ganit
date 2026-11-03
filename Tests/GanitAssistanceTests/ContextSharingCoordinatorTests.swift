import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@Suite
struct ContextSharingCoordinatorTests {
  private let source = "hidden = 10 INR\nAdd a 2% tip to the amount above."

  private func input(
    _ snapshot: AssistanceSnapshot, _ sharing: AssistantContextSharing, document: UUID = UUID()
  ) -> SuggestionJobInput {
    var settings = fixtureSettings()
    settings.contextSharing = sharing
    return SuggestionJobInput(
      document: document, snapshot: snapshot, settings: settings,
      permission: SuggestionPermission(contextAccepted: true))
  }

  @Test func namesStillAskBeforeAValueIsSent() async throws {
    let snapshot = try assistanceSnapshot(source)
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    let need = try outcome("need_context", ["records": [handle], "reason": "Identify the amount."])
    let finished = try outcome("unsupported", ["reason": "Fixture ends after context."])
    let transport = FakeSuggestionTransport([.reply(need), .reply(finished)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let log = SuggestionEventLog()
    let job = await coordinator.start(input(snapshot, .names), observer: { await log.append($0) })
    await log.waitFor(.needsContext)
    let first = String(decoding: await transport.requests[0].body, as: UTF8.self)
    #expect(first.contains("hidden"))
    #expect(first.contains("The index lists"))
    await coordinator.includeContext(job: job.id, handles: [handle])
    _ = await job.result.value
    #expect(await transport.count() == 2)
  }

  @Test func wholeSheetSendsEveryRecordWithoutAsking() async throws {
    let snapshot = try assistanceSnapshot(source)
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    let need = try outcome("need_context", ["records": [handle], "reason": "Identify the amount."])
    let finished = try outcome("unsupported", ["reason": "Fixture ends after context."])
    let transport = FakeSuggestionTransport([.reply(need), .reply(finished)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let log = SuggestionEventLog()
    let job = await coordinator.start(input(snapshot, .sheet), observer: { await log.append($0) })
    if case .unsupported = await job.result.value {
    } else {
      Issue.record("Expected the follow-up without a consent prompt")
    }
    #expect(await transport.count() == 2)
    let first = String(decoding: await transport.requests[0].body, as: UTF8.self)
    #expect(first.contains("hidden"))
    #expect(first.contains("The sheet field"))
  }

  @Test func aWholeSheetTooLargeStillSendsTheRecordTheModelAsksFor() async throws {
    let note = "// " + String(repeating: "a", count: 1_000)
    let text =
      (["hidden = 10 INR", ""] + Array(repeating: note, count: 70) + ["", "Add a 2% tip to it."])
      .joined(separator: "\n")
    let snapshot = try assistanceSnapshot(text)
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    let need = try outcome("need_context", ["records": [handle], "reason": "Identify the amount."])
    let finished = try outcome("unsupported", ["reason": "Fixture ends after context."])
    let transport = FakeSuggestionTransport([.reply(need), .reply(finished)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(input(snapshot, .sheet))
    _ = await job.result.value
    try #require(await transport.count() == 2)
    let first = try context(await transport.requests[0].body)
    let second = try context(await transport.requests[1].body)
    #expect(first["sheet"] == nil)
    #expect(!symbolHandles(first).contains(handle))
    #expect(symbolHandles(second).contains(handle))
  }

  private func context(_ body: Data) throws -> [String: Any] {
    let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let text = try #require(
      messages.first { $0["role"] as? String == "user" }?["content"] as? String)
    return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private func symbolHandles(_ context: [String: Any]) -> Set<String> {
    Set((context["symbols"] as? [[String: Any]] ?? []).compactMap { $0["handle"] as? String })
  }

  @Test func eachLevelHasItsOwnCachedReply() async throws {
    let snapshot = try assistanceSnapshot("secret = 5\nbill = 10\nAdd a tip to bill.")
    let finished = try outcome("unsupported", ["reason": "Fixture ends here."])
    let transport = FakeSuggestionTransport([.reply(finished), .reply(finished)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let document = UUID()
    _ = await coordinator.start(input(snapshot, .needed, document: document)).result.value
    _ = await coordinator.start(input(snapshot, .names, document: document)).result.value
    #expect(await transport.count() == 2)
    _ = await coordinator.start(input(snapshot, .needed, document: document)).result.value
    #expect(await transport.count() == 2)
  }
}
