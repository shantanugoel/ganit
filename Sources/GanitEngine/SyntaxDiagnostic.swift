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
    case expectedPercentagePhrase
    case expectedConversionUnit
    case unknownUnit
    case invalidUnitExponent
    case expectedUnitClosingParenthesis
    case expectedClosingParenthesis
    case expectedArgumentSeparator
    case unexpectedToken
    case invalidVariableName
    case resourceLimitExceeded
  }

  public let code: Code
  public let severity: DiagnosticSeverity
  public let range: SourceRange

  public var messageKey: String {
    "syntax.\(code.rawValue)"
  }

  package init(
    code: Code,
    severity: DiagnosticSeverity = .error,
    range: SourceRange
  ) {
    self.code = code
    self.severity = severity
    self.range = range
  }
}
