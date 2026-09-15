import Foundation
import Testing

@testable import GanitEngine

@Suite
struct FinanceTests {
  @Test
  func computesTheFormulaAPersonWouldWriteByHand() throws {
    try expectEqual("fv(1000, 10%, 2)", "1000 * 1.1^2")
    try expectEqual("pv(1210, 10%, 2)", "1210 / 1.1^2")
    try expectEqual("pmt(1000, 5%, 3)", "1000 * 0.05 / (1 - 1 / 1.05^3)")
    // A rate may also be written as the fraction it is.
    try expectEqual("fv(1000, 0.1, 2)", "fv(1000, 10%, 2)")
    // Without a rate, a loan is repaid in equal parts.
    try expectEqual("pmt(1200, 0%, 12)", "100")
    // Compounding whole periods is exact arithmetic, not an estimate.
    #expect(try evaluate("fv(1000, 10%, 2)") == .number(.integer(IntegerValue(1210))))
  }

  @Test
  func keepsMoneyInItsCurrency() throws {
    try expectEqual("fv(1000 USD, 5%, 2)", "1000 USD * 1.05^2")
    try expectEqual("fv(1000 USD, 5%, 2)", "1102.50 USD")
    try expectEqual(
      "pmt(300000 EUR, 0.5%, 360)", "300000 EUR * 0.005 / (1 - 1 / 1.005^360)")

    let value = try evaluate("fv(1000 USD, 5%, 2)")
    guard case .money(let money) = value else {
      Issue.record("Expected money, got \(value)")
      return
    }
    #expect(money.currency == "USD")
  }

  @Test
  func refusesArgumentsThatWouldHideAnAssumption() throws {
    // A fraction of a period would compound by a rule no one stated, and
    // no periods at all is not a calculation.
    #expect(try error("fv(1000, 5%, 1.5)").code == .invalidDomain)
    #expect(try error("fv(1000, 5%, 0)").code == .invalidDomain)
    #expect(try error("fv(1000, 5%, -2)").code == .invalidDomain)
    #expect(try error("fv(1 m, 5%, 2)").code == .typeMismatch)
    #expect(try error("fv(1000, 5 m, 2)").code == .typeMismatch)

    let arguments = try error("fv(1000, 5%)")
    #expect(arguments.code == .argumentCountMismatch)
    #expect(arguments.context == .argumentCount(function: "fv", expected: 3...3, actual: 2))
  }

  @Test
  func reportsTheAssumptionsAnAnswerRestsOn() throws {
    let lines = try evaluateSheet(SheetSource("fv(1000, 5%, 2)\npmt(1000, 5%, 3)\n2 + 2"))

    #expect(lines.map(\.financeUses) == [[.futureValue], [.payment], []])
  }

  @Test
  func reservesItsNamesSoTheyMeanOneThing() throws {
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(
      SheetSource("pmt = 5\nfv = 2"), context: try sheetContext())

    #expect(
      evaluation.lines.allSatisfy {
        if case .syntaxFailure(let diagnostics) = $0.result {
          return diagnostics.map(\.code) == [.invalidVariableName]
        }
        return false
      }
    )
  }

  /// Two expressions are the same amount when their difference is zero,
  /// whatever exact representation each one reached it by.
  private func expectEqual(
    _ source: String,
    _ expected: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) throws {
    let difference = try evaluate("(\(source)) - (\(expected))")
    switch difference {
    case .number(let number):
      #expect(number.isZero, "\(source) is not \(expected)", sourceLocation: sourceLocation)
    case .money(let money):
      #expect(money.amount.isZero, "\(source) is not \(expected)", sourceLocation: sourceLocation)
    default:
      Issue.record(
        "\(source) is not a number or an amount of money", sourceLocation: sourceLocation)
    }
  }

  private func evaluate(_ source: String) throws -> EngineValue {
    let parsing = Parser(source: source).parse()
    #expect(parsing.diagnostics.isEmpty, "\(source)")
    return try Evaluator(context: sheetContext()).evaluate(try #require(parsing.expression))
  }

  private func error(_ source: String) throws -> EngineError {
    do {
      let value = try evaluate(source)
      Issue.record("Expected an error for \(source), got \(value)")
      throw EngineError(code: .invalidDomain)
    } catch let error as EngineError {
      return error
    }
  }

  private func requireNumber(_ value: EngineValue) throws -> NumericValue {
    guard case .number(let number) = value else {
      throw EngineError(code: .typeMismatch)
    }
    return number
  }
}
