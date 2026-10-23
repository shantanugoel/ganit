import Foundation
import GanitAssistance
import Testing

@testable import GanitData

@Suite
struct ProviderCompatibilityTests {
  private func failure(_ fields: [String: Any], status: Int = 400) throws
    -> SuggestionTransportError
  {
    .provider(
      try #require(
        ProviderFailure.decode(
          try JSONSerialization.data(withJSONObject: ["error": fields]), status: status)))
  }

  @Test func sequentialParameterFallbackKeepsTheOtherFieldAndInspectorBody() async throws {
    let snapshot = try assistanceSnapshot(
      "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    let transport = FakeSuggestionTransport([
      .failure(try failure(["code": "unsupported_parameter", "param": "reasoning_effort"])),
      .failure(
        try failure(["code": "unsupported_parameter", "param": "response_format"], status: 422)),
      .reply(try billProposal(snapshot)),
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      SuggestionJobInput(
        document: UUID(), snapshot: snapshot, settings: fixtureSettings(),
        permission: SuggestionPermission(contextAccepted: true)), observer: { await log.append($0) }
    )
    guard case .proposal = await job.result.value else {
      Issue.record("Expected a checked proposal")
      return
    }
    let requests = await transport.requests
    #expect(requests.count == 3)
    let objects = try requests.map {
      try #require(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
    }
    #expect(objects[0]["response_format"] != nil && objects[0]["reasoning_effort"] != nil)
    #expect(objects[1]["response_format"] != nil && objects[1]["reasoning_effort"] == nil)
    #expect(objects[2]["response_format"] == nil && objects[2]["reasoning_effort"] == nil)
    #expect(await log.bodies() == requests.map(\.body))
  }

  @Test func knownFailuresAndAbsentFieldsStopWithoutRepair() async throws {
    let snapshot = try assistanceSnapshot(
      "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    for (fields, status, effortOff) in [
      (["code": "invalid_api_key"], 400, false),
      (["code": "model_not_found"], 422, false),
      (["code": "context_length_exceeded"], 400, false),
      (["code": "rate_limit_exceeded"], 429, false),
      (["code": "server_error"], 503, false),
      (["code": "unsupported_parameter", "param": "reasoning_effort"], 400, true),
      (["code": "unsupported_parameter", "param": "response_format"], 200, false),
    ] {
      let transport = FakeSuggestionTransport([.failure(try failure(fields, status: status))])
      let coordinator = SuggestionCoordinator(transport: transport)
      var settings = fixtureSettings()
      if effortOff { settings.effort = .off }
      let log = SuggestionEventLog()
      let job = await coordinator.start(
        SuggestionJobInput(
          document: UUID(), snapshot: snapshot, settings: settings,
          permission: SuggestionPermission(contextAccepted: true)),
        observer: { await log.append($0) })
      guard case .failed(.providerFailure) = await job.result.value else {
        Issue.record("Expected a provider failure")
        continue
      }
      #expect(await transport.count() == 1)
      #expect(
        await log.events.contains { if case .failure(.provider) = $0 { true } else { false } })
      #expect(await log.events.allSatisfy { if case .repairStarted = $0 { false } else { true } })
    }
  }

  @Test func aParameterErrorAtTheRequestLimitKeepsItsCategory() async throws {
    let snapshot = try assistanceSnapshot(
      "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    let transport = FakeSuggestionTransport([
      .reply(Data("invalid reply".utf8)),
      .failure(try failure(["code": "unsupported_parameter", "param": "response_format"])),
      .failure(try failure(["code": "unsupported_parameter", "param": "reasoning_effort"])),
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      SuggestionJobInput(
        document: UUID(), snapshot: snapshot, settings: fixtureSettings(),
        permission: SuggestionPermission(contextAccepted: true)), observer: { await log.append($0) }
    )
    guard case .failed(.providerFailure) = await job.result.value else {
      Issue.record("Expected the last provider failure")
      return
    }
    #expect(await transport.count() == 3)
    #expect(
      await log.events.contains {
        if case .failure(.provider(let failure)) = $0 {
          failure.category == .parameter
        } else {
          false
        }
      })
  }

  @Test func rejectedFieldIsNotRemovedTwice() async throws {
    let snapshot = try assistanceSnapshot(
      "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    let rejection = try failure(["param": "response_format", "code": "unsupported_parameter"])
    let transport = FakeSuggestionTransport([.failure(rejection), .failure(rejection)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      SuggestionJobInput(
        document: UUID(), snapshot: snapshot, settings: fixtureSettings(),
        permission: SuggestionPermission(contextAccepted: true)))
    guard case .failed(.providerFailure) = await job.result.value else {
      Issue.record("Expected a provider failure")
      return
    }
    #expect(await transport.count() == 2)
  }
}
