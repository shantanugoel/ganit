import Foundation
import GanitEngine
import Testing

@testable import GanitSystemIntegration

@Suite
struct ExpressionCalculationTests {
  @Test
  func answersEveryLineOfASheet() throws {
    let answers = try ExpressionCalculation().answers(
      forSheet: "# Rent\nrent = 2,100\nrent * 12\n\nfoo\n1 +")

    #expect(
      answers == [
        SheetAnswer(text: nil, isFailure: false),
        SheetAnswer(text: "2,100", isFailure: false),
        SheetAnswer(text: "25,200", isFailure: false),
        SheetAnswer(text: nil, isFailure: false),
        SheetAnswer(text: "This identifier is not defined.", isFailure: true),
        SheetAnswer(text: "Enter an expression here.", isFailure: true),
      ])
  }

  @Test
  func answersTheSameWayASheetDisplaysIt() throws {
    let calculation = ExpressionCalculation()

    #expect(try calculation.answer(for: "20% off 85") == "68")
    // Each argument of `ganit` is a line, so a declaration reaches the next one.
    let lines = try calculation.answers(forSheet: "rent = 3\nrent * 12")
    #expect(lines.map(\.text) == ["3", "36"])
    #expect(!lines.contains { $0.isFailure })
    #expect(try calculation.answer(for: "12 km in miles") == "≈ 7.45645430684801 mi")
    #expect(try calculation.answer(for: "1/3") == "≈ 0.333333333333333")
  }

  @Test
  func answersCurrencyFromTheRatesItWasGiven() throws {
    let calculation = ExpressionCalculation(
      rates: try CurrencyRates(
        unitsPerEuro: ["USD": "1.5"],
        observationDate: "2026-09-14",
        retrievedAt: Date(timeIntervalSince1970: 0)
      )
    )

    #expect(try calculation.answer(for: "15 USD in EUR") == "€10.00")
  }

  @Test
  func refusesCurrencyConversionWithoutRatesRatherThanInventingOne() throws {
    let missing = #expect(throws: UnevaluableExpression.self) {
      try ExpressionCalculation().answer(for: "15 USD in EUR")
    }
    #expect(missing?.diagnostics.first?.code == "evaluation.currencyRatesUnavailable")
  }

  @Test
  func explainsAnExpressionItCannotAnswerInsteadOfGuessing() throws {
    let calculation = ExpressionCalculation()

    let syntax = #expect(throws: UnevaluableExpression.self) {
      try calculation.answer(for: "2 +")
    }
    #expect(syntax?.errorDescription?.isEmpty == false)

    let evaluation = #expect(throws: UnevaluableExpression.self) {
      try calculation.answer(for: "1/0")
    }
    #expect(evaluation?.diagnostics.first?.code == "evaluation.divisionByZero")

    let empty = #expect(throws: UnevaluableExpression.self) {
      try calculation.answer(for: "   ")
    }
    #expect(empty?.errorDescription?.isEmpty == false)
  }

  @Test
  func refusesSourceLongerThanAnotherProcessMaySend() throws {
    let calculation = ExpressionCalculation()
    let tooLong = "1 + " + String(repeating: "1 + ", count: 1_100) + "1"
    #expect(tooLong.utf8.count > ExpressionCalculation.maximumSourceUTF8Length)

    #expect(throws: UnevaluableExpression.self) {
      try calculation.answer(for: tooLong)
    }
  }

  /// A table block is not one expression: services, Shortcuts and URL
  /// actions explain that instead of reading its lines as one expression.
  @Test
  func explainsThatATableIsNotOneExpression() throws {
    let block =
      "@ganit-table 1\n{\"ids\":[\"abcdef00-0000-4000-8000-000000000001\","
      + "\"abcdef00-0000-4000-8000-000000000011\"],\"t\":0,\"n\":\"Items\","
      + "\"c\":[{\"i\":1,\"h\":\"Qty\",\"p\":\"value\"}],\"r\":[],\"x\":[],\"b\":[]}\n"
      + "@end-ganit-table\n"
    let calculation = ExpressionCalculation()
    for source in [
      block, block + "2 + 2", "2 + 2\n" + block, "@ganit-table 1", "@ganit-table 2\n{}",
    ] {
      let failure = #expect(throws: UnevaluableExpression.self) {
        try calculation.answer(for: source)
      }
      #expect(failure?.diagnostics.first?.code == "evaluation.tableReference", "\(source)")
      #expect(failure?.errorDescription?.contains("one expression") == true)
    }
    // Text that only looks like a table stays an expression.
    let prose = #expect(throws: UnevaluableExpression.self) {
      try calculation.answer(for: " @ganit-table 1")
    }
    #expect(prose?.diagnostics.first?.code != "evaluation.tableReference")
  }

  /// A sheet's table lines never answer as ordinary lines; prose reads the
  /// table by name.
  @Test
  func sheetAnswersNeverFlattenTableRows() throws {
    let block =
      "@ganit-table 1\n{\"ids\":[\"abcdef00-0000-4000-8000-000000000001\","
      + "\"abcdef00-0000-4000-8000-000000000011\",\"abcdef00-0000-4000-8000-000000000021\"],"
      + "\"t\":0,\"n\":\"Items\",\"c\":[{\"i\":1,\"h\":\"Qty\",\"p\":\"value\"}],"
      + "\"r\":[2],\"x\":[{\"a\":[2,1],\"s\":\"5\"}],\"b\":[]}\n@end-ganit-table\n"
    let answers = try ExpressionCalculation().answers(
      forSheet: "1\n" + block + "sum(Items[Qty]) * 2\nsum")
    #expect(
      answers == [
        SheetAnswer(text: "1", isFailure: false),
        SheetAnswer(text: nil, isFailure: false),
        SheetAnswer(text: nil, isFailure: false),
        SheetAnswer(text: nil, isFailure: false),
        SheetAnswer(text: "10", isFailure: false),
        SheetAnswer(text: "10", isFailure: false),
      ])
  }
}
