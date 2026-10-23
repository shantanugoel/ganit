import Foundation
import GanitAssistance
import GanitData
import GanitSuggestionProtocol
import Testing

@Suite
struct ModelAnswerTests {
  private func input(
    text: String = "What is the capital of France?", allow: Bool = true,
    permission: Bool = true, document: UUID = UUID()
  ) throws -> SuggestionJobInput {
    SuggestionJobInput(
      document: document, snapshot: try assistanceSnapshot(text), settings: fixtureSettings(),
      permission: SuggestionPermission(contextAccepted: permission), allowsAnswer: allow)
  }

  @Test func answerIsUncachedAndPreparedBytesMatchTransmission() async throws {
    let payload = try outcome("answer", ["text": "Paris"])
    let transport = FakeSuggestionTransport([.reply(payload), .reply(payload)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let request = try input()
    let prepared = try await SuggestionRequestContext.requestBody(
      settings: request.settings, snapshot: request.snapshot, allowsAnswer: true)
    for _ in 0..<2 {
      let job = await coordinator.start(request)
      guard case .answer(let text) = await job.result.value else {
        Issue.record("Expected a transient answer")
        return
      }
      #expect(text == "Paris")
    }
    #expect(await transport.count() == 2)
    #expect(await transport.requests.first?.body == prepared)
  }

  @Test(arguments: ["10 kg of water in ml", "bill = 2400\nsplit bill", "2 + 2", "split among four"])
  func anAnswerCannotReplaceACalculation(_ source: String) async throws {
    let transport = FakeSuggestionTransport([.reply(try outcome("answer", ["text": "Paris"]))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(try input(text: source))
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected the answer gate to reject numeric or bound input")
      return
    }
    let body = String(decoding: await transport.requests[0].body, as: UTF8.self)
    #expect(!body.contains("You may return kind answer"))
  }

  @Test func answerRequiresManualRequestAndContextPermission() async throws {
    let transport = FakeSuggestionTransport([.reply(try outcome("answer", ["text": "Paris"]))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let denied = await coordinator.start(try input(permission: false))
    guard case .failed(.permissionRequired) = await denied.result.value else {
      Issue.record("Expected context permission failure")
      return
    }
    #expect(await transport.count() == 0)
    let unsolicited = await coordinator.start(try input(allow: false))
    guard case .failed(.schema) = await unsolicited.result.value else {
      Issue.record("Expected an unsolicited answer to fail")
      return
    }
  }

  @Test func automaticOriginCannotReturnAnAnswer() async throws {
    let request = try input()
    let automatic = SuggestionJobInput(
      document: request.document, snapshot: request.snapshot, settings: request.settings,
      permission: SuggestionPermission(contextAccepted: true, automaticArea: UUID()),
      origin: .automatic, allowsAnswer: true)
    let transport = FakeSuggestionTransport([.reply(try outcome("answer", ["text": "Paris"]))])
    let clock = SuggestionClock(now: { 0 }, sleepUntil: { _ in })
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock)
    let job = await coordinator.start(automatic)
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected an automatic answer to fail")
      return
    }
  }

  @Test func lateAnswerCannotReplaceAStaleJob() async throws {
    let transport = FakeSuggestionTransport([.pending])
    let coordinator = SuggestionCoordinator(transport: transport)
    let request = try input()
    let job = await coordinator.start(request)
    await transport.waitForRequests(1)
    await coordinator.invalidate(document: request.document)
    await transport.complete(0, data: try outcome("answer", ["text": "Paris"]))
    guard case .stale = await job.result.value else {
      Issue.record("Expected a stale answer to be discarded")
      return
    }
  }

  @Test(arguments: [
    "42", "forty = two", "2+2", "二", "Ⅳ", "²", "forty two kilograms", "One kilogram",
    "a dozen eggs", "lakhs", "a half", "",
    "   ",
  ])
  func decoderRejectsNumbersEquationsAndEmptyAnswers(_ text: String) throws {
    let data = try outcome("answer", ["text": text])
    #expect(throws: (any Error).self) { try SuggestionDecoder.decode(data) }
  }

  @Test func decoderRejectsAnswerSourceAndUnknownFields() throws {
    for fields: [String: Any] in [["text": "Paris", "source": "1"], ["value": "Paris"]] {
      let data = try outcome("answer", fields)
      #expect(throws: (any Error).self) { try SuggestionDecoder.decode(data) }
    }
  }
}
