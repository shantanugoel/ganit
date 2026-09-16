import Foundation
import Testing

@testable import GanitEngine

func evaluateSheet(_ sheet: SheetSource) throws -> [SheetLineResult] {
  var calculator = SheetCalculator()
  return try calculator.evaluate(sheet, context: try sheetContext()).lines
}

/// Evaluates a sheet and summarizes each line: exact integers and fractions,
/// percentages, `value` for other values, message keys for failures, and
/// `nil` for lines without an expression.
func sheetOutcomes(_ source: String) throws -> [String?] {
  var calculator = SheetCalculator()
  return try calculator.evaluate(SheetSource(source), context: try sheetContext()).lines.map {
    switch $0.result {
    case nil:
      return nil
    case .value(.number(let number)):
      return summary(of: number)
    case .value(.percentage(let percentage)):
      return summary(of: percentage.points).map { $0 + "%" } ?? "value"
    case .value:
      return "value"
    case .syntaxFailure(let diagnostics):
      return diagnostics.first?.messageKey
    case .evaluationFailure(let error):
      return error.messageKey
    }
  }
}

func sheetContext(
  angleMode: AngleMode = .radians,
  isMarkdownMode: Bool = false,
  dollarCurrency: String = "USD"
) throws
  -> EvaluationContext
{
  try EvaluationContext(
    localeIdentifier: "en-US",
    lexingConfiguration: .englishUnitedStates,
    angleMode: angleMode,
    precision: PrecisionContext(significantDecimalDigits: 15),
    now: Date(timeIntervalSince1970: 0),
    calendar: Calendar(identifier: .gregorian),
    timeZone: try #require(TimeZone(identifier: "UTC")),
    dollarCurrency: dollarCurrency,
    isMarkdownMode: isMarkdownMode
  )
}

private func summary(of number: NumericValue) -> String? {
  switch number {
  case .integer(let integer):
    return integer.canonicalDigits
  case .rational(let rational):
    return "\(rational.numerator.canonicalDigits)/\(rational.denominator.canonicalDigits)"
  case .decimal, .approximate:
    return nil
  }
}

struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next(below bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(bound))
  }
}
