import Foundation
import Testing

@testable import GanitEngine

@Suite
struct VariableTests {
  @Test
  func declaresSingleAndMultiWordVariablesTopToBottom() throws {
    let results = try evaluate(
      """
      monthly rent = 2,100
      months = 12
      Yearly: monthly rent * months // before utilities
      monthly rent in total = 1
      monthly   rent + 1
      """
    )

    #expect(results[0] == "2100")
    #expect(results[1] == "12")
    #expect(results[2] == "25200")
    #expect(results[3] == "syntax.invalidVariableName")
    #expect(results[4] == "2101")
  }

  @Test
  func matchesTheLongestDeclaredName() throws {
    let results = try evaluate("rent = 1\nrent total = 20\nrent total\nrent + rent total")

    #expect(results[2] == "20")
    #expect(results[3] == "21")
  }

  @Test
  func requiresDeclarationBeforeUse() throws {
    let results = try evaluate(
      """
      tax + 1
      tax = 8%
      tax of 50
      tax = tax + 2%
      tax
      """
    )

    #expect(results[0] == "error.evaluation.unknownIdentifier")
    #expect(results[1] == "8%")
    #expect(results[2] == "4")
    #expect(results[4] == "10%")
  }

  @Test
  func dividersResetScopeButHeadingsDoNot() throws {
    let results = try evaluate(
      """
      rate = 3
      # Section
      rate * 2
      ---
      rate * 2
      """
    )

    #expect(results[2] == "6")
    #expect(results[4] == "error.evaluation.unknownIdentifier")
  }

  @Test
  func usesOfFailedDeclarationsReportTheDefinitionError() throws {
    let sheet = SheetSource("distance = 1 m + 1 s\ndistance in km\ndistance =\n")
    let results = CalculationEngine().evaluate(sheet, context: try context())

    guard case .evaluationFailure(let error) = results[1].result else {
      Issue.record("Expected an unavailable variable")
      return
    }
    #expect(error.code == .unavailableVariable)
    #expect(error.ranges.first?.text(in: sheet.text) == "distance")

    guard case .syntaxFailure(let diagnostics) = results[2].result else {
      Issue.record("Expected an incomplete declaration")
      return
    }
    #expect(diagnostics.first?.code == .expectedExpression)
    #expect(diagnostics.first?.severity == .incomplete)
  }

  @Test
  func rejectsReservedAndNonWordNames() throws {
    for source in [
      "in = 1", "pi = 3", "e = 2", "min = 1", "km = 5", "kW = 3", "total km = 3",
      "2x = 1", "a-b = 1", "percentage = 5",
    ] {
      let results = try evaluate(source)
      #expect(results[0] == "syntax.invalidVariableName", "\(source)")
    }
  }

  @Test
  func quantityVariablesKeepConversionAndMultiWordRanges() throws {
    let sheet = SheetSource("trip distance = 12 km\ntrip distance in miles\ntrip distance + 1")
    let results = CalculationEngine().evaluate(sheet, context: try context())

    guard case .value(.quantity) = results[1].result else {
      Issue.record("Expected a converted quantity")
      return
    }
    guard case .evaluationFailure(let error) = results[2].result else {
      Issue.record("Expected a type mismatch")
      return
    }
    #expect(error.code == .typeMismatch)
    guard case .calculation(_, let name?, _, _) = results[0].syntax else {
      Issue.record("Expected a declaration")
      return
    }
    #expect(name.text(in: sheet.text) == "trip distance")
  }

  private func evaluate(_ source: String) throws -> [String?] {
    let context = try context()
    return CalculationEngine().evaluate(SheetSource(source), context: context).map {
      switch $0.result {
      case nil:
        return nil
      case .value(.number(.integer(let integer))):
        return integer.canonicalDigits
      case .value(.percentage(let percentage)):
        guard case .integer(let points) = percentage.points else {
          return "value"
        }
        return points.canonicalDigits + "%"
      case .value:
        return "value"
      case .syntaxFailure(let diagnostics):
        return diagnostics.first?.messageKey
      case .evaluationFailure(let error):
        return error.messageKey
      }
    }
  }

  private func context() throws -> EvaluationContext {
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
}
