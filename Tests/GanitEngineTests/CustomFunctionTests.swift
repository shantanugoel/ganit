import Foundation
import Testing

@testable import GanitEngine

@Suite
struct CustomFunctionTests {
  @Test
  func aDefinedFunctionAnswersItsCalls() throws {
    let outcomes = try sheetOutcomes(
      """
      area(w, h) = w * h
      area(3, 4)
      Area(2, 5) + 1
      rate = 2
      double(x) = x * rate
      double(5)
      sq(x) = x^2
      hyp(a, b) = sqrt(sq(a) + sq(b))
      hyp(3, 4)
      speed(d, t) = d / t
      speed(10 km, 2 h)
      nothing() = 7
      nothing()
      """
    )
    #expect(
      outcomes == [
        nil, "12", "11", "2", nil, "10", nil, nil, "5", nil, "value", nil, "7",
      ])
  }

  @Test
  func problemsAreReportedAtTheCall() throws {
    let sheet = SheetSource("f(x) = x + y\nf(1)\nf(1, 2)\ng(x) = g(x)\ng(1)\nh(x) = 1 +")
    let results = try evaluateSheet(sheet)
    guard case .evaluationFailure(let unknown) = results[1].result else {
      Issue.record("Expected the body's unknown word to fail the call")
      return
    }
    #expect(unknown.code == .unknownIdentifier)
    #expect(unknown.ranges.first?.text(in: "f(1)") == "f")
    guard case .evaluationFailure(let count) = results[2].result else {
      Issue.record("Expected an argument count mismatch")
      return
    }
    #expect(count.code == .argumentCountMismatch)
    // A function sees only what is above it, so it cannot call itself.
    guard case .evaluationFailure(let recursive) = results[4].result else {
      Issue.record("Expected a function calling itself to be unknown")
      return
    }
    #expect(recursive.code == .unknownFunction)
    guard case .syntaxFailure = results[5].result else {
      Issue.record("Expected an incomplete body to be reported on its own line")
      return
    }
  }

  @Test
  func namesThatAreNotFunctionsStayNames() throws {
    let outcomes = try sheetOutcomes("Groceries (Costco) = 5\nsqrt(x) = x\nf(x, x) = x")
    #expect(outcomes.allSatisfy { $0 != nil })
  }

  @Test
  func theDefinitionsSheetSharesItsFunctions() throws {
    let definitions = try SheetDefinitions(
      source: "tax(amount) = amount * 20%", context: try sheetContext())
    #expect(definitions.functions["tax"]?.parameters == ["amount"])
    var calculator = SheetCalculator(definitions: definitions)
    let results = try calculator.evaluate(SheetSource("tax(100)"), context: try sheetContext())
    guard case .value(.number(let tax)) = results.lines[0].result else {
      Issue.record("Expected the shared function to answer")
      return
    }
    #expect(tax == .integer(IntegerValue(20)))
  }

  @Test
  func changingAFunctionRecalculatesItsCalls() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("f(x) = x * 2\nf(5)")
    let before = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(before.lines[1].result == .value(.number(.integer(IntegerValue(10)))))
    sheet.replace(utf8Range: 11..<12, with: "3")
    let after = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(after.lines[1].result == .value(.number(.integer(IntegerValue(15)))))
  }
}
