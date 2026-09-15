import Foundation
import Testing

@testable import GanitEngine

@Suite
struct TemporalValueTests {
  @Test
  func validatesDatesAndTimes() throws {
    #expect(throws: EngineError(code: .invalidDate)) {
      try DateValue(year: 2023, month: 2, day: 29)
    }
    #expect(throws: EngineError(code: .invalidDate)) {
      try DateValue(year: 1900, month: 2, day: 29)
    }
    #expect(try DateValue(year: 2000, month: 2, day: 29).day == 29)
    #expect(throws: EngineError(code: .invalidTime)) {
      try LocalTimeValue(hour: 24, minute: 0)
    }
  }

  @Test
  func parsesCalendarPeriodWords() throws {
    #expect(try evaluate("3 months") == .period(CalendarPeriodValue(months: 3)))
    #expect(try evaluate("1 year + 2 quarters") == .period(CalendarPeriodValue(months: 18)))
    #expect(try evaluate("2 weeks - 1 day") == .period(CalendarPeriodValue(days: 13)))
    #expect(try evaluate("-(2 * 1 month)") == .period(CalendarPeriodValue(months: -2)))
    #expect(try error("1.5 months").code == .fractionalCalendarPeriod)
    #expect(try error("1 month * 0.5").code == .fractionalCalendarPeriod)
    #expect(try error("1 month + 30 min").code == .typeMismatch)
  }

  @Test
  func addsCalendarPeriodsToDatesWithMonthEndClamping() throws {
    let january31 = try DateValue(year: 2024, month: 1, day: 31)
    #expect(
      try evaluate("d + 1 month", ["d": .date(january31)])
        == .date(try DateValue(year: 2024, month: 2, day: 29))
    )
    #expect(
      try evaluate("d + 1 year", ["d": .date(try DateValue(year: 2024, month: 2, day: 29))])
        == .date(try DateValue(year: 2025, month: 2, day: 28))
    )
    #expect(
      try evaluate("d - 1 quarter", ["d": .date(try DateValue(year: 2024, month: 5, day: 31))])
        == .date(try DateValue(year: 2024, month: 2, day: 29))
    )
    #expect(
      try evaluate("1 week + d", ["d": .date(try DateValue(year: 2023, month: 12, day: 28))])
        == .date(try DateValue(year: 2024, month: 1, day: 4))
    )
    #expect(
      try error("d + 1 year", ["d": .date(try DateValue(year: 9_999, month: 12, day: 1))]).code
        == .dateOutOfRange
    )
  }

  @Test
  func subtractsDatesIntoDayPeriods() throws {
    let values: [String: EngineValue?] = [
      "start": .date(try DateValue(year: 2024, month: 2, day: 1)),
      "end": .date(try DateValue(year: 2024, month: 3, day: 1)),
    ]
    #expect(try evaluate("end - start", values) == .period(CalendarPeriodValue(days: 29)))
    #expect(try evaluate("start - end", values) == .period(CalendarPeriodValue(days: -29)))
    #expect(try error("end + start", values).code == .typeMismatch)
  }

  @Test
  func wrapsTimesOfDayAndMeasuresDurations() throws {
    let values: [String: EngineValue?] = [
      "late": .time(try LocalTimeValue(hour: 23, minute: 30)),
      "early": .time(try LocalTimeValue(hour: 0, minute: 15)),
    ]
    #expect(
      try evaluate("late + 45 min", values) == .time(try LocalTimeValue(hour: 0, minute: 15))
    )
    #expect(
      try evaluate("early - 30 min", values) == .time(try LocalTimeValue(hour: 23, minute: 45))
    )
    #expect(try evaluate("late - early", values) == .quantity(try duration(83_700)))
    #expect(try error("late + 0.5 s", values).code == .invalidTime)
    #expect(try error("late + 1 day", values).code == .typeMismatch)
  }

  @Test
  func keepsWallClockTimeWhenAddingPeriodsToInstantsAcrossDaylightSaving() throws {
    // 2024-03-09 12:00 in New York, the day before clocks move forward.
    let noon = InstantValue(
      date: Date(timeIntervalSince1970: 1_710_003_600),
      timeZoneIdentifier: "America/New_York"
    )
    let nextNoon = try evaluate("t + 1 day", ["t": .instant(noon)])
    #expect(
      nextNoon
        == .instant(
          InstantValue(
            date: Date(timeIntervalSince1970: 1_710_086_400),
            timeZoneIdentifier: "America/New_York"
          )
        )
    )
    #expect(
      try evaluate("t - s", ["t": nextNoon, "s": .instant(noon)]) == .quantity(try duration(82_800))
    )
    #expect(
      try evaluate("s + 24 h", ["s": .instant(noon)])
        == .instant(
          InstantValue(
            date: Date(timeIntervalSince1970: 1_710_090_000),
            timeZoneIdentifier: "America/New_York"
          )
        )
    )
  }

  @Test
  func expressesDurationsInTheLargestWholeUnit() throws {
    #expect(try evaluate("2 h") == .quantity(try duration(7_200)))
    #expect(try evaluate("90 s") == .quantity(try duration(90)))
    #expect(try evaluate("90 min") == .quantity(try duration(5_400)))
    #expect(try evaluate("0 s") == .quantity(try duration(0)))
    #expect(try evaluate("(1/4) s") == .quantity(try duration(0.25)))
  }

  @Test
  func evaluatesISOInputInTheEvaluationZoneOrItsOffset() throws {
    let zone = "America/New_York"
    #expect(try evaluate("2024-02-29") == .date(try DateValue(year: 2024, month: 2, day: 29)))
    #expect(try evaluate("9:05") == .time(try LocalTimeValue(hour: 9, minute: 5)))
    #expect(try evaluate("12:30 am") == .time(try LocalTimeValue(hour: 0, minute: 30)))
    #expect(try evaluate("12:30 PM") == .time(try LocalTimeValue(hour: 12, minute: 30)))
    #expect(
      try evaluate("2024-03-09T12:00", zone: zone)
        == .instant(
          InstantValue(date: Date(timeIntervalSince1970: 1_710_003_600), timeZoneIdentifier: zone))
    )
    #expect(
      try evaluate("2024-03-09T17:00Z")
        == .instant(
          InstantValue(date: Date(timeIntervalSince1970: 1_710_003_600), timeZoneIdentifier: "GMT"))
    )
    #expect(
      try evaluate("2024-03-09T12:00-05:00")
        == .instant(
          InstantValue(
            date: Date(timeIntervalSince1970: 1_710_003_600), timeZoneIdentifier: "GMT-0500"))
    )
    #expect(try error("2023-02-29").code == .invalidDate)
    #expect(try error("24:00").code == .invalidTime)
    #expect(try error("2024-01-01T12:00+19:00").code == .invalidTime)
    #expect(Parser(source: "13:00 pm").parse().diagnostics.map(\.code) == [.unexpectedToken])
  }

  @Test
  func evaluatesEnglishPhrasesAgainstTheFrozenNow() throws {
    // The frozen now is Tuesday 2023-11-14 22:13:20 UTC, 17:13 in New York and
    // Wednesday 07:13 in Tokyo.
    let zone = "America/New_York"
    #expect(try evaluate("today") == .date(try DateValue(year: 2023, month: 11, day: 14)))
    #expect(
      try evaluate("Today", zone: "Asia/Tokyo")
        == .date(try DateValue(year: 2023, month: 11, day: 15)))
    #expect(try evaluate("tomorrow") == .date(try DateValue(year: 2023, month: 11, day: 15)))
    #expect(try evaluate("yesterday") == .date(try DateValue(year: 2023, month: 11, day: 13)))
    #expect(
      try evaluate("now", zone: zone)
        == .instant(
          InstantValue(date: Date(timeIntervalSince1970: 1_700_000_000), timeZoneIdentifier: zone))
    )
    #expect(try evaluate("next tuesday") == .date(try DateValue(year: 2023, month: 11, day: 21)))
    #expect(try evaluate("next Wed") == .date(try DateValue(year: 2023, month: 11, day: 15)))
    #expect(try evaluate("last tuesday") == .date(try DateValue(year: 2023, month: 11, day: 7)))
    #expect(try evaluate("last sunday") == .date(try DateValue(year: 2023, month: 11, day: 12)))
    #expect(try evaluate("March 9, 2024") == .date(try DateValue(year: 2024, month: 3, day: 9)))
    #expect(try evaluate("mar 9 2024") == .date(try DateValue(year: 2024, month: 3, day: 9)))
    #expect(try evaluate("9 March 2024") == .date(try DateValue(year: 2024, month: 3, day: 9)))
    #expect(try evaluate("Dec 25") == .date(try DateValue(year: 2023, month: 12, day: 25)))
    #expect(try evaluate("Dec 25 - today") == .period(CalendarPeriodValue(days: 41)))
    #expect(try evaluate("3 days ago") == .date(try DateValue(year: 2023, month: 11, day: 11)))
    #expect(
      try evaluate("1 month + 2 weeks from now")
        == .date(try DateValue(year: 2023, month: 12, day: 28)))
    #expect(
      try evaluate("90 min ago")
        == .instant(
          InstantValue(date: Date(timeIntervalSince1970: 1_699_994_600), timeZoneIdentifier: "GMT"))
    )
    #expect(try error("5 ago").code == .typeMismatch)
    #expect(try error("Feb 30").code == .invalidDate)
    #expect(
      try evaluate("may * 2", ["may": .number(.integer(IntegerValue(3)))])
        == .number(.integer(IntegerValue(6))))
  }

  @Test
  func resolvesIANAZonesAndConservativeAliases() throws {
    let noon = Date(timeIntervalSince1970: 1_710_003_600)
    let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(
      try evaluate("now in Asia/Tokyo")
        == .instant(InstantValue(date: frozenNow, timeZoneIdentifier: "Asia/Tokyo"))
    )
    #expect(
      try evaluate("now to america/argentina/buenos_aires")
        == .instant(
          InstantValue(date: frozenNow, timeZoneIdentifier: "America/Argentina/Buenos_Aires"))
    )
    #expect(
      try evaluate("2024-03-09T17:00Z in New York")
        == .instant(InstantValue(date: noon, timeZoneIdentifier: "America/New_York"))
    )
    #expect(
      try evaluate("2024-03-09T12:00 America/New_York")
        == .instant(InstantValue(date: noon, timeZoneIdentifier: "America/New_York"))
    )
    #expect(
      try evaluate("2024-03-10T02:00 tokyo - 2024-03-09T12:00 New York")
        == .quantity(try duration(0))
    )
    #expect(try error("today in Tokyo").code == .typeMismatch)
    for source in ["now in EST", "now in Mars", "now in Asia/Atlantis", "now in"] {
      #expect(Parser(source: source).parse().diagnostics.map(\.code) == [.unknownTimeZone])
    }
    #expect(Set(TimeZoneNames.aliases.values).allSatisfy { TimeZone(identifier: $0) != nil })
  }

  private func evaluate(
    _ source: String, _ values: [String: EngineValue?] = [:], zone: String = "UTC"
  ) throws -> EngineValue {
    let parsing = Parser(
      source: source,
      variables: values.mapValues { $0?.kind ?? .number }
    ).parse()
    #expect(parsing.diagnostics.isEmpty, "\(source)")
    return try Evaluator(
      context: fixedContext(zone: zone),
      limits: .default,
      variables: values,
      lines: LineOutcomes()
    ).evaluate(try #require(parsing.expression))
  }

  private func error(_ source: String, _ values: [String: EngineValue?] = [:]) throws
    -> EngineError
  {
    do {
      let value = try evaluate(source, values)
      Issue.record("Expected an error for \(source), got \(value)")
      throw EngineError(code: .invalidDomain)
    } catch let error as EngineError {
      return error
    }
  }

  private func duration(_ seconds: Double) throws -> QuantityValue {
    try temporalArithmetic().duration(seconds: seconds)
  }

  private func temporalArithmetic() throws -> TemporalArithmetic {
    let context = try fixedContext()
    return TemporalArithmetic(
      context: context,
      operations: NumericOperations(context: context, limits: .default),
      unitAlgebra: UnitAlgebra(context: context, limits: .default)
    )
  }

  private func unitAlgebra() throws -> UnitAlgebra {
    UnitAlgebra(context: try fixedContext(), limits: .default)
  }

  private func fixedContext(zone: String = "UTC") throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: try PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: try #require(TimeZone(identifier: zone))
    )
  }
}
