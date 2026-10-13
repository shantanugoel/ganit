import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@Suite
struct SuggestionCoordinatorTests {
  let source = "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways."

  private func input(
    _ snapshot: AssistanceSnapshot, document: UUID = UUID(), permission: Bool = true,
    origin: SuggestionJobOrigin = .manual, area: UUID? = nil, local: Bool = false,
    enabled: Bool = true,
    retry: Bool = false, model: String = "fixture"
  ) -> SuggestionJobInput {
    SuggestionJobInput(
      document: document, snapshot: snapshot,
      settings: fixtureSettings(local: local, enabled: enabled, model: model),
      permission: SuggestionPermission(contextAccepted: permission, automaticArea: area),
      origin: origin, retry: retry)
  }

  @Test func permissionAndProviderReadinessMakeZeroRequests() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([])
    let coordinator = SuggestionCoordinator(transport: transport)
    let denied = await coordinator.start(input(snapshot, permission: false))
    if case .failed(.permissionRequired) = await denied.result.value {
    } else {
      Issue.record("Expected permission rejection")
    }
    let disabled = await coordinator.start(input(snapshot, enabled: false))
    if case .failed(.providerNotReady) = await disabled.result.value {
    } else {
      Issue.record("Expected an unready provider")
    }
    let automatic = await coordinator.start(input(snapshot, origin: .automatic))
    if case .failed(.permissionRequired) = await automatic.result.value {
    } else {
      Issue.record("Expected automatic scope rejection")
    }
    #expect(await transport.count() == 0)
  }

  @Test func oneRequestProducesAnEngineCheckedPreviewAndExactInspectorBody() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.reply(try billProposal(snapshot))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let log = SuggestionEventLog()
    let job = await coordinator.start(input(snapshot), observer: { await log.append($0) })
    guard case .proposal(let proposals) = await job.result.value else {
      Issue.record("Expected a checked proposal")
      return
    }
    #expect(proposals.count == 1)
    #expect(proposals[0].isApplicable)
    #expect(proposals[0].sourceBefore == source)
    #expect(await transport.count() == 1)
    #expect(await log.bodies() == transport.requests.map(\.body))
  }

  @Test func twoCorrectionsUseAtMostThreeWireRequests() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([
      .reply(try billProposal(snapshot, source: "(other + 10%) / 4", binding: "S99")),
      .reply(try billProposal(snapshot, source: "(bill + 15%) / 4", literal: "15%")),
      .reply(try billProposal(snapshot)),
    ])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(input(snapshot))
    if case .proposal = await job.result.value {
    } else {
      Issue.record("Expected a corrected proposal")
    }
    #expect(await transport.count() == 3)
    let messages = await transport.requests.dropFirst().map {
      String(decoding: $0.body, as: UTF8.self)
    }
    #expect(messages[0].contains("unknownBinding"))
    #expect(messages[1].contains("missingEvidence"))
  }

  @Test func formatFallbackConsumesTheSameBudget() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([
      .failure(.unexpectedStatus(422)),
      .reply(try billProposal(snapshot, source: "(bill + 15%) / 4", literal: "15%")),
      .reply(try billProposal(snapshot)),
    ])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(input(snapshot))
    if case .proposal = await job.result.value {
    } else {
      Issue.record("Expected a format fallback and repair")
    }
    #expect(await transport.count() == 3)
    let bodies = await transport.requests.map { String(decoding: $0.body, as: UTF8.self) }
    #expect(bodies[0].contains("response_format"))
    #expect(!bodies[1].contains("response_format"))
    #expect(!bodies[2].contains("response_format"))
  }

  @Test func transportFailuresHaveNoAutomaticRetryOrSuccessfulCacheEntry() async throws {
    let snapshot = try assistanceSnapshot(source)
    let document = UUID()
    let transport = FakeSuggestionTransport([
      .failure(.unexpectedStatus(503)), .reply(try billProposal(snapshot)),
    ])
    let coordinator = SuggestionCoordinator(transport: transport)
    let first = await coordinator.start(input(snapshot, document: document))
    if case .failed(.transport) = await first.result.value {
    } else {
      Issue.record("Expected a transport failure")
    }
    #expect(await transport.count() == 1)
    let retry = await coordinator.start(input(snapshot, document: document))
    if case .proposal = await retry.result.value {
    } else {
      Issue.record("Expected a fresh request")
    }
    #expect(await transport.count() == 2)
  }

  @Test func repeatedCandidateAndMalformedJSONStopWithinBudget() async throws {
    let snapshot = try assistanceSnapshot(source)
    let bad = try billProposal(snapshot, binding: "S99")
    for replies in [[bad, bad], [Data("not json".utf8), Data("not json".utf8)]] {
      let transport = FakeSuggestionTransport(replies.map(FakeSuggestionTransport.Step.reply))
      let coordinator = SuggestionCoordinator(transport: transport)
      let job = await coordinator.start(input(snapshot))
      if case .failed = await job.result.value {} else { Issue.record("Expected bounded failure") }
      #expect(await transport.count() == 2)
    }
  }

  @Test func deniedContextCannotLeaveTheSnapshotAndApprovedContextSharesTheJobBudget() async throws
  {
    let snapshot = try assistanceSnapshot("hidden = 10 INR\nAdd a 2% tip to the amount above.")
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    let need = try outcome("need_context", ["records": [handle], "reason": "Identify the amount."])
    let finished = try outcome("unsupported", ["reason": "Fixture ends after context inspection."])
    let transport = FakeSuggestionTransport([.reply(need), .reply(finished)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let log = SuggestionEventLog()
    let job = await coordinator.start(input(snapshot), observer: { await log.append($0) })
    await log.waitFor(.needsContext)
    #expect(await transport.count() == 1)
    let firstBody = await transport.requests[0].body
    #expect(!String(decoding: firstBody, as: UTF8.self).contains("hidden"))
    await coordinator.includeContext(job: job.id, handles: [handle])
    if case .unsupported = await job.result.value {
    } else {
      Issue.record("Expected one approved follow-up")
    }
    #expect(await transport.count() == 2)
    let secondBody = await transport.requests[1].body
    #expect(String(decoding: secondBody, as: UTF8.self).contains("hidden"))
    #expect(await log.bodies() == transport.requests.map(\.body))
  }

  @Test func fakeClockDeadlineFinishesBeforeAnUncooperativeLateReply() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending])
    let clock = FakeSuggestionClock()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let job = await coordinator.start(input(snapshot))
    await transport.waitForRequests(1)
    await clock.waitForSleepers(1)
    clock.advance(to: 30)
    if case .failed(.deadline) = await job.result.value {
    } else {
      Issue.record("Expected a remote request deadline")
    }
    await transport.complete(0, data: try billProposal(snapshot))
    #expect(await transport.count() == 1)
  }

  @Test func sourceInvalidationAndStopIgnoreLateReplies() async throws {
    let snapshot = try assistanceSnapshot(source)
    let document = UUID()
    let transport = FakeSuggestionTransport([.pending])
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(input(snapshot, document: document))
    await transport.waitForRequests(1)
    await coordinator.invalidate(document: document)
    if case .stale = await job.result.value {} else { Issue.record("Expected stale cancellation") }
    await transport.complete(0, data: try billProposal(snapshot))
    #expect(await transport.count() == 1)
  }

  @Test func manualJobsPreemptAutomaticJobsAcrossWindows() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending, .reply(try billProposal(snapshot))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let automatic = await coordinator.start(input(snapshot, origin: .automatic, area: UUID()))
    await transport.waitForRequests(1)
    let manual = await coordinator.start(input(snapshot))
    if case .cancelled = await automatic.result.value {
    } else {
      Issue.record("Expected automatic cancellation")
    }
    if case .proposal = await manual.result.value {
    } else {
      Issue.record("Expected manual priority")
    }
    await transport.complete(0, data: try billProposal(snapshot))
    #expect(await transport.count() == 2)
  }

  @Test func exactDuplicateReusesCheckedSourceWithoutAnotherWireRequest() async throws {
    let snapshot = try assistanceSnapshot(source)
    let document = UUID()
    let transport = FakeSuggestionTransport([.reply(try billProposal(snapshot))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let first = await coordinator.start(input(snapshot, document: document))
    if case .proposal = await first.result.value {} else { Issue.record("Expected a proposal") }
    let second = await coordinator.start(input(snapshot, document: document))
    if case .proposal = await second.result.value {} else { Issue.record("Expected local replay") }
    #expect(await transport.count() == 1)
  }
  @Test func providerHasOneActiveJobEvenWhenModelsDiffer() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending])
    let coordinator = SuggestionCoordinator(transport: transport)
    let first = await coordinator.start(input(snapshot))
    await transport.waitForRequests(1)
    let second = await coordinator.start(input(snapshot, model: "another-model"))
    if case .failed(.providerBusy) = await second.result.value {
    } else {
      Issue.record("Expected one active provider job")
    }
    #expect(await transport.count() == 1)
    await coordinator.stopAll()
    if case .cancelled = await first.result.value {} else { Issue.record("Expected cancellation") }
    await transport.complete(0, data: try billProposal(snapshot))
  }

  @Test func onlyLatestAutomaticTargetWaitsAcrossWindows() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending, .reply(try billProposal(snapshot))])
    let clock = FakeSuggestionClock()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let first = await coordinator.start(input(snapshot, origin: .automatic, area: UUID()))
    await transport.waitForRequests(1)
    let second = await coordinator.start(input(snapshot, origin: .automatic, area: UUID()))
    let third = await coordinator.start(input(snapshot, origin: .automatic, area: UUID()))
    if case .cancelled = await second.result.value {
    } else {
      Issue.record("Expected the older pending target to be cancelled")
    }
    clock.advance(to: 15)
    await transport.complete(0, data: try billProposal(snapshot))
    if case .proposal = await first.result.value {
    } else {
      Issue.record("Expected the first proposal")
    }
    if case .proposal = await third.result.value {
    } else {
      Issue.record("Expected the latest pending target")
    }
    #expect(await transport.count() == 2)
  }

  @Test func automaticLimitsPauseWithoutATimedRestart() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport(
      Array(repeating: .reply(try billProposal(snapshot)), count: 20))
    let clock = FakeSuggestionClock()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let area = UUID()
    let first = await coordinator.start(input(snapshot, origin: .automatic, area: area))
    if case .proposal = await first.result.value {
    } else {
      Issue.record("Expected the first automatic job")
    }
    let immediate = await coordinator.start(input(snapshot, origin: .automatic, area: area))
    if case .paused = await immediate.result.value {
    } else {
      Issue.record("Expected the minimum interval")
    }
    clock.advance(to: 15)
    let second = await coordinator.start(input(snapshot, origin: .automatic, area: area))
    if case .proposal = await second.result.value {
    } else {
      Issue.record("Expected the second minute job")
    }
    clock.advance(to: 30)
    let minuteLimit = await coordinator.start(input(snapshot, origin: .automatic, area: area))
    if case .paused = await minuteLimit.result.value {
    } else {
      Issue.record("Expected the minute limit")
    }
    #expect(await transport.count() == 2)
    clock.advance(to: 1000)
    #expect(await transport.count() == 2)
    for index in 0..<10 {
      clock.advance(to: 1000 + Double(index) * 60)
      let next = await coordinator.start(input(snapshot, origin: .automatic, area: area))
      if case .proposal = await next.result.value {
      } else {
        Issue.record("Expected a permitted area job")
      }
    }
    clock.advance(to: 2000)
    let areaLimit = await coordinator.start(input(snapshot, origin: .automatic, area: area))
    if case .paused = await areaLimit.result.value {
    } else {
      Issue.record("Expected the area session limit")
    }
    #expect(await transport.count() == 12)
    let manual = await coordinator.start(input(snapshot))
    if case .proposal = await manual.result.value {
    } else {
      Issue.record("Manual requests remain available")
    }
    #expect(await transport.count() == 13)
  }

  @Test func deniedAndUnknownContextRequestsDoNotSendFollowUps() async throws {
    let snapshot = try assistanceSnapshot("hidden = 10 INR\nAdd a 2% tip to the amount above.")
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    for requested in [handle, "S999"] {
      let transport = FakeSuggestionTransport([
        .reply(try outcome("need_context", ["records": [requested], "reason": "More context."]))
      ])
      let coordinator = SuggestionCoordinator(transport: transport)
      let log = SuggestionEventLog()
      let job = await coordinator.start(input(snapshot), observer: { await log.append($0) })
      if requested == handle {
        await log.waitFor(.needsContext)
        await coordinator.denyContext(job: job.id)
      }
      if case .failed(.contextDenied) = await job.result.value {
      } else {
        Issue.record("Expected denied context")
      }
      #expect(await transport.count() == 1)
    }
  }

  @Test func jobDeadlineAlsoBoundsContextApprovalWaits() async throws {
    let snapshot = try assistanceSnapshot("hidden = 10 INR\nAdd a 2% tip to the amount above.")
    let handle = try #require(snapshot.inventory.first { $0.name == "hidden" }?.handle)
    let transport = FakeSuggestionTransport([
      .reply(try outcome("need_context", ["records": [handle], "reason": "More context."]))
    ])
    let clock = FakeSuggestionClock()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let log = SuggestionEventLog()
    let job = await coordinator.start(input(snapshot), observer: { await log.append($0) })
    await log.waitFor(.needsContext)
    clock.advance(to: 90)
    if case .failed(.deadline) = await job.result.value {
    } else {
      Issue.record("Expected the logical job deadline")
    }
    await coordinator.includeContext(job: job.id, handles: [handle])
    #expect(await transport.count() == 1)
  }

  @Test func localRequestsUseTheLongerTimeoutWithTheSameFakeClock() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.pending])
    let clock = FakeSuggestionClock()
    let coordinator = SuggestionCoordinator(transport: transport, clock: clock.clock)
    let job = await coordinator.start(input(snapshot, local: true))
    await transport.waitForRequests(1)
    await clock.waitForSleepers(1)
    clock.advance(to: 120)
    if case .failed(.deadline) = await job.result.value {
    } else {
      Issue.record("Expected the local request deadline")
    }
    await transport.complete(0, data: try billProposal(snapshot))
  }

  @Test func cacheEvictsOldEntriesAt128AndRetryBypassesIt() async throws {
    let snapshot = try assistanceSnapshot(source)
    let payload = try outcome("unsupported", ["reason": "No applicable expression."])
    let transport = FakeSuggestionTransport(Array(repeating: .reply(payload), count: 140))
    let coordinator = SuggestionCoordinator(transport: transport)
    let documents = (0..<129).map { _ in UUID() }
    for document in documents {
      let job = await coordinator.start(input(snapshot, document: document))
      if case .unsupported = await job.result.value {
      } else {
        Issue.record("Expected a terminal outcome")
      }
    }
    #expect(await transport.count() == 129)
    let latest = await coordinator.start(input(snapshot, document: documents.last!))
    if case .unsupported = await latest.result.value {
    } else {
      Issue.record("Expected cached outcome")
    }
    #expect(await transport.count() == 129)
    let oldest = await coordinator.start(input(snapshot, document: documents[0]))
    if case .unsupported = await oldest.result.value {
    } else {
      Issue.record("Expected a fresh outcome")
    }
    #expect(await transport.count() == 130)
    let retry = await coordinator.start(input(snapshot, document: documents[0], retry: true))
    if case .unsupported = await retry.result.value {
    } else {
      Issue.record("Expected explicit retry")
    }
    #expect(await transport.count() == 131)
  }

  @Test func contextFollowUpsConsumeTheThreeRequestBudget() async throws {
    let snapshot = try assistanceSnapshot(source)
    let handle = try #require(snapshot.inventory.first { $0.name == "bill" }?.handle)
    let request = try outcome("need_context", ["records": [handle], "reason": "Check the amount."])
    let transport = FakeSuggestionTransport(Array(repeating: .reply(request), count: 4))
    let coordinator = SuggestionCoordinator(transport: transport)
    let job = await coordinator.start(input(snapshot))
    if case .failed(.requestLimit) = await job.result.value {
    } else {
      Issue.record("Expected the shared request limit")
    }
    #expect(await transport.count() == 3)
  }

  @Test func cacheEvictsByBytesAndDoesNotTransmitTheShadowSheet() async throws {
    let shadow = "// PRIVATE-FIXTURE-" + String(repeating: "x", count: 1_500_000)
    let snapshot = try assistanceSnapshot(shadow + "\n\n" + source)
    let reply = try outcome("unsupported", ["reason": "Synthetic cache fixture."])
    let transport = FakeSuggestionTransport(Array(repeating: .reply(reply), count: 4))
    let coordinator = SuggestionCoordinator(transport: transport)
    let documents = [UUID(), UUID(), UUID()]
    for document in documents {
      let job = await coordinator.start(input(snapshot, document: document))
      if case .unsupported = await job.result.value {
      } else {
        Issue.record("Expected a terminal fixture response")
      }
    }
    let again = await coordinator.start(input(snapshot, document: documents[0]))
    if case .unsupported = await again.result.value {
    } else {
      Issue.record("Expected a new request after byte eviction")
    }
    #expect(await transport.count() == 4)
    for request in await transport.requests {
      #expect(!String(decoding: request.body, as: UTF8.self).contains("PRIVATE-FIXTURE"))
    }
  }

  @Test func explicitMaterialChoicesAreSentAndHaveDistinctCacheKeys() async throws {
    let snapshot = try assistanceSnapshot("cost = 1000 INR\nFind a price with 20% profit on cost.")
    let evidence = snapshot.evidence()
    let cost = try #require(snapshot.inventory.first { $0.name == "cost" }?.handle)
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "cost + 20%")],
      bindings: [SuggestionBinding(symbol: "cost", source: cost)],
      literals: [
        SuggestionLiteral(
          text: "20%", evidence: try #require(evidence.first { $0.text == "20%" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Add profit based on cost.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try outcome("proposal", ["candidates": [object]])
    let transport = FakeSuggestionTransport([.reply(reply), .reply(reply)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let document = UUID()
    let initial = await coordinator.start(input(snapshot, document: document))
    guard case .proposal(let unresolved) = await initial.result.value else {
      Issue.record("Expected a choice")
      return
    }
    #expect(!unresolved[0].isApplicable)
    let selected = SuggestionJobInput(
      document: document, snapshot: snapshot, settings: fixtureSettings(),
      permission: SuggestionPermission(contextAccepted: true), choices: ["profit_basis": "cost"])
    for _ in 0..<2 {
      let job = await coordinator.start(selected)
      guard case .proposal(let proposals) = await job.result.value else {
        Issue.record("Expected a checked choice")
        return
      }
      #expect(proposals[0].isApplicable)
    }
    #expect(await transport.count() == 2)
    let body = await transport.requests[1].body
    let wire = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(wire["messages"] as? [[String: Any]])
    let context = try #require(messages.last?["content"] as? String)
    let records = try #require(
      JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
    #expect(records["selectedChoices"] as? [String: String] == ["profit_basis": "cost"])
  }

  @Test func importedFunctionCaptureChangesInvalidateReuseWithTheSameTargetText() async throws {
    func snapshot(_ definitions: SheetDefinitions) throws -> AssistanceSnapshot {
      let source = SheetSource("Use f with two.")
      var calculator = SheetCalculator(definitions: definitions)
      return try calculator.assistanceSnapshot(
        source, context: assistanceContext(), target: source.lines[0].id)
    }
    let firstDefinitions = try SheetDefinitions(
      source: "factor = 7\nf(x) = x * factor", context: assistanceContext())
    let first = try snapshot(firstDefinitions)
    let evidence = first.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "f(2)")],
      bindings: [
        SuggestionBinding(
          symbol: "f", source: try #require(first.inventory.first { $0.kind == "function" }?.handle)
        )
      ],
      literals: [
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Use the selected function.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try outcome("proposal", ["candidates": [object]])
    let transport = FakeSuggestionTransport([.reply(reply), .reply(reply)])
    let coordinator = SuggestionCoordinator(transport: transport)
    let document = UUID()
    let changed = try snapshot(
      SheetDefinitions(source: "factor = 9\nf(x) = x * factor", context: assistanceContext()))
    for (snapshot, expected) in [(first, 14), (try snapshot(firstDefinitions), 14), (changed, 18)] {
      let job = await coordinator.start(input(snapshot, document: document))
      guard case .proposal(let proposals) = await job.result.value else {
        Issue.record("Expected the current capture")
        return
      }
      #expect(proposals[0].result == .number(.integer(IntegerValue(expected))))
    }
    #expect(await transport.count() == 2)
  }

  @Test func aCancelledCallerCannotStartAWireRequest() async throws {
    let snapshot = try assistanceSnapshot(source)
    let transport = FakeSuggestionTransport([.failure(.unexpectedStatus(500))])
    let coordinator = SuggestionCoordinator(transport: transport)
    let gate = SuggestionStartGate()
    let input = input(snapshot)
    let task = Task {
      await gate.wait()
      let job = await coordinator.start(input)
      return await job.result.value
    }
    await gate.waitUntilWaiting()
    task.cancel()
    await gate.open()
    if case .cancelled = await task.value {
    } else {
      Issue.record("Expected cancellation before a request")
    }
    #expect(await transport.count() == 0)
  }

}
