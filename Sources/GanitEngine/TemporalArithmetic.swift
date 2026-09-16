import Foundation

/// Arithmetic between dates, times of day, instants, calendar periods, and
/// fixed durations, which are time quantities.
///
/// - date ± period → date, applying months before days in the proleptic
///   Gregorian calendar and clamping to the last day of a shorter month;
/// - date − date → period of days;
/// - time ± duration → time, wrapping around midnight;
/// - time − time and instant − instant → duration;
/// - instant ± duration → instant;
/// - instant ± period → instant, keeping the local wall-clock time in the
///   instant's zone and calendar;
/// - period ± period → period, and period × whole number → period.
///
/// Periods and durations never mix: a month is not 30 days, and a calendar day
/// is not always 24 hours.
struct TemporalArithmetic {
  let context: EvaluationContext
  let operations: NumericOperations
  let unitAlgebra: UnitAlgebra

  /// The result of a temporal operation, or `nil` when neither operand is
  /// temporal and ordinary arithmetic applies.
  func apply(_ binaryOperator: BinaryOperator, left: EngineValue, right: EngineValue) throws
    -> EngineValue?
  {
    switch (binaryOperator, left, right) {
    case (.add, .date(let date), .period(let period)), (.add, .period(let period), .date(let date)):
      return .date(try add(period, to: date))
    case (.subtract, .date(let date), .period(let period)):
      return .date(try add(negated(period), to: date))
    case (.subtract, .date(let later), .date(let earlier)):
      return .period(CalendarPeriodValue(days: try days(from: earlier, to: later)))

    case (.add, .time(let time), .quantity(let duration)),
      (.add, .quantity(let duration), .time(let time)):
      return .time(
        LocalTimeValue(wrapping: time.secondsSinceMidnight + (try wholeSeconds(duration))))
    case (.subtract, .time(let time), .quantity(let duration)):
      return .time(
        LocalTimeValue(wrapping: time.secondsSinceMidnight - (try wholeSeconds(duration))))
    case (.subtract, .time(let later), .time(let earlier)):
      return .quantity(
        try duration(seconds: Double(later.secondsSinceMidnight - earlier.secondsSinceMidnight)))

    case (.add, .instant(let instant), .quantity(let duration)),
      (.add, .quantity(let duration), .instant(let instant)):
      return .instant(try shift(instant, seconds: try seconds(duration)))
    case (.subtract, .instant(let instant), .quantity(let duration)):
      return .instant(try shift(instant, seconds: -(try seconds(duration))))
    case (.add, .instant(let instant), .period(let period)),
      (.add, .period(let period), .instant(let instant)):
      return .instant(try add(period, to: instant))
    case (.subtract, .instant(let instant), .period(let period)):
      return .instant(try add(negated(period), to: instant))
    case (.subtract, .instant(let later), .instant(let earlier)):
      return .quantity(try duration(seconds: later.date.timeIntervalSince(earlier.date)))

    case (.add, .period(let lhs), .period(let rhs)):
      return .period(try combine(lhs, rhs, sign: 1))
    case (.subtract, .period(let lhs), .period(let rhs)):
      return .period(try combine(lhs, rhs, sign: -1))
    case (.multiply, .period(let period), .number(let count)),
      (.multiply, .number(let count), .period(let period)):
      return .period(try multiply(period, by: count))

    default:
      return nil
    }
  }

  /// The value of a literal written at `range`, which fix-its replace.
  func value(of literal: TemporalLiteral, at range: SourceRange) throws -> EngineValue {
    switch literal {
    case .date(let year, let month, let day):
      return .date(try DateValue(year: year ?? today().year, month: month, day: day))
    case .time(let hour, let minute, let second):
      return .time(try LocalTimeValue(hour: hour, minute: minute, second: second))
    case .dateTime(let literal):
      return .instant(try instant(literal, at: range))
    case .relativeDay(let days):
      return .date(try add(CalendarPeriodValue(days: days), to: today()))
    case .now:
      return .instant(now)
    case .weekday(let weekday, let isNext):
      let today = try today()
      let current = dateCalendar.component(.weekday, from: startOfDay(today))
      let days = isNext ? (weekday - current + 6) % 7 + 1 : -((current - weekday + 6) % 7 + 1)
      return .date(try add(CalendarPeriodValue(days: days), to: today))
    }
  }

