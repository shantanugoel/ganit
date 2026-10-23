import CryptoKit
import Foundation
import GanitData
import GanitEngine
import GanitSuggestionProtocol

/// Share one coordinator across windows. Networking remains in GanitData.
public actor SuggestionCoordinator {
  public typealias Observer = @Sendable (SuggestionJobEvent) async -> Void
  private struct Provider: Hashable {
    let endpoint: URL
  }
  private struct CacheKey: Hashable {
    let document: UUID
    let source: String
    let digest: String
    let provider: Provider
    let model: String
  }
  private struct CacheEntry {
    let key: CacheKey
    let payload: Data
    var bytes: Int {
      payload.count + key.source.utf8.count + key.digest.utf8.count
        + key.provider.endpoint.absoluteString.utf8.count + key.model.utf8.count
    }
  }
  private final class Record {
    let input: SuggestionJobInput
    let observer: Observer
    let provider: Provider
    let key: CacheKey
    let deadline: TimeInterval
    var included: Set<String>
    var requests = 0
    var repairs = 0
    var pendingRepair = false
    var failure: AskFailure?
    var task: Task<SuggestionJobResult, Never>?
    var override: SuggestionJobResult?
    var requestedContext: Set<String> = []
    var consent: CheckedContinuation<Set<String>?, Never>?
    var slot: CheckedContinuation<Void, Never>?
    init(
      input: SuggestionJobInput, observer: @escaping Observer, provider: Provider,
      key: CacheKey, deadline: TimeInterval
    ) {
      self.input = input
      self.observer = observer
      self.provider = provider
      self.key = key
      self.deadline = deadline
      included = input.includedRecords
    }
  }
  private struct Accounting {
    var jobs: [TimeInterval] = []
    var wires: [TimeInterval] = []
    var lastJob: TimeInterval?
  }

  private let transport: any SuggestionTransport
  private let clock: SuggestionClock
  private var records: [UUID: Record] = [:]
  private var active: [Provider: UUID] = [:]
  private var pending: [Provider: UUID] = [:]
  private var accounting: [Provider: Accounting] = [:]
  private var areaJobs: [UUID: Int] = [:]
  private var cache: [CacheEntry] = []
  private var cacheBytes = 0

  public init(
    transport: any SuggestionTransport = ProviderSuggestionTransport(),
    clock: SuggestionClock = .continuous
  ) {
    self.transport = transport
    self.clock = clock
  }

  public func start(_ input: SuggestionJobInput, observer: @escaping Observer = { _ in })
    -> SuggestionJob
  {
    let id = UUID()
    func terminal(_ result: SuggestionJobResult) -> SuggestionJob {
      SuggestionJob(
        id: id,
        result: Task {
          if case .failed = result {
            await observer(.failure(.noUsefulAnswer))
            await observer(.state(.failed))
          }
          return result
        })
    }
    guard !Task.isCancelled else { return terminal(.cancelled) }
    guard input.settings.isReady else { return terminal(.failed(.providerNotReady)) }
    guard input.permission.contextAccepted,
      input.origin == .manual || input.permission.automaticArea != nil
    else { return terminal(.failed(.permissionRequired)) }
    let provider = Provider(endpoint: Assistant.chatCompletionsURL(input.settings.endpoint))
    let key: CacheKey
    do { key = try contextKey(input, provider: provider) } catch {
      return terminal(.failed(.contextLimit))
    }
    guard !Task.isCancelled else { return terminal(.cancelled) }
    if !input.retry, !input.allowsExplanation,
      let index = cache.firstIndex(where: { $0.key == key })
    {
      let entry = cache.remove(at: index)
      cache.append(entry)
      return SuggestionJob(
        id: id, result: Task { await self.replay(entry.payload, input: input, observer: observer) })
    }
    if let other = active[provider], let record = records[other], input.origin == .manual {
      guard record.input.origin == .automatic else { return terminal(.failed(.providerBusy)) }
      stop(other, outcome: .cancelled)
      active.removeValue(forKey: provider)
    }
    let record = Record(
      input: input, observer: observer, provider: provider, key: key,
      deadline: clock.now() + (isLocal(input.settings.endpoint) ? 180 : 90))
    records[id] = record
    if active[provider] != nil {
      if let older = pending[provider] { stop(older, outcome: .cancelled) }
      pending[provider] = id
    } else {
      active[provider] = id
    }
    let task = Task { await self.perform(id) }
    record.task = task
    return SuggestionJob(id: id, result: task)
  }

  public func cancel(_ id: UUID) { stop(id, outcome: .cancelled) }
  public func dismiss(_ id: UUID) { stop(id, outcome: .dismissed) }
  public func stopAll() {
    for id in Array(records.keys) { stop(id, outcome: .cancelled) }
    pending = [:]
  }

  public func invalidate(document: UUID) {
    for (id, record) in records where record.input.document == document {
      stop(id, outcome: .stale)
    }
    cache.removeAll { $0.key.document == document }
    cacheBytes = cache.reduce(0) { $0 + $1.bytes }
  }

  /// Only the editor's explicit Include More Context action calls this method.
  public func includeContext(job id: UUID, handles: Set<String>) {
    guard let record = records[id], record.override == nil,
      handles == record.requestedContext, record.consent != nil
    else { return }
    record.consent?.resume(returning: handles)
    record.consent = nil
  }

  public func denyContext(job id: UUID) {
    guard let record = records[id] else { return }
    record.consent?.resume(returning: nil)
    record.consent = nil
  }

  private func stop(_ id: UUID, outcome: SuggestionJobResult) {
    guard let record = records[id] else { return }
    record.override = outcome
    record.consent?.resume(returning: nil)
    record.consent = nil
    record.slot?.resume()
    record.slot = nil
    record.task?.cancel()
  }

  private func perform(_ id: UUID) async -> SuggestionJobResult {
    guard let record = records[id] else { return .cancelled }
    await record.observer(.state(.preparing))
    do {
      if active[record.provider] != id {
        try await SuggestionDeadline<Void>.run(clock: clock, deadline: record.deadline) {
          await self.waitForSlot(id)
        }
      }
      try ensureActive(id)
      if record.input.origin == .automatic, !reserveAutomaticJob(record) {
        return await finish(id, result: .paused)
      }
      var structured = true
      var effort = true
      var feedback: [String: Any]?
      var seenSources: Set<String> = []
      var seenFailures: Set<String> = []
      while record.requests < SuggestionLimits.requestsPerJob {
        try ensureActive(id)
        let context = try requestContext(record, feedback: feedback)
        let wire = try SuggestionWireRequest(
          settings: record.input.settings, context: context, structured: structured,
          effort: effort, allowsExplanation: record.input.allowsExplanation,
          allowsAnswer: record.input.allowsAnswer && !record.input.allowsExplanation
            && SuggestionRequestContext.canAnswer(record.input.snapshot, including: record.included)
        )
        guard record.input.origin != .automatic || reserveAutomaticWire(record) else {
          return await finish(id, result: .paused)
        }
        await record.observer(.requestBody(wire.body))
        try ensureActive(id)
        await record.observer(.state(record.requests == 0 ? .requesting : .repairing))
        if record.pendingRepair {
          record.repairs += 1
          record.pendingRepair = false
          await record.observer(.repairStarted(record.repairs))
          try ensureActive(id)
        }
        record.requests += 1
        let payload: Data
        do {
          payload = try await SuggestionDeadline<Data>.run(
            clock: clock,
            deadline: min(record.deadline, clock.now() + wire.timeout)
          ) { [transport] in
            try await transport.send(wire)
          }
        } catch SuggestionTransportError.unexpectedStatus(let status)
          where structured && [400, 422].contains(status)
        {
          // A server that refuses the ask itself drops both optional fields, the
          // way the line-level request does: an unknown field is likelier to be
          // accepted absent than present and wrong.
          structured = false
          effort = false
          continue
        } catch SuggestionDecodingError.numericProse {
          // The transport answers this on the reply's behalf: words that carried
          // a number. Asking the model to fix them only spends a request, because
          // the repair prompt repeats a schema that says nothing about the ban.
          record.failure = .modelSuppliedNumbers
          return await finish(id, result: .failed(.schema))
        } catch let error where Self.isInvalidReply(error) {
          if let transportError = error as? SuggestionTransportError,
            case .rejectedReply(let reply) = transportError
          {
            await record.observer(
              .rejectedReply(
                String(decoding: reply.prefix(SuggestionLimits.payloadBytes), as: UTF8.self)))
          }
          record.failure = .notGanitSource
          guard seenFailures.insert("schema").inserted else {
            return await finish(id, result: .failed(.repeatedFailure))
          }
          guard scheduleRepair(record) else {
            return await finish(
              id,
              result: .failed(
                record.requests == SuggestionLimits.requestsPerJob ? .requestLimit : .schema))
          }
          feedback = [
            "code": "schema.invalidResponse",
            "message": "Return one response that matches the supplied JSON schema.",
          ]
          continue
        }
        try ensureActive(id)
        let outcome: SuggestionOutcome
        do { outcome = try SuggestionDecoder.decode(payload) }
        catch SuggestionDecodingError.numericProse {
          // Asking the model to fix words that carried numbers only spends a
          // request: the schema it is handed says nothing about the ban, so the
          // repaired reply repeats the offence. Stop and say what happened.
          record.failure = .modelSuppliedNumbers
          return await finish(id, result: .failed(.schema))
        } catch {
          let raw = String(decoding: payload.prefix(SuggestionLimits.payloadBytes), as: UTF8.self)
          await record.observer(.rejectedReply(raw))
          record.failure = .notGanitSource
          guard seenFailures.insert("schema").inserted else {
            return await finish(id, result: .failed(.repeatedFailure))
          }
          guard scheduleRepair(record) else {
            return await finish(
              id,
              result: .failed(
                record.requests == SuggestionLimits.requestsPerJob ? .requestLimit : .schema))
          }
          feedback = [
            "code": "schema.invalidResponse",
            "message": "Return one response that matches the supplied JSON schema.",
          ]
          continue
        }
        switch outcome {
        case .answer(let text):
          guard record.input.allowsAnswer, !record.input.allowsExplanation,
            record.input.origin == .manual,
            SuggestionRequestContext.canAnswer(record.input.snapshot, including: record.included)
          else { return await finish(id, result: .failed(.schema)) }
          return await finish(id, result: .answer(text))
        case .explanation(let text):
          guard record.input.allowsExplanation, record.input.origin == .manual else {
            return await finish(id, result: .failed(.schema))
          }
          return await finish(id, result: .explanation(text))
        case .unsupported(let reason):
          store(
            payload,
            key: try contextKey(record.input, provider: record.provider, included: record.included))
          return await finish(id, result: .unsupported(reason))
        case .clarify(let question):
          store(
            payload,
            key: try contextKey(record.input, provider: record.provider, included: record.included))
          return await finish(id, result: .clarify(question))
        case .needContext(let handles, let reason):
          let requested = Set(handles)
          guard requested.isSubset(of: Set(record.input.snapshot.inventory.map(\.handle))) else {
            return await finish(id, result: .failed(.contextDenied))
          }
          let permitted = Set(record.input.snapshot.inventory.filter(\.matchesTarget).map(\.handle))
            .union(record.included)
          if !requested.isSubset(of: permitted) {
            record.requestedContext = requested
            let approved = try await SuggestionDeadline<Set<String>?>.run(
              clock: clock, deadline: record.deadline
            ) {
              await self.waitForConsent(id, reason: reason)
            }
            try ensureActive(id)
            guard let approved else { return await finish(id, result: .failed(.contextDenied)) }
            record.included.formUnion(approved)
          }
          feedback = ["code": "context.included", "records": handles]
          seenFailures = []
        case .proposal(let candidates):
          await record.observer(.state(.checking))
          var checked: [AssistanceCheckedCandidate] = []
          var failures: [AssistanceValidationFailure] = []
          var rejectedSources: [String] = []
          for candidate in candidates {
            let source = candidate.edits.map(\.replacement).joined(separator: "\n")
            guard seenSources.insert(source).inserted else {
              return await finish(id, result: .failed(.repeatedCandidate))
            }
            do {
              let input = record.input
              let included = record.included
              let result = try await SuggestionDeadline<AssistanceCheckedCandidate>.run(
                clock: clock, deadline: record.deadline
              ) {
                try await SuggestionLocalChecking.check(
                  candidate, snapshot: input.snapshot,
                  handles: included, choices: input.choices, assumptions: input.approvedAssumptions,
                  userRevisedInputs: input.userRevisedInputs)
              }
              checked.append(result)
            } catch let error as AssistanceValidationFailure {
              failures.append(error)
              rejectedSources.append(source)
              record.failure = .rejectedByEngine(error)
              await record.observer(.rejectedCandidate(source: source, failure: error))
            }
          }
          try ensureActive(id)
          if !checked.isEmpty {
            store(
              payload,
              key: try contextKey(
                record.input, provider: record.provider, included: record.included))
            return await finish(id, result: .proposal(checked))
          }
          guard let failure = failures.first else {
            return await finish(id, result: .failed(.validation))
          }
          record.failure = .rejectedByEngine(failure)
          let code = failure.code.rawValue
          guard seenFailures.insert(code).inserted else {
            return await finish(id, result: .failed(.repeatedFailure))
          }
          guard scheduleRepair(record) else {
            return await finish(
              id,
              result: .failed(
                record.requests == SuggestionLimits.requestsPerJob ? .requestLimit : .validation))
          }
          feedback = Self.validationFeedback(
            failure, source: rejectedSources.first ?? "", context: context)
          feedback?["rejectedSource"] = rejectedSources.first
        }
      }
      return await finish(id, result: .failed(.requestLimit))
    } catch is CancellationError {
      return await finish(id, result: record.override ?? .cancelled)
    } catch let failure as SuggestionJobFailure {
      return await finish(id, result: .failed(failure))
    } catch is AssistanceSnapshotError {
      return await finish(id, result: .failed(.contextLimit))
    } catch is SuggestionTransportError {
      return await finish(id, result: .failed(.transport))
    } catch { return await finish(id, result: .failed(.transport)) }
  }

  private static func isInvalidReply(_ error: any Error) -> Bool {
    // A number in the model's words is a policy rejection with its own reason;
    // everything the contract refuses outright is a repairable malformed reply.
    if let error = error as? SuggestionDecodingError, error != .numericProse { return true }
    guard let error = error as? SuggestionTransportError else { return false }
    switch error {
    case .malformedCompletion, .rejectedReply: return true
    default: return false
    }
  }

  private func scheduleRepair(_ record: Record) -> Bool {
    guard record.requests < SuggestionLimits.requestsPerJob,
      record.repairs
        < min(max(0, record.input.settings.repairAttempts), SuggestionLimits.requestsPerJob - 1)
    else { return false }
    record.pendingRepair = true
    return true
  }

  private static func validationFeedback(
    _ failure: AssistanceValidationFailure, source: String, context: Data
  ) -> [String: Any] {
    func spans(_ ranges: [SourceRange]) -> [[String: Int]] {
      ranges.map { ["start": $0.lowerBound, "end": $0.upperBound] }
    }
    var feedback: [String: Any] = [
      "code": failure.code.rawValue, "message": failure.message, "spans": spans(failure.ranges),
    ]
    switch failure.engineResult {
    case .evaluationFailure(let error):
      feedback["engineCode"] = error.code.rawValue
      if error.code == .unknownFunction,
        let root = try? JSONSerialization.jsonObject(with: context) as? [String: Any],
        let catalog = root["catalog"] as? [String: Any],
        let functions = catalog["functions"] as? [[String: Any]]
      {
        let names = functions.compactMap { $0["name"] as? String }
        feedback["availableFunctions"] =
          source.lowercased().contains("mortgage")
          ? ["pmt", "fv", "pv"].filter { names.contains($0) } : names
      }
      feedback["engineDiagnostic"] =
        [
          "code": error.code.rawValue, "messageKey": error.messageKey,
          "severity": error.severity.rawValue, "spans": spans(error.ranges),
          "fixes": error.fixIts.map {
            [
              "span": ["start": $0.range.lowerBound, "end": $0.range.upperBound],
              "replacement": $0.replacement, "messageKey": $0.messageKey,
            ] as [String: Any]
          },
        ] as [String: Any]
    case .syntaxFailure(let diagnostics):
      feedback["engineDiagnostics"] = diagnostics.map {
        [
          "code": $0.messageKey, "severity": $0.severity.rawValue, "spans": spans([$0.range]),
        ] as [String: Any]
      }
    default: break
    }
    return feedback
  }

  private func ensureActive(_ id: UUID) throws {
    try Task.checkCancellation()
    guard let record = records[id], record.override == nil, active[record.provider] == id else {
      throw CancellationError()
    }
    guard clock.now() < record.deadline else { throw SuggestionJobFailure.deadline }
  }

  private func waitForSlot(_ id: UUID) async {
    guard let record = records[id], record.override == nil, active[record.provider] != id else {
      return
    }
    await withCheckedContinuation { record.slot = $0 }
  }

  private func waitForConsent(_ id: UUID, reason: String) async -> Set<String>? {
    guard let record = records[id], record.override == nil else { return nil }
    return await withCheckedContinuation { continuation in
      record.consent = continuation
      Task { await self.announceContext(id, reason: reason) }
    }
  }

  private func announceContext(_ id: UUID, reason: String) async {
    guard let record = records[id], record.override == nil else { return }
    let observer = record.observer
    let requested = record.input.snapshot.inventory.filter {
      record.requestedContext.contains($0.handle)
    }
    await observer(.state(.needsContext))
    guard records[id]?.override == nil, records[id] != nil else { return }
    await observer(.includeContext(records: requested, reason: reason))
  }

  private func finish(_ id: UUID, result: SuggestionJobResult) async -> SuggestionJobResult {
    guard let record = records.removeValue(forKey: id) else { return .cancelled }
    let result = record.override ?? result
    record.consent?.resume(returning: nil)
    record.slot?.resume()
    if active[record.provider] == id {
      active.removeValue(forKey: record.provider)
      if let next = pending.removeValue(forKey: record.provider), let waiting = records[next] {
        active[record.provider] = next
        waiting.slot?.resume()
        waiting.slot = nil
      }
    } else if pending[record.provider] == id {
      pending.removeValue(forKey: record.provider)
    }
    let state: SuggestionJobState
    switch result {
    case .proposal(let checked): state = checked.allSatisfy(\.isApplicable) ? .ready : .needsChoice
    case .explanation, .answer: state = .ready
    case .clarify: state = .needsChoice
    case .unsupported, .failed: state = .failed
    case .cancelled: state = .cancelled
    case .dismissed: state = .dismissed
    case .stale: state = .stale
    case .paused: state = .paused
    }
    if state == .failed {
      let failure: AskFailure
      switch result {
      case .failed(.transport), .failed(.deadline): failure = .unreachable
      case .unsupported: failure = .noUsefulAnswer
      default: failure = record.failure ?? .noUsefulAnswer
      }
      await record.observer(.failure(failure))
    }
    await record.observer(.state(state))
    return result
  }

  private func requestContext(_ record: Record, feedback: [String: Any]?) throws -> Data {
    let data = try SuggestionRequestContext.data(
      snapshot: record.input.snapshot,
      including: record.included, choices: record.input.choices,
      userRevisedInputs: record.input.userRevisedInputs)
    guard let feedback else { return data }
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["feedback"] = feedback
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  private func contextKey(
    _ input: SuggestionJobInput, provider: Provider, included: Set<String>? = nil
  ) throws -> CacheKey {
    let data = try SuggestionRequestContext.data(
      snapshot: input.snapshot,
      including: included ?? input.includedRecords, choices: input.choices,
      userRevisedInputs: input.userRevisedInputs)
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var settings = root["settings"] as! [String: Any]
    settings.removeValue(forKey: "now")
    root["settings"] = settings
    if input.allowsExplanation { root["allowsExplanation"] = true }
    if input.allowsAnswer { root["allowsAnswer"] = true }
    let canonical = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    return CacheKey(
      document: input.document, source: input.snapshot.source.text,
      digest: SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(),
      provider: provider, model: input.settings.model)
  }

  private func replay(_ payload: Data, input: SuggestionJobInput, observer: Observer) async
    -> SuggestionJobResult
  {
    do {
      switch try SuggestionDecoder.decode(payload) {
      case .explanation, .answer: return .failed(.schema)
      case .proposal(let candidates):
        var checked: [AssistanceCheckedCandidate] = []
        for candidate in candidates {
          try Task.checkCancellation()
          if let value = try? await SuggestionLocalChecking.check(
            candidate, snapshot: input.snapshot,
            handles: input.includedRecords, choices: input.choices,
            assumptions: input.approvedAssumptions, userRevisedInputs: input.userRevisedInputs)
          {
            checked.append(value)
          }
        }
        try Task.checkCancellation()
        guard !checked.isEmpty else { return .stale }
        await observer(.state(checked.allSatisfy(\.isApplicable) ? .ready : .needsChoice))
        return .proposal(checked)
      case .clarify(let value):
        await observer(.state(.needsChoice))
        return .clarify(value)
      case .unsupported(let reason):
        await observer(.failure(.noUsefulAnswer))
        await observer(.state(.failed))
        return .unsupported(reason)
      case .needContext: return .failed(.contextDenied)
      }
    } catch is CancellationError { return .cancelled } catch { return .stale }
  }

  private func store(_ payload: Data, key: CacheKey) {
    if let index = cache.firstIndex(where: { $0.key == key }) {
      cacheBytes -= cache.remove(at: index).bytes
    }
    let entry = CacheEntry(key: key, payload: payload)
    guard entry.bytes <= 4 * 1_024 * 1_024 else { return }
    cache.append(entry)
    cacheBytes += entry.bytes
    while cache.count > 128 || cacheBytes > 4 * 1_024 * 1_024 {
      cacheBytes -= cache.removeFirst().bytes
    }
  }

  private func reserveAutomaticJob(_ record: Record) -> Bool {
    let now = clock.now()
    var value = accounting[record.provider] ?? Accounting()
    value.jobs.removeAll { now - $0 >= 60 }
    guard value.jobs.count < 2, value.lastJob.map({ now - $0 >= 15 }) != false,
      let area = record.input.permission.automaticArea, areaJobs[area, default: 0] < 12
    else { return false }
    value.jobs.append(now)
    value.lastJob = now
    accounting[record.provider] = value
    areaJobs[area, default: 0] += 1
    return true
  }

  private func reserveAutomaticWire(_ record: Record) -> Bool {
    let now = clock.now()
    var value = accounting[record.provider] ?? Accounting()
    value.wires.removeAll { now - $0 >= 60 }
    guard value.wires.count < 6 else { return false }
    value.wires.append(now)
    accounting[record.provider] = value
    return true
  }

  private func isLocal(_ url: URL) -> Bool {
    ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host() ?? "")
  }
}
