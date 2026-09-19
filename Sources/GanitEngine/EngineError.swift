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
  case unknownIdentifier = "evaluation.unknownIdentifier"
  case unavailableReference = "evaluation.unavailableReference"
  case invalidReference = "evaluation.invalidReference"
  case unknownFunction = "evaluation.unknownFunction"
  case unresolvedAssistantPrompt = "evaluation.unresolvedAssistantPrompt"
  case unusableAssistantAnswer = "evaluation.unusableAssistantAnswer"
  case argumentCountMismatch = "evaluation.argumentCountMismatch"
  case typeMismatch = "evaluation.typeMismatch"
  case incompatibleDimensions = "evaluation.incompatibleDimensions"
  case invalidUnitDefinition = "evaluation.invalidUnitDefinition"
  case affineUnitInCompound = "evaluation.affineUnitInCompound"
  case invalidAbsoluteQuantityOperation =
    "evaluation.invalidAbsoluteQuantityOperation"
  case incompatibleRatePeriods = "evaluation.incompatibleRatePeriods"
  case invalidDate = "evaluation.invalidDate"
  case invalidTime = "evaluation.invalidTime"
  case fractionalCalendarPeriod = "evaluation.fractionalCalendarPeriod"
  case dateOutOfRange = "evaluation.dateOutOfRange"
  case nonexistentLocalTime = "evaluation.nonexistentLocalTime"
  case ambiguousLocalTime = "evaluation.ambiguousLocalTime"
  case offsetMismatch = "evaluation.offsetMismatch"
  case mixedCurrencies = "evaluation.mixedCurrencies"
  case missingCurrencyRate = "evaluation.missingCurrencyRate"
  case currencyRatesUnavailable = "evaluation.currencyRatesUnavailable"
  case invalidCurrencyRate = "evaluation.invalidCurrencyRate"
  case resourceLimitExceeded = "evaluation.resourceLimitExceeded"
  case approximationOutOfRange = "evaluation.approximationOutOfRange"
  case internalFailure = "evaluation.internalFailure"
  case invalidEvaluationContext = "evaluation.invalidContext"
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
  case rootDegree
  case rootRadicand
  /// A unit raised to a power that is not a whole number.
  case unitPower
  /// The one-based number of a line whose error a reference read.
  case failedLine(Int)
  /// A variable whose declaration failed.
  case failedVariable(String)
  case evaluationContext(EvaluationContextField)
  case argumentCount(
    function: String,
    expected: ClosedRange<Int>,
    actual: Int
  )
  case typeMismatch(expected: EngineValueKind, actual: EngineValueKind)
  case dimensionMismatch(expected: Dimension, actual: Dimension)
  case resourceLimit(EvaluationResource)
}

public enum EngineValueKind: String, Hashable, Sendable {
  case number
  case percentage
  case quantity
  case rate
  case date
  case time
  case instant
  case period
  case money
}

public enum EvaluationContextField: String, Hashable, Sendable {
  case locale
  case now
  case timeZone
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
