import Foundation
import GanitAssistance
import GanitData
import GanitSuggestionProtocol
import Testing

@Suite
struct ModelExplanationTests {
  private let text = "The tip applies to the bill before the split."

  private func input(allow: Bool = true, permission: Bool = true, document: UUID = UUID()) throws
    -> SuggestionJobInput
  {
    SuggestionJobInput(
      document: document, snapshot: try assistanceSnapshot("bill = 2400\n10% of bill"),
      settings: fixtureSettings(), permission: SuggestionPermission(contextAccepted: permission),
      allowsExplanation: allow)
  }

  @Test func explicitExplanationIsTransientAndIsNeverReplayed() async throws {
    let payload = try outcome("explanation", ["text": text])
    let transport = FakeSuggestionTransport([.reply(payload), .reply(payload)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let request = try input()
    for _ in 0..<2 {
      let job = await coordinator.start(request)
      guard case .explanation(let explanation) = await job.result.value else {
        Issue.record("Expected a model explanation")
        return
      }
      #expect(explanation == text)
    }
    #expect(await transport.count() == 2)
    let body = String(decoding: await transport.requests[0].body, as: UTF8.self)
    #expect(body.contains("The user explicitly requested an explanation"))
    #expect(body.contains("explanation"))
  }

  @Test func unsolicitedExplanationFailsWithoutAProposal() async throws {
    let transport = FakeSuggestionTransport([.reply(try outcome("explanation", ["text": text]))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(try input(allow: false))
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected rejection of an unsolicited explanation")
      return
    }
    #expect(await transport.count() == 1)
  }

  @Test func permissionIsRequiredBeforeAnExplanationRequest() async throws {
    let transport = FakeSuggestionTransport([])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(try input(permission: false))
    guard case .failed(.permissionRequired) = await job.result.value else {
      Issue.record("Expected context permission rejection")
      return
    }
    #expect(await transport.count() == 0)
  }

  @Test func lateExplanationCannotReplaceAStaleJob() async throws {
    let transport = FakeSuggestionTransport([.pending])
    let coordinator = SuggestionCoordinator(transport: transport)
    let request = try input()
    let job = await coordinator.start(request)
    await transport.waitForRequests(1)
    await coordinator.invalidate(document: request.document)
    await transport.complete(0, data: try outcome("explanation", ["text": text]))
    guard case .stale = await job.result.value else {
      Issue.record("Expected a stale explanation to be discarded")
      return
    }
  }

  @Test func preparedBodyMatchesTheSentExplanationRequest() async throws {
    let request = try input()
    let prepared = try await SuggestionRequestContext.requestBody(
      settings: request.settings, snapshot: request.snapshot, allowsExplanation: true)
    let transport = FakeSuggestionTransport([.reply(try outcome("explanation", ["text": text]))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(request)
    _ = await job.result.value
    #expect(await transport.requests.first?.body == prepared)
  }

  @Test func numericProseIsReportedAsItsOwnReason() throws {
    for text in ["The tip is 10% of 2400.", "Divide by 4.", "bill + 10%"] {
      let data = try outcome("explanation", ["text": text])
      #expect(throws: SuggestionDecodingError.numericProse) {
        try SuggestionDecoder.decode(data)
      }
    }
  }

  @Test func numericProseStopsTheJobWithoutADoomedRepair() async throws {
    let transport = FakeSuggestionTransport([
      .reply(try outcome("explanation", ["text": "Take 10% of the bill."])),
      .reply(try outcome("explanation", ["text": text])),
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(try input(), observer: { await log.append($0) })
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected a numeric explanation to stop the job")
      return
    }
    #expect(await transport.count() == 1)
    let events = await log.events
    #expect(
      !events.contains {
        if case .repairStarted = $0 { return true }
        return false
      })
    #expect(
      events.contains {
        if case .failure(.modelSuppliedNumbers) = $0 { return true }
        return false
      })
  }

  @Test func anUnsolicitedExplanationHasItsOwnReason() async throws {
    let transport = FakeSuggestionTransport([.reply(try outcome("explanation", ["text": text]))])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      try input(allow: false), observer: { await log.append($0) })
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected rejection of an unsolicited explanation")
      return
    }
    #expect(await transport.count() == 1)
    #expect(
      await log.events.contains {
        if case .failure(.explanationNotRequested) = $0 { return true }
        return false
      })
  }
}
