import Foundation
import Testing

@testable import GanitEngine

@Suite
struct UsageTests {
  @Test
  func readsEverydayMoneyAndScaleWords() throws {
    let engine = CalculationEngine()
    let context = try sheetContext()
    func value(_ source: String) throws -> EngineValue {
      guard case .value(let value) = engine.evaluate(source, context: context) else {
        Issue.record("Expected a value for \(source)")
        throw EngineError(code: .internalFailure)
      }
      return value
    }

    #expect(try equal(value("$1.5"), value("1.5 USD")))
    #expect(try equal(value("USD 1.5"), value("1.5 USD")))
    #expect(try equal(value("5 dollars"), value("5 USD")))
    #expect(try equal(value("5 bucks"), value("5 USD")))
    #expect(try equal(value("11.5 million"), value("11500000")))
    #expect(try equal(value("11.5mn"), value("11500000")))
    #expect(try equal(value("11.5 mn"), value("11500000")))
    #expect(try equal(value("2 billion"), value("2000000000")))
    #expect(try equal(value("3k"), value("3000")))
    #expect(try equal(value("2 dozen"), value("24")))
    #expect(try equal(value("2 lakh"), value("200000")))
    #expect(try equal(value("1 crore"), value("10000000")))
    for suffix in ["m", "M", "mn", "MN"] {
      #expect(try equal(value("1.1\(suffix)"), value("1100000")), "\(suffix)")
      #expect(try equal(value("$1.1\(suffix)"), value("1100000 USD")), "\(suffix)")
    }
    for suffix in ["l", "L"] {
      #expect(try equal(value("7.23\(suffix)"), value("723000")), "\(suffix)")
    }
    for suffix in ["cr", "CR"] {
      #expect(try equal(value("2\(suffix)"), value("20000000")), "\(suffix)")
    }
    #expect(try equal(value("1 m"), value("1 m")))
    #expect(try equal(value("1 L"), value("1 L")))
    #expect(try equal(value("inr7.23 + 1.15 inr"), value("8.38 INR")))
    #expect(try equal(value("INR 7.23 lakh"), value("723000 INR")))
    #expect(try equal(value("50 percent"), value("50%")))
    #expect(try equal(value("50 pct"), value("50%")))
    #expect(try equal(value("$1.5 million"), value("1500000 USD")))
    #expect(try equal(value("1.5 million USD"), value("1500000 USD")))
    #expect(try equal(value("USD 1.5 million"), value("1500000 USD")))
    #expect(try equal(value("1.5$"), value("1.5 USD")))
    #expect(try equal(value("dollars 5"), value("5 USD")))
    #expect(try equal(value("kg 5"), value("5 kg")))
    #expect(try equal(value("km/h 60"), value("60 km/h")))
    #expect(try equal(value("million 2"), value("2000000")))
    #expect(try equal(value("days 3"), value("3 days")))
    #expect(try equal(value("¥5"), value("5 JPY")))
    guard case .quantity(let kelvin) = try value("3 K") else {
      Issue.record("Expected kelvin")
      return
    }
    #expect(kelvin.unit.dimension == .temperature)
    #expect(try sheetOutcomes("k = 5\n10k")[1] == "50")
    #expect(try sheetOutcomes("cup5 = 7\ncup5")[1] == "7")

    let cad = try sheetContext(dollarCurrency: "CAD")
    guard case .value(.money(let money)) = engine.evaluate("$2", context: cad) else {
      Issue.record("Expected CAD money")
      return
    }
    #expect(money.currency == "CAD")
  }

  @Test
  func nestedParenthesesDoNotTrapTheSheetCalculator() throws {
    let engine = CalculationEngine()
    let context = try sheetContext()
    let source = "((((((((((((((((1))))))))))))))))"
    var calculator = SheetCalculator(engine: engine)
    guard
      case .value = try calculator.evaluate(SheetSource(source), context: context).lines[0]
        .result
    else {
      Issue.record("Expected a value")
      return
    }
  }

  @Test
  func sheetCanChooseAmbiguousSuffixMeanings() throws {
    let engine = CalculationEngine()
    let base = try sheetContext()
    let scale = base.with(
      dollarCurrency: "USD", isMarkdownMode: false,
      ambiguousSuffixes: ["m": .scale, "l": .scale])
    let unit = base.with(
      dollarCurrency: "USD", isMarkdownMode: false,
      ambiguousSuffixes: ["m": .unit, "l": .unit])
    let cupCurrency = base.with(
      dollarCurrency: "USD", isMarkdownMode: false,
      ambiguousSuffixes: ["cup": .currency])
    guard case .value(let spacedMillion) = engine.evaluate("2 m", context: scale),
      case .value(let attachedMetres) = engine.evaluate("2m", context: unit),
      case .value(let spacedLakh) = engine.evaluate("3 L", context: scale),
      case .value(let attachedLitres) = engine.evaluate("3L", context: unit)
    else {
      Issue.record("Expected sheet-wide suffix choices to parse")
      return
    }
    #expect(try equal(spacedMillion, .number(.integer(IntegerValue(2_000_000)))))
    #expect(try equal(attachedMetres, engineValue("2 m", context: base)))
    #expect(try equal(spacedLakh, .number(.integer(IntegerValue(300_000)))))
    #expect(try equal(attachedLitres, engineValue("3 L", context: base)))
    #expect(try engineValue("5 cup", context: cupCurrency).kind == .money)
    #expect(try engineValue("5 cup", context: base).kind == .quantity)
  }

  private func engineValue(_ source: String, context: EvaluationContext) throws -> EngineValue {
    guard case .value(let value) = CalculationEngine().evaluate(source, context: context) else {
      throw EngineError(code: .internalFailure)
    }
    return value
  }

  private func equal(_ value: EngineValue, _ expected: EngineValue) throws -> Bool {
    let operations = NumericOperations(context: try sheetContext(), limits: .default)
    func amount(_ value: EngineValue) -> NumericValue? {
      switch value {
      case .number(let number):
        return number
      case .percentage(let percentage):
        return percentage.points
      case .money(let money):
        return money.amount
      case .quantity(let quantity):
        return quantity.magnitude
      default:
        return nil
      }
    }
    switch (value, expected) {
    case (.money(let lhs), .money(let rhs)):
      return try lhs.currency == rhs.currency
        && operations.applying(.subtract, left: lhs.amount, right: rhs.amount).isZero
    default:
      guard value.kind == expected.kind, let left = amount(value), let right = amount(expected)
      else {
        return value == expected
      }
      return try operations.applying(.subtract, left: left, right: right).isZero
    }
  }
}
