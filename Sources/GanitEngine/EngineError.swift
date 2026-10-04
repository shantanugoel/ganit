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
  case brokenReference = "evaluation.brokenReference"
  case invalidReference = "evaluation.invalidReference"
  /// A qualified table operand in a sheet line, or a line reference to a
  /// table block's source line, that cannot be read; the context says why.
  case tableReference = "evaluation.tableReference"
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
  /// The original failures, deduplicated and in sheet order.
  case failedLines([Int])
  case brokenReference(BrokenLineReferenceReason)
  /// A variable whose declaration failed.
  case failedVariable(String)
  case evaluationContext(EvaluationContextField)
  case argumentCount(
    function: String,
    expected: ClosedRange<Int>,
    actual: Int
  )
  case typeMismatch(expected: EngineValueKind, actual: EngineValueKind)
  case aggregateTypeMismatch(
    firstLine: Int, firstKind: EngineValueKind, otherLine: Int, otherKind: EngineValueKind)
  case dimensionMismatch(expected: Dimension, actual: Dimension)
  case resourceLimit(EvaluationResource)
  case tableReference(TableReferenceProblem)
}

/// Why a sheet line cannot read a table operand.
public enum TableReferenceProblem: String, Hashable, Sendable {
  /// `@N`/`line N` names a table block's source line, which has no answer.
  case tableLine
  /// No table of that name is visible above the line (later tables and
  /// tables above a divider are not).
  case unknownTable
  /// The table has no column with that header.
  case unknownColumn
  /// An address outside the table's bounds.
  case outOfBounds
  /// A reference that is not well formed, or a deleted-target marker.
  case malformed
  /// A text, blank or header cell, or a range, where a value is needed.
  case notScalar
  /// The cell, or a member of the range, has an error.
  case failedCell
  /// The table could not be calculated, such as over a resource limit.
  case unavailableTable
  /// average, median, min or max of no values.
  case emptyRange
  /// An aggregate the range's kinds do not support.
  case unsupportedAggregation
  /// The definitions sheet declares names; it never calculates a table, so
  /// nothing a table holds is shared with every sheet.
  case definitions
  /// Quick Ganit does not calculate tables; Keep as Sheet opens the buffer,
  /// table included, as a sheet.
  case quickGanit
  /// One expression, as a service, Shortcuts or a URL action answers, cannot
  /// hold a table block.
  case expression
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
