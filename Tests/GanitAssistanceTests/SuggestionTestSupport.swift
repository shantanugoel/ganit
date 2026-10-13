import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

func assistanceContext() throws -> EvaluationContext {
  try EvaluationContext(
    localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates, angleMode: .radians,
    precision: PrecisionContext(significantDecimalDigits: 15), now: Date(timeIntervalSince1970: 0),
    calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!)
}

func assistanceSnapshot(_ text: String) throws -> AssistanceSnapshot {
  let source = SheetSource(text)
  var calculator = SheetCalculator()
  return try calculator.assistanceSnapshot(
    source, context: assistanceContext(), target: source.lines.last!.id)
}

func fixtureSettings(local: Bool = false, enabled: Bool = true, model: String = "fixture")
  -> AssistantSettings
{
  AssistantSettings(
    isEnabled: enabled,
    endpoint: URL(string: local ? "http://127.0.0.1:1/v1" : "https://fixture.invalid/v1")!,
    model: model)
}

func outcome(_ kind: String, _ fields: [String: Any] = [:]) throws -> Data {
  var root = fields
  root["schemaVersion"] = 1
  root["kind"] = kind
  return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

func billProposal(
  _ snapshot: AssistanceSnapshot, source: String = "(bill + 10%) / 4", binding: String? = nil,
  literal: String = "10%"
) throws -> Data {
  let percent = try #require(snapshot.evidence().first { $0.text == "10%" }?.handle)
  let count = try #require(snapshot.evidence().first { $0.text == "four" }?.handle)
  let relation = try #require(
    snapshot.evidence().first { $0.kind == "relation" && $0.source == "T1" }?.handle)
  let bill = try #require(snapshot.inventory.first { $0.name == "bill" }?.handle)
  return try outcome(
    "proposal",
    [
      "candidates": [
        [
          "id": "C1", "edits": [["target": "T1", "replacement": source]],
          "bindings": [["symbol": "bill", "source": binding ?? bill]],
          "literals": [["text": literal, "evidence": percent], ["text": "4", "evidence": count]],
          "relations": [["rule": "interpretation", "evidence": relation]], "assumptions": [],
          "summary": "Add the tip, then split equally.",
        ]
      ]
    ])
}

actor FakeSuggestionTransport: SuggestionTransport {
  enum Step: Sendable {
    case reply(Data)
    case failure(SuggestionTransportError)
    case pending
  }
  private var steps: [Step]
  private(set) var requests: [SuggestionWireRequest] = []
  private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(_ steps: [Step]) { self.steps = steps }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    let index = requests.count
    requests.append(request)
    let ready = waiters.filter { requests.count >= $0.0 }
    waiters.removeAll { requests.count >= $0.0 }
    for item in ready { item.1.resume() }
    let step = steps.isEmpty ? Step.pending : steps.removeFirst()
    switch step {
    case .reply(let data): return data
    case .failure(let error): throw error
    case .pending: return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
  }
  func count() -> Int { requests.count }
  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
  func complete(_ index: Int, data: Data) {
    pending.removeValue(forKey: index)?.resume(returning: data)
  }
}

final class FakeSuggestionClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
  private var cancelled: Set<UUID> = []
  private var waits: [(Int, CheckedContinuation<Void, Never>)] = []
  var clock: SuggestionClock {
    SuggestionClock(
      now: { self.lock.withLock { self.time } },
      sleepUntil: { deadline in
        try await self.sleep(until: deadline)
      })
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
          let ready = waits.filter { sleepers.count >= $0.0 }
          waits.removeAll { sleepers.count >= $0.0 }
          for item in ready { item.1.resume() }
        }
      }
    } onCancel: {
      self.lock.withLock {
        if let item = self.sleepers.removeValue(forKey: id) {
          item.1.resume(throwing: CancellationError())
        } else {
          self.cancelled.insert(id)
        }
      }
    }
  }
  func advance(to time: TimeInterval) {
    lock.withLock {
      self.time = time
      let ready = sleepers.filter { $0.value.0 <= time }
      for (id, item) in ready {
        sleepers.removeValue(forKey: id)
        item.1.resume()
      }
    }
  }
  func waitForSleepers(_ count: Int) async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if sleepers.count >= count {
          continuation.resume()
        } else {
          waits.append((count, continuation))
        }
      }
    }
  }
}

actor SuggestionEventLog {
  private(set) var events: [SuggestionJobEvent] = []
  private var waits: [(SuggestionJobState, CheckedContinuation<Void, Never>)] = []
  func append(_ event: SuggestionJobEvent) {
    events.append(event)
    if case .state(let state) = event {
      let ready = waits.filter { $0.0 == state }
      waits.removeAll { $0.0 == state }
      for item in ready { item.1.resume() }
    }
  }
  func waitFor(_ state: SuggestionJobState) async {
    if events.contains(where: {
      if case .state(let value) = $0 { return value == state }
      return false
    }) {
      return
    }
    await withCheckedContinuation { waits.append((state, $0)) }
  }
  func bodies() -> [Data] {
    events.compactMap {
      if case .requestBody(let body) = $0 { return body }
      return nil
    }
  }
}
