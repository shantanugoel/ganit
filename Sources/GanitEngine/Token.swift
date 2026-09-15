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

public enum TokenKind: Equatable, Sendable {
  case number(NumericLiteral)
  case identifier(String)
  case plus
  case minus
  case multiply
  case divide
  case power
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
