public struct SyntaxDiagnostic: Hashable, Sendable {
  public enum Code: String, Hashable, Sendable {
    case unexpectedCharacter
    case mixedDigitScripts
    case missingRadixDigits
    case invalidRadixDigit
    case missingFractionDigits
    case missingExponentDigits
    case exponentOutOfRange
    case expectedExpression
    case expectedClosingParenthesis
    case expectedArgumentSeparator
    case unexpectedToken
    case resourceLimitExceeded
  }

  public let code: Code
  public let range: SourceRange

  package init(code: Code, range: SourceRange) {
    self.code = code
    self.range = range
  }
}