  /// Resolves a wall-clock date and time. In a zone, a time skipped by a
  /// daylight-saving gap is an error, and a time repeated by an overlap is an
  /// ambiguity unless its offset picks one; fix-its spell out the choices.
  private func instant(_ literal: DateTimeLiteral, at range: SourceRange) throws -> InstantValue {
    let date = try DateValue(year: literal.year, month: literal.month, day: literal.day)
    let time = try LocalTimeValue(
      hour: literal.hour, minute: literal.minute, second: literal.second)
    let wall = startOfDay(date).addingTimeInterval(TimeInterval(time.secondsSinceMidnight))
    guard
      let identifier = literal.zone ?? (literal.offset == nil ? context.timeZoneIdentifier : nil)
    else {
      guard let zone = TimeZone(secondsFromGMT: literal.offset!) else {
        throw EngineError(code: .invalidTime)
      }
      return InstantValue(
        date: wall.addingTimeInterval(-TimeInterval(literal.offset!)),
        timeZoneIdentifier: zone.identifier)
    }
    guard let zone = TimeZone(identifier: identifier) else {
      throw EngineError(code: .invalidTime)
    }
    let candidates = instants(showing: wall, in: zone)
    if let offset = literal.offset {
      let chosen = wall.addingTimeInterval(-TimeInterval(offset))
      guard candidates.contains(chosen) else {
        throw EngineError(code: .offsetMismatch, ranges: [range])
      }
      return InstantValue(date: chosen, timeZoneIdentifier: identifier)
    }
    switch candidates.count {
    case 1:
      return InstantValue(date: candidates[0], timeZoneIdentifier: identifier)
    case 0:
      // The offset in effect before the gap moves the time past it.
      let before = zone.secondsFromGMT(for: wall.addingTimeInterval(-86_400))
      let shifted = wall.addingTimeInterval(-TimeInterval(before))
      throw EngineError(
        code: .nonexistentLocalTime,
        ranges: [range],
        fixIts: [fixIt(shifted, zone: zone, identifier: identifier, range: range, key: "afterGap")]
      )
    default:
      throw EngineError(
        code: .ambiguousLocalTime,
        severity: .ambiguity,
        ranges: [range],
        fixIts: [
          fixIt(
            candidates[0], zone: zone, identifier: identifier, range: range, key: "earlierOffset"),
          fixIt(
            candidates[1], zone: zone, identifier: identifier, range: range, key: "laterOffset"),
        ]
      )
    }
  }

  /// The instants at which a zone's clocks show a wall-clock time, given as a
  /// UTC date with the same fields: none in a gap, two in an overlap.
  private func instants(showing wall: Date, in zone: TimeZone) -> [Date] {
    let offsets = Set(
      [-86_400.0, 0, 86_400].map { zone.secondsFromGMT(for: wall.addingTimeInterval($0)) })
    return offsets.map { wall.addingTimeInterval(-TimeInterval($0)) }
      .filter { zone.secondsFromGMT(for: $0) == Int(wall.timeIntervalSince($0)) }
      .sorted()
  }

  private func fixIt(
    _ instant: Date, zone: TimeZone, identifier: String, range: SourceRange, key: String
  ) -> DiagnosticFixIt {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = zone
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    // ISO 8601 writes UTC as `Z`; an explicit offset keeps the zone name valid.
    let text = formatter.string(from: instant).replacingOccurrences(of: "Z", with: "+00:00")
    return DiagnosticFixIt(
      range: range, replacement: "\(text) \(identifier)", messageKey: "fixIt.\(key)")
  }

  /// The same moment shown in another zone.
  func converted(_ value: EngineValue, toZone identifier: String) throws -> EngineValue {
    guard case .instant(let instant) = value else {
      throw EngineError(
        code: .typeMismatch, context: .typeMismatch(expected: .instant, actual: value.kind))
    }
    return .instant(InstantValue(date: instant.date, timeZoneIdentifier: identifier))
  }

  /// A time of day today in the evaluation time zone.
  func today(at time: LocalTimeValue, range: SourceRange) throws -> InstantValue {
    let date = try today()
    let seconds = time.secondsSinceMidnight
    return try instant(
      DateTimeLiteral(
        year: date.year, month: date.month, day: date.day, hour: seconds / 3_600,
        minute: seconds / 60 % 60, second: seconds % 60),
      at: range)
  }

  /// The current moment in the evaluation time zone.
  var now: InstantValue {
    InstantValue(date: context.now, timeZoneIdentifier: context.timeZoneIdentifier)
  }

  /// The current date in the evaluation time zone.
  func today() throws -> DateValue {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = context.timeZone
    return try dateValue(calendar.dateComponents([.era, .year, .month, .day], from: context.now))
  }

  func negated(_ period: CalendarPeriodValue) throws -> CalendarPeriodValue {
    try multiply(period, by: -1)
  }

  // MARK: Dates

  /// A Gregorian calendar in UTC, for dates that have no zone.
  private var dateCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func startOfDay(_ date: DateValue) -> Date {
    dateCalendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
  }

