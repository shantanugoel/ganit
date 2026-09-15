import Foundation

/// A calendar date without a time of day or zone.
public struct DateValue: Hashable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  /// Validates the date in the proleptic Gregorian calendar.
  public init(year: Int, month: Int, day: Int) throws {
    guard (1...9_999).contains(year), (1...12).contains(month), day >= 1,
      day <= DateValue.daysInMonth(year: year, month: month)
    else {
      throw EngineError(code: .invalidDate)
    }
    self.year = year
    self.month = month
    self.day = day
  }

  static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
      return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }
}

/// A time of day without a date or zone, to the second.
public struct LocalTimeValue: Hashable, Sendable {
  public static let secondsPerDay = 86_400

  public let secondsSinceMidnight: Int

  public init(hour: Int, minute: Int, second: Int = 0) throws {
    guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
      throw EngineError(code: .invalidTime)
    }
    secondsSinceMidnight = hour * 3_600 + minute * 60 + second
  }

  init(wrapping seconds: Int) {
    let remainder = seconds % Self.secondsPerDay
    secondsSinceMidnight = remainder < 0 ? remainder + Self.secondsPerDay : remainder
  }

  public var hour: Int { secondsSinceMidnight / 3_600 }
  public var minute: Int { secondsSinceMidnight / 60 % 60 }
  public var second: Int { secondsSinceMidnight % 60 }
}

/// An absolute moment, shown in a named IANA time zone.
public struct InstantValue: Hashable, Sendable {
  public let date: Date
  public let timeZoneIdentifier: String

  public init(date: Date, timeZoneIdentifier: String) {
    self.date = date
    self.timeZoneIdentifier = timeZoneIdentifier
  }
}

/// A calendar span of whole months and days. Its real length depends on where
/// it is applied: a month is 28 to 31 days, and a day can be 23 to 25 hours
/// across a daylight-saving change. It never converts to a fixed duration.
public struct CalendarPeriodValue: Hashable, Sendable {
  public let months: Int
  public let days: Int

  public init(months: Int = 0, days: Int = 0) {
    self.months = months
    self.days = days
  }
}

/// The calendar words that form periods, singular and plural.
public enum CalendarPeriodUnit: String, CaseIterable, Sendable {
  case day
  case week
  case month
  case quarter
  case year

  init?(word: String) {
    self.init(rawValue: word.hasSuffix("s") ? String(word.dropLast()) : word)
  }

  func period(count: Int) -> CalendarPeriodValue? {
    let (months, days): (Int, Int) =
      switch self {
      case .day: (0, 1)
      case .week: (0, 7)
      case .month: (1, 0)
      case .quarter: (3, 0)
      case .year: (12, 0)
      }
    let (monthCount, monthOverflow) = count.multipliedReportingOverflow(by: months)
    let (dayCount, dayOverflow) = count.multipliedReportingOverflow(by: days)
    guard !monthOverflow, !dayOverflow else {
      return nil
    }
    return CalendarPeriodValue(months: monthCount, days: dayCount)
  }
}
