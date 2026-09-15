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

  private func add(_ period: CalendarPeriodValue, to date: DateValue) throws -> DateValue {
    let calendar = dateCalendar
    guard
      let start = calendar.date(
        from: DateComponents(year: date.year, month: date.month, day: date.day)),
      let end = calendar.date(
        byAdding: DateComponents(month: period.months, day: period.days), to: start)
    else {
      throw EngineError(code: .dateOutOfRange)
    }
    let components = calendar.dateComponents([.year, .month, .day], from: end)
    do {
      return try DateValue(year: components.year!, month: components.month!, day: components.day!)
    } catch {
      throw EngineError(code: .dateOutOfRange)
    }
  }

  private func days(from earlier: DateValue, to later: DateValue) throws -> Int {
    let calendar = dateCalendar
    guard
      let start = calendar.date(
        from: DateComponents(year: earlier.year, month: earlier.month, day: earlier.day)),
      let end = calendar.date(
        from: DateComponents(year: later.year, month: later.month, day: later.day)),
      let days = calendar.dateComponents([.day], from: start, to: end).day
    else {
      throw EngineError(code: .dateOutOfRange)
    }
    return days
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
