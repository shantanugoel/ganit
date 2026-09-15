import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct RateProvenanceTests {
  private let utc = TimeZone(identifier: "UTC")!

  @Test
  func classifiesRateAgeByCalendarDay() throws {
    // 2026-09-11 is a Friday.
    let cases: [(String, RateFreshness)] = [
      ("2026-09-11T20:00:00Z", .current),
      ("2026-09-12T09:00:00Z", .weekendCarryForward(days: 1)),
      ("2026-09-13T23:59:00Z", .weekendCarryForward(days: 2)),
      ("2026-09-14T10:00:00Z", .aged(days: 3)),
      ("2026-09-15T10:00:00Z", .aged(days: 4)),
      ("2026-09-16T00:00:00Z", .stale(days: 5)),
    ]
    for (now, freshness) in cases {
      #expect(
        RateFreshness(observationDate: "2026-09-11", now: try date(now), timeZone: utc)
          == freshness, "\(now)")
    }
    // Sunday evening in UTC is already Monday in Tokyo.
    #expect(
      RateFreshness(
        observationDate: "2026-09-11", now: try date("2026-09-13T20:00:00Z"),
        timeZone: TimeZone(identifier: "Asia/Tokyo")!) == .aged(days: 3))
    #expect(RateFreshness(observationDate: "2026-9-x", now: Date(), timeZone: utc) == nil)
  }

  @Test
  func describesReferenceCrossAndManualRates() throws {
    let rates = try CurrencyRates(
      unitsPerEuro: ["USD": "1.1551"], observationDate: "2026-09-11",
      retrievedAt: try date("2026-09-11T15:30:00Z"))
    let formatter = RateProvenanceFormatter(
      context: try context(rates, now: "2026-09-17T08:00:00Z"))

    #expect(
      formatter.details(for: [.reference]) == [
        detail("Exchange rate", "ECB reference rate"),
        detail("Source", "ECB statistics"),
        detail("Rates published", "Sep 11, 2026"),
        detail("Retrieved", "Sep 11, 2026 at 3:30\u{202F}PM"),
        detail("Rate status", "Stale, 6 days old"),
        detail("Note", "Indicative, not for transactions"),
      ])
    #expect(
      formatter.details(for: [.crossReference, .manual]).first
        == detail("Exchange rate", "Calculated by Ganit from ECB reference rates; Manual rate"))
    #expect(formatter.details(for: [.manual]) == [detail("Exchange rate", "Manual rate")])
    #expect(formatter.details(for: []).isEmpty)
  }

  private func detail(_ label: String, _ value: String) -> ProvenanceDetail {
    ProvenanceDetail(label: label, value: value)
  }

  private func date(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
  }

  private func context(_ rates: CurrencyRates, now: String) throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: try date(now),
      calendar: Calendar(identifier: .gregorian),
      timeZone: utc,
      currencyRates: rates
    )
  }
}
