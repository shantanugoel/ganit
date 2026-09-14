import Foundation

public enum AngleMode: String, Hashable, Sendable {
  case radians
  case degrees
}

public enum RoundingRule: String, Hashable, Sendable {
  case toNearestOrEven
  case awayFromZero
  case towardZero
  case up
  case down

  var floatingPointRule: FloatingPointRoundingRule {
    switch self {
    case .toNearestOrEven:
      return .toNearestOrEven
    case .awayFromZero:
      return .awayFromZero
    case .towardZero:
      return .towardZero
    case .up:
      return .up
    case .down:
      return .down
    }
  }
}

public struct PrecisionContext: Hashable, Sendable {
  public let significantDecimalDigits: Int
  public let roundingRule: RoundingRule

  var transcendentalSignificantDigits: Int {
    min(significantDecimalDigits, 15)
  }

  public init(
    significantDecimalDigits: Int,
    roundingRule: RoundingRule = .toNearestOrEven
  ) throws {
    guard
      significantDecimalDigits > 0,
      significantDecimalDigits
        <= ApproximateValue.maximumSignificantDecimalDigits
    else {
      throw EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(significantDecimalDigits)
      )
    }
    self.significantDecimalDigits = significantDecimalDigits
    self.roundingRule = roundingRule
  }
}

public struct EvaluationContext: Hashable, Sendable {
  public let localeIdentifier: String
  public let lexingConfiguration: LexingConfiguration
  public let angleMode: AngleMode
  public let precision: PrecisionContext
  public let now: Date
  public let calendar: Calendar
  public let timeZone: TimeZone

  public var calendarIdentifier: Calendar.Identifier {
    calendar.identifier
  }

  public var timeZoneIdentifier: String {
    timeZone.identifier
  }

  public init(
    localeIdentifier: String,
    lexingConfiguration: LexingConfiguration,
    angleMode: AngleMode,
    precision: PrecisionContext,
    now: Date,
    calendar: Calendar,
    timeZone: TimeZone
  ) throws {
    guard Self.isStructurallyValidBCP47(localeIdentifier) else {
      throw EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.locale)
      )
    }
    guard now.timeIntervalSinceReferenceDate.isFinite else {
      throw EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.now)
      )
    }
    guard timeZone != .autoupdatingCurrent else {
      throw EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.timeZone)
      )
    }
    self.localeIdentifier = localeIdentifier
    self.lexingConfiguration = lexingConfiguration
    self.angleMode = angleMode
    self.precision = precision
    self.now = now
    var normalizedCalendar = calendar
    normalizedCalendar.locale = Locale(identifier: localeIdentifier)
    normalizedCalendar.timeZone = timeZone
    self.calendar = normalizedCalendar
    self.timeZone = timeZone
  }

  private static func isStructurallyValidBCP47(_ identifier: String) -> Bool {
    let grandfathered: Set<String> = [
      "art-lojban", "cel-gaulish", "en-gb-oed", "i-ami", "i-bnn",
      "i-default", "i-enochian", "i-hak", "i-klingon", "i-lux",
      "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu",
      "no-bok", "no-nyn", "sgn-be-fr", "sgn-be-nl", "sgn-ch-de",
      "zh-guoyu", "zh-hakka", "zh-min", "zh-min-nan", "zh-xiang",
    ]
    if grandfathered.contains(identifier.lowercased()) {
      return true
    }

    let subtags = identifier.split(
      separator: "-",
      omittingEmptySubsequences: false
    )
    guard !subtags.isEmpty, !subtags.contains(where: \.isEmpty) else {
      return false
    }
    if subtags[0].lowercased() == "x" {
      return subtags.count > 1
        && subtags.dropFirst().allSatisfy(isPrivateUseSubtag)
    }

    var index = 0
    let languageLength = subtags[index].utf8.count
    guard
      (2...3).contains(languageLength)
        || languageLength == 4
        || (5...8).contains(languageLength),
      isAlphabetic(subtags[index])
    else {
      return false
    }
    index += 1

    if (2...3).contains(languageLength) {
      var extlangCount = 0
      while index < subtags.count,
        subtags[index].utf8.count == 3,
        isAlphabetic(subtags[index]),
        extlangCount < 3
      {
        extlangCount += 1
        index += 1
      }
    }
    if index < subtags.count,
      subtags[index].utf8.count == 4,
      isAlphabetic(subtags[index])
    {
      index += 1
    }
    if index < subtags.count {
      let length = subtags[index].utf8.count
      if (length == 2 && isAlphabetic(subtags[index]))
        || (length == 3 && isNumeric(subtags[index]))
      {
        index += 1
      }
    }

    var variants: Set<String> = []
    while index < subtags.count, isVariant(subtags[index]) {
      guard variants.insert(subtags[index].lowercased()).inserted else {
        return false
      }
      index += 1
    }

    var extensions: Set<String> = []
    while index < subtags.count, isExtensionSingleton(subtags[index]) {
      let singleton = subtags[index].lowercased()
      guard extensions.insert(singleton).inserted else {
        return false
      }
      index += 1
      let start = index
      while index < subtags.count, isExtensionSubtag(subtags[index]) {
        index += 1
      }
      guard index > start else {
        return false
      }
    }

    if index < subtags.count, subtags[index].lowercased() == "x" {
      index += 1
      let start = index
      while index < subtags.count, isPrivateUseSubtag(subtags[index]) {
        index += 1
      }
      guard index > start else {
        return false
      }
    }
    return index == subtags.count
  }

  private static func isAlphabetic(_ subtag: Substring) -> Bool {
    subtag.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0)
    }
  }

  private static func isNumeric(_ subtag: Substring) -> Bool {
    subtag.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func isAlphaNumeric(_ subtag: Substring) -> Bool {
    subtag.utf8.allSatisfy {
      (48...57).contains($0)
        || (65...90).contains($0)
        || (97...122).contains($0)
    }
  }

  private static func isVariant(_ subtag: Substring) -> Bool {
    let length = subtag.utf8.count
    return ((5...8).contains(length) && isAlphaNumeric(subtag))
      || (length == 4
        && subtag.utf8.first.map { (48...57).contains($0) } == true
        && isAlphaNumeric(subtag))
  }

  private static func isExtensionSingleton(_ subtag: Substring) -> Bool {
    guard subtag.utf8.count == 1, isAlphaNumeric(subtag) else {
      return false
    }
    return subtag.lowercased() != "x"
  }

  private static func isExtensionSubtag(_ subtag: Substring) -> Bool {
    (2...8).contains(subtag.utf8.count) && isAlphaNumeric(subtag)
  }

  private static func isPrivateUseSubtag(_ subtag: Substring) -> Bool {
    (1...8).contains(subtag.utf8.count) && isAlphaNumeric(subtag)
  }
}
