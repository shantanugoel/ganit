import Foundation
import GanitData
import GanitEngine

/// Keeps currency rates current: loads the last-known-good snapshot, requests
/// new ones when the refresh policy allows, and publishes accepted rates.
///
/// A request that is already due starts at once. Later automatic requests
/// are scheduled one at a time with the system's background activity
/// scheduler, so there is no polling and the system may defer a request to
/// save energy. Nothing is scheduled while automatic updates are off.
@MainActor
public final class RateRefresher {
  public private(set) var rates: CurrencyRates
  public private(set) var isRequesting = false
  /// Called with newly accepted rates.
  public var ratesDidChange: (CurrencyRates) -> Void = { _ in }
  public var isAutomatic: Bool {
    didSet {
      schedule()
    }
  }

  private let store: RateSnapshotStore
  private let download: @Sendable () async throws -> RateSnapshot
  private let policy: RateRefreshPolicy
  private let now: () -> Date
  private var lastSuccess: Date?
  private var lastFailure: Date?
  private var consecutiveFailures = 0
  private var activity: NSBackgroundActivityScheduler?

  public init(
    store: RateSnapshotStore,
    isAutomatic: Bool,
    timeZone: TimeZone = .current,
    now: @escaping () -> Date = Date.init,
    download: @escaping @Sendable () async throws -> RateSnapshot = {
      try await RateDownloader().download()
    }
  ) {
    self.store = store
    self.isAutomatic = isAutomatic
    self.download = download
    self.now = now
    policy = RateRefreshPolicy(timeZone: timeZone)
    let snapshot = try? store.lastKnownGood()
    rates = snapshot.flatMap(Self.rates) ?? .none
    lastSuccess = snapshot?.metadata.retrievedAt
    schedule()
  }

  /// Requests rates now unless a request is running or one started less
  /// than a minute ago. Returns whether a request started.
  @discardableResult
  public func refreshNow() -> Bool {
    let lastAttempt = [lastSuccess, lastFailure].compactMap { $0 }.max()
    guard
      policy.allowsManualRefresh(lastAttempt: lastAttempt, isRequesting: isRequesting, now: now())
    else {
      return false
    }
    Task { await refresh() }
    return true
  }

  /// Downloads, validates, and commits a snapshot, then reschedules.
  func refresh() async {
    guard !isRequesting else {
      return
    }
    isRequesting = true
    defer {
      isRequesting = false
      schedule()
    }
    do {
      let snapshot = try await download()
      try store.commit(snapshot)
      lastSuccess = now()
      lastFailure = nil
      consecutiveFailures = 0
      if let accepted = try store.lastKnownGood().flatMap(Self.rates), accepted != rates {
        rates = accepted
        ratesDidChange(accepted)
      }
    } catch {
      lastFailure = now()
      consecutiveFailures += 1
    }
  }

  private func schedule() {
    activity?.invalidate()
    activity = nil
    guard isAutomatic else {
      return
    }
    let delay = policy.nextAutomaticRefresh(
      lastSuccess: lastSuccess, lastFailure: lastFailure,
      consecutiveFailures: consecutiveFailures, now: now()
    ).timeIntervalSince(now())
    guard delay > 0 else {
      Task { await refresh() }
      return
    }
    let activity = NSBackgroundActivityScheduler(
      identifier: "com.shantanugoel.Ganit.currencyRates")
    activity.repeats = false
    activity.qualityOfService = .utility
    activity.interval = delay
    activity.tolerance = min(max(delay * 0.1, 1), 15 * 60)
    activity.schedule { [weak self] completion in
      Task { @MainActor in
        await self?.refresh()
        completion(.finished)
      }
    }
    self.activity = activity
  }

  private static func rates(_ snapshot: RateSnapshot) -> CurrencyRates? {
    try? CurrencyRates(
      unitsPerEuro: snapshot.metadata.rates,
      observationDate: snapshot.metadata.observationDate,
      retrievedAt: snapshot.metadata.retrievedAt
    )
  }
}
