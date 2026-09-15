import Foundation
import Testing

@testable import GanitData

@Suite
struct RateRefreshPolicyTests {
  private let policy = RateRefreshPolicy(timeZone: TimeZone(identifier: "America/New_York")!)

  @Test
  func requestsAtOnceWithoutRates() throws {
    let now = try date("2026-09-15T03:00:00Z")
    #expect(
      policy.nextAutomaticRefresh(
        lastSuccess: nil, lastFailure: nil, consecutiveFailures: 0, now: now) == now)
  }

  @Test
  func requestsOncePerLocalDayAfterBrusselsPublication() throws {
    // 16:15 in Brussels on Sep 15 is 14:15 UTC; a success late on Sep 14 in
    // New York waits for Sep 15 there, then for the publication time.
    #expect(
      try next(afterSuccess: "2026-09-15T02:00:00Z") == date("2026-09-15T14:15:00Z"))
    // After a success on Sep 15 afternoon in New York, the next local day
    // starts at 04:00 UTC on Sep 16, before that day's publication.
    #expect(
      try next(afterSuccess: "2026-09-15T15:00:00Z") == date("2026-09-16T14:15:00Z"))
    // A local day that starts before that day's Brussels publication waits
    // for it: Sep 16 in Kiritimati starts at 10:00 UTC on Sep 15.
    let kiritimati = RateRefreshPolicy(timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
    #expect(
      kiritimati.nextAutomaticRefresh(
        lastSuccess: try date("2026-09-15T09:00:00Z"), lastFailure: nil, consecutiveFailures: 0,
        now: Date()) == (try date("2026-09-15T14:15:00Z")))
  }

  @Test
  func backsOffExponentiallyUpToADay() throws {
    let failure = try date("2026-09-15T15:00:00Z")
    let delays = [1, 2, 3, 9, 30].map {
      policy.nextAutomaticRefresh(
        lastSuccess: nil, lastFailure: failure, consecutiveFailures: $0, now: failure
      ).timeIntervalSince(failure)
    }
    #expect(delays == [300, 600, 1_200, 76_800, 86_400])
  }

  @Test
  func limitsManualRefresh() throws {
    let attempt = try date("2026-09-15T15:00:00Z")
    #expect(policy.allowsManualRefresh(lastAttempt: nil, isRequesting: false, now: attempt))
    #expect(!policy.allowsManualRefresh(lastAttempt: nil, isRequesting: true, now: attempt))
    #expect(
      !policy.allowsManualRefresh(
        lastAttempt: attempt, isRequesting: false, now: attempt.addingTimeInterval(59)))
    #expect(
      policy.allowsManualRefresh(
        lastAttempt: attempt, isRequesting: false, now: attempt.addingTimeInterval(60)))
  }

  private func next(afterSuccess text: String) throws -> Date {
    policy.nextAutomaticRefresh(
      lastSuccess: try date(text), lastFailure: nil, consecutiveFailures: 0, now: Date())
  }

  private func date(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
  }
}
