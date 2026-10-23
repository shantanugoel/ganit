import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import Testing

@Suite
struct AskRepairCoordinatorTests {
  private let source = "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways."

  private func input(
    _ snapshot: AssistanceSnapshot, repairs: Int, responseTimeout: TimeInterval? = nil
  ) -> SuggestionJobInput {
    var settings = fixtureSettings()
    settings.repairAttempts = repairs
    if let responseTimeout { settings.responseTimeout = responseTimeout }
    return SuggestionJobInput(
      document: UUID(), snapshot: snapshot, settings: settings,
      permission: SuggestionPermission(contextAccepted: true))
  }

  private func repairCounts(_ events: [SuggestionJobEvent]) -> [Int] {
    events.compactMap {
      if case .repairStarted(let count) = $0 { return count }
      return nil
    }
  }

  @Test func zeroRepairsStopsMalformedRepliesAndExposesOnlyFailureDetails() async throws {
    let snapshot = try assistanceSnapshot(source)
    let malformed = "The result is 42."
    let transport = FakeSuggestionTransport([.reply(Data(malformed.utf8))])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      input(snapshot, repairs: 0), observer: { await log.append($0) })
    guard case .failed(.schema) = await job.result.value else {
      Issue.record("Expected one malformed response to stop.")
      return
    }
    #expect(await transport.count() == 1)
    let events = await log.events
    #expect(repairCounts(events).isEmpty)
    #expect(
      events.contains {
        if case .rejectedReply(let raw) = $0 { return raw == malformed }
        return false
      })
    #expect(
      events.contains {
        if case .failure(.notGanitSource) = $0 { return true }
        return false
      })
    #expect(
      !events.contains {
        if case .state(.ready) = $0 { return true }
        return false
      })
  }

  @Test func malformedOutputCanUseOneRepairAndFormatFallbackIsNotARepair() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([
      .failure(.provider(ProviderFailure(status: 422, category: .unknown))),
      .reply(Data("not JSON".utf8)),
      .reply(try billProposal(snapshot)),
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      input(snapshot, repairs: 1), observer: { await log.append($0) })
    guard case .proposal(let proposals) = await job.result.value else {
      Issue.record("Expected a checked repair.")
      return
    }
    #expect(proposals.allSatisfy { $0.isApplicable })
    #expect(await transport.count() == 3)
    #expect(repairCounts(await log.events) == [1])
  }

  @Test func anEngineRepairReceivesTheNativeDiagnosticAndRejectedSource() async throws {
    let snapshot = try assistanceSnapshot(source)
    let rejectedSource = "(mortgage(bill) + 10%) / 4"
    let transport = FakeSuggestionTransport([
      .reply(try billProposal(snapshot, source: rejectedSource)),
      .reply(try billProposal(snapshot)),
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      input(snapshot, repairs: 1), observer: { await log.append($0) })
    guard case .proposal = await job.result.value else {
      Issue.record("Expected a checked proposal after the native diagnostic.")
      return
    }
    let events = await log.events
    let rejected = try #require(
      events.compactMap { event -> AssistanceValidationFailure? in
        if case .rejectedCandidate(let source, let failure) = event {
          #expect(source == rejectedSource)
          return failure
        }
        return nil
      }.first)
    guard case .evaluationFailure(let error) = rejected.engineResult else {
      Issue.record("Expected the native unknown-function diagnostic.")
      return
    }
    #expect(error.code == .unknownFunction)
    #expect(!rejected.ranges.isEmpty)
    let requests = await transport.requests
    let payload = try #require(
      JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let text = try #require(messages.last?["content"] as? String)
    let context = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let feedback = try #require(context["feedback"] as? [String: Any])
    #expect(feedback["message"] as? String == rejected.message)
    #expect(feedback["rejectedSource"] as? String == rejectedSource)
    #expect(feedback["engineCode"] as? String == "evaluation.unknownFunction")
    #expect(feedback["availableFunctions"] as? [String] == ["pmt", "fv", "pv"])
    let diagnostic = try #require(feedback["engineDiagnostic"] as? [String: Any])
    #expect(diagnostic["code"] as? String == "evaluation.unknownFunction")
    #expect((diagnostic["spans"] as? [[String: Int]])?.isEmpty == false)
    #expect(repairCounts(events) == [1])
  }

  @Test func zeroEngineRepairsKeepsTheTypedNativeFailure() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([
      .reply(try billProposal(snapshot, source: "(mortgage(bill) + 10%) / 4"))
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      input(snapshot, repairs: 0), observer: { await log.append($0) })
    guard case .failed(.validation) = await job.result.value else {
      Issue.record("Expected the rejected proposal to stop.")
      return
    }
    #expect(await transport.count() == 1)
    let events = await log.events
    #expect(
      events.contains {
        if case .failure(.rejectedByEngine) = $0 { return true }
        return false
      })
    #expect(
      !events.contains {
        if case .state(.ready) = $0 { return true }
        return false
      })
  }

  @Test func timeoutIsUnreachableAndNeverStartsARepair() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending])
    let clock = FakeSuggestionClock()
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let job = await coordinator.start(
      input(snapshot, repairs: 3, responseTimeout: 30), observer: { await log.append($0) })
    await transport.waitForRequests(1)
    await clock.waitForSleepers(1)
    clock.advance(to: 31)
    guard case .failed(.deadline) = await job.result.value else {
      Issue.record("Expected the request timeout.")
      return
    }
    let events = await log.events
    #expect(
      events.contains {
        if case .failure(.unreachable) = $0 { return true }
        return false
      })
    #expect(repairCounts(events).isEmpty)
    #expect(await transport.count() == 1)
    await transport.complete(0, data: try billProposal(snapshot))
  }
  @Test func theRepairSettingAndSharedWireCeilingBothApply() async throws {
    let snapshot = try assistanceSnapshot(source)
    for setting in [1, 3] {
      let transport = FakeSuggestionTransport([
        .reply(try billProposal(snapshot, source: "(other + 10%) / 4", binding: "S99")),
        .reply(try billProposal(snapshot, source: "(bill + 15%) / 4", literal: "15%")),
        .reply(try billProposal(snapshot)),
      ])
      let log = SuggestionEventLog()
      let coordinator = SuggestionCoordinator(transport: transport)
      let job = await coordinator.start(
        input(snapshot, repairs: setting), observer: { await log.append($0) })
      let result = await job.result.value
      if setting == 1 {
        guard case .failed(.validation) = result else {
          Issue.record("Expected the selected repair limit.")
          continue
        }
        #expect(await transport.count() == 2)
        #expect(repairCounts(await log.events) == [1])
      } else {
        guard case .proposal = result else {
          Issue.record("Expected two repairs within the three-request ceiling.")
          continue
        }
        #expect(await transport.count() == 3)
        #expect(repairCounts(await log.events) == [1, 2])
      }
    }
  }

  @Test func unsupportedOutputHasNoUsefulAnswerAndFailurePrecedesTerminalState() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([
      .reply(try outcome("unsupported", ["reason": "No useful source."]))
    ])
    let log = SuggestionEventLog()
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(
      input(snapshot, repairs: 2), observer: { await log.append($0) })
    guard case .unsupported = await job.result.value else {
      Issue.record("Expected the unsupported outcome.")
      return
    }
    let events = await log.events
    let failure = try #require(
      events.firstIndex {
        if case .failure(.noUsefulAnswer) = $0 { return true }
        return false
      })
    let terminal = try #require(
      events.firstIndex {
        if case .state(.failed) = $0 { return true }
        return false
      })
    #expect(failure < terminal)
    #expect(await transport.count() == 1)
  }

  @Test func rejectedTransportReplyUsesTheSameBoundedSchemaFailurePath() async throws {
    let snapshot = try assistanceSnapshot(source)
    let raw = "The model returned prose instead of a source proposal."
    for repairs in [0, 1] {
      let transport = FakeSuggestionTransport([
        .failure(.rejectedReply(Data(raw.utf8))), .reply(try billProposal(snapshot)),
      ])
      let log = SuggestionEventLog()
      let coordinator = SuggestionCoordinator(transport: transport)
      let job = await coordinator.start(
        input(snapshot, repairs: repairs), observer: { await log.append($0) })
      let result = await job.result.value
      let events = await log.events
      #expect(
        events.contains {
          if case .rejectedReply(let reply) = $0 { return reply == raw }
          return false
        })
      if repairs == 0 {
        guard case .failed(.schema) = result else {
          Issue.record("Expected the provider's invalid source to stop.")
          continue
        }
        #expect(
          events.contains {
            if case .failure(.notGanitSource) = $0 { return true }
            return false
          })
        #expect(repairCounts(events).isEmpty)
        #expect(await transport.count() == 1)
      } else {
        guard case .proposal = result else {
          Issue.record("Expected the provider's invalid source to use one repair.")
          continue
        }
        #expect(repairCounts(events) == [1])
        #expect(await transport.count() == 2)
      }
    }
  }

}
