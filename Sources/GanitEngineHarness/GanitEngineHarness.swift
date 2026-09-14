import Foundation
import GanitEngine
import GanitFormatting

@main
enum GanitEngineHarness {
  static func main() throws {
    let expressions = Array(CommandLine.arguments.dropFirst())
    let context = try fixedContext()
    let engine = CalculationEngine()
    let formatter = NumericResultFormatter(context: context)
    let diagnosticFormatter = DiagnosticFormatter(context: context)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    if expressions.isEmpty {
      while let expression = readLine(strippingNewline: true) {
        try emit(
          expression,
          engine: engine,
          formatter: formatter,
          diagnosticFormatter: diagnosticFormatter,
          context: context,
          encoder: encoder
        )
      }
    } else {
      for expression in expressions {
        try emit(
          expression,
          engine: engine,
          formatter: formatter,
          diagnosticFormatter: diagnosticFormatter,
          context: context,
          encoder: encoder
        )
      }
    }
  }

  private static func emit(
    _ expression: String,
    engine: CalculationEngine,
    formatter: NumericResultFormatter,
    diagnosticFormatter: DiagnosticFormatter,
    context: EvaluationContext,
    encoder: JSONEncoder
  ) throws {
    let record = evaluate(
      expression,
      engine: engine,
      formatter: formatter,
      diagnosticFormatter: diagnosticFormatter,
      context: context
    )
    let data = try encoder.encode(record)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private static func fixedContext() throws -> EvaluationContext {
    guard let timeZone = TimeZone(identifier: "UTC") else {
      throw HarnessFailure.missingUTCTimeZone
    }
    return try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }

  private static func evaluate(
    _ expression: String,
    engine: CalculationEngine,
    formatter: NumericResultFormatter,
    diagnosticFormatter: DiagnosticFormatter,
    context: EvaluationContext
  ) -> HarnessRecord {
    switch engine.evaluate(expression, context: context) {
    case .value(let value):
      do {
        let result = try formatter.format(value)
        return HarnessRecord(
          expression: expression,
          status: .value,
          display: result.display,
          fullPrecision: result.fullPrecision,
          approximate: result.isApproximate
        )
      } catch let error as FormattingError {
        let range = engine.parse(expression, context: context).expression?.range
        let diagnostic = diagnosticFormatter.format(
          error,
          ranges: range.map { [$0] } ?? []
        )
        return HarnessRecord(
          expression: expression,
          status: .formattingFailure,
          code: diagnostic.code,
          messageKey: error.messageKey,
          message: diagnostic.message,
          range: diagnostic.ranges.first.map { HarnessRange($0) }
        )
      } catch {
        let range = engine.parse(expression, context: context).expression?.range
        let formattingError = FormattingError.internalFailure
        let diagnostic = diagnosticFormatter.format(
          formattingError,
          ranges: range.map { [$0] } ?? []
        )
        return HarnessRecord(
          expression: expression,
          status: .formattingFailure,
          code: diagnostic.code,
          messageKey: formattingError.messageKey,
          message: diagnostic.message,
          range: diagnostic.ranges.first.map { HarnessRange($0) }
        )
      }

    case .syntaxFailure(let diagnostics):
      let first = diagnostics.first
      let range = first.map { HarnessRange($0.range) }
      let formattedDiagnostics = diagnostics.map {
        HarnessDiagnostic(diagnosticFormatter.format($0))
      }
      return HarnessRecord(
        expression: expression,
        status: .syntaxFailure,
        code: first?.code.rawValue,
        messageKey: first?.messageKey,
        message: first.map { diagnosticFormatter.format($0).message },
        range: range,
        diagnostics: formattedDiagnostics
      )

    case .evaluationFailure(let error):
      let range = error.ranges.first.map { HarnessRange($0) }
      let formatted = diagnosticFormatter.format(error)
      return HarnessRecord(
        expression: expression,
        status: .evaluationFailure,
        code: error.code.rawValue,
        messageKey: error.messageKey,
        message: formatted.message,
        range: range,
        diagnostics: [HarnessDiagnostic(formatted)]
      )
    }
  }
}

private enum HarnessFailure: Error {
  case missingUTCTimeZone
}

private struct HarnessRange: Codable {
  let lowerBound: Int
  let upperBound: Int
  let graphemeLowerBound: Int
  let graphemeUpperBound: Int

  init(_ range: SourceRange) {
    lowerBound = range.lowerBound
    upperBound = range.upperBound
    graphemeLowerBound = range.graphemeLowerBound
    graphemeUpperBound = range.graphemeUpperBound
  }
}

private struct HarnessDiagnostic: Codable {
  let code: String
  let severity: String
  let message: String
  let ranges: [HarnessRange]

  init(_ diagnostic: FormattedDiagnostic) {
    code = diagnostic.code
    severity = diagnostic.severity.rawValue
    message = diagnostic.message
    ranges = diagnostic.ranges.map { HarnessRange($0) }
  }
}

private struct HarnessRecord: Codable {
  enum Status: String, Codable {
    case value
    case syntaxFailure
    case evaluationFailure
    case formattingFailure
  }

  let expression: String
  let status: Status
  let display: String?
  let fullPrecision: String?
  let approximate: Bool?
  let code: String?
  let messageKey: String?
  let message: String?
  let range: HarnessRange?
  let diagnostics: [HarnessDiagnostic]?

  init(
    expression: String,
    status: Status,
    display: String? = nil,
    fullPrecision: String? = nil,
    approximate: Bool? = nil,
    code: String? = nil,
    messageKey: String? = nil,
    message: String? = nil,
    range: HarnessRange? = nil,
    diagnostics: [HarnessDiagnostic]? = nil
  ) {
    self.expression = expression
    self.status = status
    self.display = display
    self.fullPrecision = fullPrecision
    self.approximate = approximate
    self.code = code
    self.messageKey = messageKey
    self.message = message
    self.range = range
    self.diagnostics = diagnostics
  }
}
