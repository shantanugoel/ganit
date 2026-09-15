public enum NumericRadix: Int, Equatable, Sendable {
  case binary = 2
  case octal = 8
  case decimal = 10
  case hexadecimal = 16
}

public enum NumericLiteral: Equatable, Sendable {
  case integer(digits: String, radix: NumericRadix)
  case decimal(digits: String, fractionalDigitCount: Int, exponent: Int)
}

/// A wall-clock date and time with an optional UTC offset and zone, as in
/// `2024-11-03T01:30-04:00 America/New_York`.
public struct DateTimeLiteral: Equatable, Sendable {
  public var year: Int
  public var month: Int
  public var day: Int
  public var hour: Int
  public var minute: Int
  public var second: Int
  /// The UTC offset in seconds.
  public var offset: Int?
  /// An IANA zone identifier.
  public var zone: String?
}

/// A date or time written in ISO 8601 form, or in an English phrase. Fields
/// are validated when evaluated.
public enum TemporalLiteral: Equatable, Sendable {
  /// A calendar date; a `nil` year is the current year.
  case date(year: Int?, month: Int, day: Int)
  case time(hour: Int, minute: Int, second: Int)
  /// A date and time, in the evaluation time zone unless an offset or zone is
  /// given.
  case dateTime(DateTimeLiteral)
  /// Today moved by a number of days: `yesterday`, `today`, `tomorrow`.
  case relativeDay(Int)
  case now
  /// The next or last weekday strictly after or before today; weekdays count
  /// from Sunday as 1.
  case weekday(Int, isNext: Bool)
}

public enum TokenKind: Equatable, Sendable {
  case number(NumericLiteral)
  case temporal(TemporalLiteral)
  /// A currency symbol such as `€`, `US$`, or the ambiguous `$`.
  case currencySymbol(String)
  case identifier(String)
  case plus
  case minus
  case multiply
  case divide
  case power
  case superscript(Int)
  case percent
  case leftParenthesis
  case rightParenthesis
  case argumentSeparator
  case newline
  case endOfFile
}

public struct Token: Equatable, Sendable {
  public let kind: TokenKind
  public let range: SourceRange

  package init(kind: TokenKind, range: SourceRange) {
    self.kind = kind
    self.range = range
  }
}

public struct LexingConfiguration: Hashable, Sendable {
  public let decimalSeparator: Character
  public let groupingSeparator: Character?
  public let primaryGroupingSize: Int
  public let secondaryGroupingSize: Int

  public init(
    decimalSeparator: Character,
    groupingSeparator: Character?,
    primaryGroupingSize: Int = 3,
    secondaryGroupingSize: Int = 3
  ) {
    precondition(primaryGroupingSize > 0)
    precondition(secondaryGroupingSize > 0)
    precondition(groupingSeparator != decimalSeparator)
    self.decimalSeparator = decimalSeparator
    self.groupingSeparator = groupingSeparator
    self.primaryGroupingSize = primaryGroupingSize
    self.secondaryGroupingSize = secondaryGroupingSize
  }

  public static let englishUnitedStates = LexingConfiguration(
    decimalSeparator: ".",
    groupingSeparator: ","
  )
}

public struct LexingResult: Equatable, Sendable {
  public let tokens: [Token]
  public let diagnostics: [SyntaxDiagnostic]

  package init(tokens: [Token], diagnostics: [SyntaxDiagnostic]) {
    self.tokens = tokens
    self.diagnostics = diagnostics
  }
}
