import Foundation

/// When Ganit may request currency rates.
///
/// Without rates, a request is due at once. Otherwise automatic requests
/// happen at most once per local calendar day, no earlier than 16:15 in
/// Brussels, after the ECB normally publishes. A failed request is retried
/// after a delay that doubles from five minutes up to 24 hours. A manual
/// request needs no request in flight and 60 seconds since the last attempt.
public struct RateRefreshPolicy: Sendable {
  public static let publicationZone = TimeZone(identifier: "Europe/Brussels")!
  public static let manualMinimumInterval: TimeInterval = 60
  public static let firstRetryDelay: TimeInterval = 5 * 60
  public static let maximumRetryDelay: TimeInterval = 24 * 3_600

  /// The user's time zone, which defines a local calendar day.
  public let timeZone: TimeZone

  public init(timeZone: TimeZone) {
    self.timeZone = timeZone
  }

  /// The earliest moment the next automatic request may start; a moment in
  /// the past means now.
  public func nextAutomaticRefresh(
    lastSuccess: Date?,
    lastFailure: Date?,
    consecutiveFailures: Int,
    now: Date
  ) -> Date {
    if let lastFailure, consecutiveFailures > 0 {
      let exponent = Double(min(consecutiveFailures - 1, 16))
      let delay = min(Self.firstRetryDelay * pow(2, exponent), Self.maximumRetryDelay)
      return lastFailure.addingTimeInterval(delay)
    }
    guard let lastSuccess else {
      return now
    }
    var local = Calendar(identifier: .gregorian)
    local.timeZone = timeZone
    let nextDay = local.dateInterval(of: .day, for: lastSuccess)!.end
    return afterPublication(nextDay)
  }

  public func allowsManualRefresh(lastAttempt: Date?, isRequesting: Bool, now: Date) -> Bool {
    !isRequesting
      && lastAttempt.map { now.timeIntervalSince($0) >= Self.manualMinimumInterval } != false
  }

  /// The first moment at or after `date` that is past 16:15 in Brussels on
  /// its Brussels day.
  private func afterPublication(_ date: Date) -> Date {
    var brussels = Calendar(identifier: .gregorian)
    brussels.timeZone = Self.publicationZone
    let publication = brussels.date(bySettingHour: 16, minute: 15, second: 0, of: date)!
    return max(date, publication)
  }
}
