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
}
