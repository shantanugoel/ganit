import Foundation
import Testing

@testable import GanitEngine

/// Evaluates a sheet and summarizes each line: exact integers and fractions,
/// percentages, `value` for other values, message keys for failures, and
/// `nil` for lines without an expression.
func sheetOutcomes(_ source: String) throws -> [String?] {
  CalculationEngine().evaluate(SheetSource(source), context: try sheetContext()).map {
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

func sheetContext() throws -> EvaluationContext {
  try EvaluationContext(
    localeIdentifier: "en-US",
    lexingConfiguration: .englishUnitedStates,
    angleMode: .radians,
    precision: PrecisionContext(significantDecimalDigits: 15),
    now: Date(timeIntervalSince1970: 0),
    calendar: Calendar(identifier: .gregorian),
    timeZone: try #require(TimeZone(identifier: "UTC"))
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
