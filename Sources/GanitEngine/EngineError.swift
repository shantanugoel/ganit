public enum EngineErrorCode: String, Hashable, Sendable {
  case zeroDenominator = "numeric.zeroDenominator"
  case invalidIntegerLiteral = "numeric.invalidIntegerLiteral"
  case integerLiteralTooLong = "numeric.integerLiteralTooLong"
  case invalidDecimalScale = "numeric.invalidDecimalScale"
  case nonFiniteApproximation = "numeric.nonFiniteApproximation"
  case invalidApproximationPrecision = "numeric.invalidApproximationPrecision"
  case negativeApproximationErrorBound = "numeric.negativeApproximationErrorBound"
  case divisionByZero = "evaluation.divisionByZero"
  case invalidDomain = "evaluation.invalidDomain"
  case overflow = "evaluation.overflow"
  case nonConvergence = "evaluation.nonConvergence"
}

public enum DiagnosticSeverity: String, Hashable, Sendable {
  case incomplete
  case warning
  case ambiguity
  case error
}

public struct DiagnosticFixIt: Hashable, Sendable {
  public let range: SourceRange
  public let replacement: String
  public let messageKey: String

  public init(
    range: SourceRange,
    replacement: String,
    messageKey: String
  ) {
    self.range = range
    self.replacement = replacement
    self.messageKey = messageKey
  }
}

public enum EngineErrorContext: Hashable, Sendable {
  case none
  case significantDecimalDigits(Int)
  case maximumIntegerDigits(Int)
}

public struct EngineError: Error, Hashable, Sendable {
  public let code: EngineErrorCode
  public let severity: DiagnosticSeverity
  public let ranges: [SourceRange]
  public let fixIts: [DiagnosticFixIt]
  public let context: EngineErrorContext

  public var messageKey: String {
    "error.\(code.rawValue)"
  }

  public init(
    code: EngineErrorCode,
    severity: DiagnosticSeverity = .error,
    ranges: [SourceRange] = [],
    fixIts: [DiagnosticFixIt] = [],
    context: EngineErrorContext = .none
  ) {
    self.code = code
    self.severity = severity
    self.ranges = ranges
    self.fixIts = fixIts
    self.context = context
  }
}
