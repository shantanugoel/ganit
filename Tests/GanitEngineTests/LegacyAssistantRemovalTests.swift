import Testing

@testable import GanitEngine

@Suite struct LegacyAssistantRemovalTests {
  @Test func oldFunctionNameUsesOrdinaryUnknownFunctionError() throws {
    let result = CalculationEngine().evaluate("ask_assistant(10)", context: try sheetContext())
    guard case .evaluationFailure(let error) = result else {
      Issue.record("Expected an unknown function error")
      return
    }
    #expect(error.code == .unknownFunction)
  }

  @Test(arguments: [
    "ask_assistant({weight} kg)",
    "ask_assistant(what's 5 (roughly)?)",
    "ask_assistant(price of {})",
  ])
  func oldPromptsUseOrdinarySyntaxErrors(source: String) {
    #expect(!Parser(source: source).parse().diagnostics.isEmpty)
  }

  @Test func aRemovedCallCannotSupplyADownstreamValue() throws {
    var calculator = SheetCalculator()
    let source = SheetSource("mass = ask_assistant(10)\nmass * 2\n@1 + 1")
    let result = try calculator.evaluate(source, context: sheetContext())
    #expect(result.lines.count == 3)
    for line in result.lines {
      guard case .evaluationFailure = line.result else {
        Issue.record("Expected an ordinary evaluation error")
        continue
      }
    }
    #expect(result.lines[1].failureOriginLineNumbers == [1])
    #expect(result.lines[2].failureOriginLineNumbers == [1])
  }
}