  private func add(_ period: CalendarPeriodValue, to date: DateValue) throws -> DateValue {
    let calendar = dateCalendar
    guard
      let end = calendar.date(
        byAdding: DateComponents(month: period.months, day: period.days), to: startOfDay(date))
    else {
      throw EngineError(code: .dateOutOfRange)
    }
    return try dateValue(calendar.dateComponents([.era, .year, .month, .day], from: end))
  }

  private func days(from earlier: DateValue, to later: DateValue) throws -> Int {
    guard
      let days = dateCalendar.dateComponents(
        [.day], from: startOfDay(earlier), to: startOfDay(later)
      ).day
    else {
      throw EngineError(code: .dateOutOfRange)
    }
    return days
  }

  /// A date from Gregorian components; years before 1 are in era 0.
  private func dateValue(_ components: DateComponents) throws -> DateValue {
    guard components.era == 1 else {
      throw EngineError(code: .dateOutOfRange)
    }
    do {
      return try DateValue(year: components.year!, month: components.month!, day: components.day!)
    } catch {
      throw EngineError(code: .dateOutOfRange)
    }
  }

  // MARK: Instants

  private func add(_ period: CalendarPeriodValue, to instant: InstantValue) throws -> InstantValue {
    guard let zone = TimeZone(identifier: instant.timeZoneIdentifier) else {
      throw EngineError(code: .dateOutOfRange)
    }
    var calendar = context.calendar
    calendar.timeZone = zone
    guard
      let date = calendar.date(
        byAdding: DateComponents(month: period.months, day: period.days),
        to: instant.date
      )
    else {
      throw EngineError(code: .dateOutOfRange)
    }
    return InstantValue(date: date, timeZoneIdentifier: instant.timeZoneIdentifier)
  }

  private func shift(_ instant: InstantValue, seconds: Double) throws -> InstantValue {
    let date = instant.date.addingTimeInterval(seconds)
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw EngineError(code: .dateOutOfRange)
    }
    return InstantValue(date: date, timeZoneIdentifier: instant.timeZoneIdentifier)
  }

  // MARK: Durations

  private func seconds(_ duration: QuantityValue) throws -> Double {
    guard duration.unit.dimension == Dimension(.time) else {
      throw EngineError(
        code: .incompatibleDimensions,
        context: .dimensionMismatch(expected: Dimension(.time), actual: duration.unit.dimension)
      )
    }
    return try operations.double(unitAlgebra.canonicalMagnitude(of: duration))
  }

  private func wholeSeconds(_ duration: QuantityValue) throws -> Int {
    let seconds = try seconds(duration)
    guard let whole = Int(exactly: seconds) else {
      throw EngineError(code: .invalidTime)
    }
    return whole
  }

  /// A duration in the largest of hours, minutes, or seconds that keeps the
  /// value whole, rounded to milliseconds.
  func duration(seconds: Double) throws -> QuantityValue {
    let milliseconds = (seconds * 1_000).rounded()
    guard let millisecondCount = Int(exactly: milliseconds) else {
      throw EngineError(code: .dateOutOfRange)
    }
    let (symbol, divisor) =
      [("h", 3_600_000), ("min", 60_000)].first {
        millisecondCount != 0 && millisecondCount % $0.1 == 0
      } ?? ("s", 1_000)
    let magnitude = try operations.applying(
      .divide,
      left: .integer(IntegerValue(millisecondCount)),
      right: .integer(IntegerValue(divisor))
    )
    let definition = builtInMinimalUnitCatalog.unit(matching: symbol)!.definition
    return QuantityValue(magnitude: magnitude, unit: try unitAlgebra.unit(definition))
  }

  // MARK: Periods

  private func combine(_ lhs: CalendarPeriodValue, _ rhs: CalendarPeriodValue, sign: Int) throws
    -> CalendarPeriodValue
  {
    let (months, monthOverflow) = lhs.months.addingReportingOverflow(sign * rhs.months)
    let (days, dayOverflow) = lhs.days.addingReportingOverflow(sign * rhs.days)
    guard !monthOverflow, !dayOverflow else {
      throw EngineError(code: .dateOutOfRange)
    }
    return CalendarPeriodValue(months: months, days: days)
  }

  private func multiply(_ period: CalendarPeriodValue, by count: NumericValue) throws
    -> CalendarPeriodValue
  {
    guard let count = operations.exactInteger(count) else {
      throw EngineError(code: .fractionalCalendarPeriod)
    }
    return try multiply(period, by: count)
  }

  private func multiply(_ period: CalendarPeriodValue, by count: Int) throws -> CalendarPeriodValue
  {
    let (months, monthOverflow) = period.months.multipliedReportingOverflow(by: count)
    let (days, dayOverflow) = period.days.multipliedReportingOverflow(by: count)
    guard !monthOverflow, !dayOverflow else {
      throw EngineError(code: .dateOutOfRange)
    }
    return CalendarPeriodValue(months: months, days: days)
  }
}
