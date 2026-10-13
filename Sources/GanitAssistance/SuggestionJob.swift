import Foundation
import GanitData
import GanitEngine
import GanitSuggestionProtocol

public enum SuggestionJobState: String, Sendable {
  case idle, preparing, requesting, checking, repairing, needsContext, needsChoice
  case ready, stale, applied, dismissed, cancelled, failed, paused
}

public enum SuggestionJobOrigin: Sendable { case manual, automatic }

public struct SuggestionPermission: Sendable {
  public let contextAccepted: Bool
  public let automaticArea: UUID?
  public init(contextAccepted: Bool = false, automaticArea: UUID? = nil) {
    self.contextAccepted = contextAccepted
    self.automaticArea = automaticArea
  }
}

public struct SuggestionJobInput: Sendable {
  public let document: UUID
  public let snapshot: AssistanceSnapshot
  public let settings: AssistantSettings
  public let permission: SuggestionPermission
  public let origin: SuggestionJobOrigin
  public let includedRecords: Set<String>
  public let choices: [String: String]
  public let approvedAssumptions: Set<String>
  public let retry: Bool

  public init(
    document: UUID, snapshot: AssistanceSnapshot, settings: AssistantSettings,
    permission: SuggestionPermission = SuggestionPermission(),
    origin: SuggestionJobOrigin = .manual,
    includedRecords: Set<String> = [], choices: [String: String] = [:],
    approvedAssumptions: Set<String> = [], retry: Bool = false
  ) {
    self.document = document
    self.snapshot = snapshot
    self.settings = settings
    self.permission = permission
    self.origin = origin
    self.includedRecords = includedRecords
    self.choices = choices
    self.approvedAssumptions = approvedAssumptions
    self.retry = retry
  }
}

public enum SuggestionJobEvent: Sendable {
  case state(SuggestionJobState)
  case requestBody(Data)
  case includeContext(records: [AssistanceSymbol], reason: String)
}

public enum SuggestionJobFailure: String, Error, Equatable, Sendable {
  case providerNotReady, permissionRequired, providerBusy, deadline, transport, schema
  case contextLimit, contextDenied, requestLimit, repeatedCandidate, repeatedFailure, validation
}

public enum SuggestionJobResult: Sendable {
  case proposal([AssistanceCheckedCandidate])
  case clarify(SuggestionClarification)
  case unsupported(String)
  case failed(SuggestionJobFailure)
  case cancelled, dismissed, stale, paused
}

public struct SuggestionJob: Sendable {
  public let id: UUID
  public let result: Task<SuggestionJobResult, Never>
  public func cancel() { result.cancel() }
}

/// Tests supply a clock that advances without real sleeps.
public struct SuggestionClock: Sendable {
  public let now: @Sendable () -> TimeInterval
  public let sleepUntil: @Sendable (TimeInterval) async throws -> Void

  public init(
    now: @escaping @Sendable () -> TimeInterval,
    sleepUntil: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.now = now
    self.sleepUntil = sleepUntil
  }

  public static let continuous = SuggestionClock(
    now: { ProcessInfo.processInfo.systemUptime },
    sleepUntil: { deadline in
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
      try Task.checkCancellation()
    })
}
