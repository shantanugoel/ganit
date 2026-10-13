import Foundation
import Testing

@testable import GanitEngine

@Suite
struct AssistanceCatalogTests {
  @Test func functionsAndGrammarFactsComeFromTheNativeRegistries() throws {
    let context = try sheetContext()
    let catalog = CalculationEngine().assistanceCatalog(for: "mass density g ml", context: context)
    #expect(
      Set(catalog.functions.map(\.name))
        == Set(
          BuiltInFunction.allCases.map(\.rawValue)
            + FinanceFunction.allCases.map(\.rawValue) + StatisticsFunction.allCases.map(\.rawValue)
        ))
    #expect(catalog.functions.first { $0.name == "pmt" }?.minimumArguments == 3)
    #expect(catalog.functions.first { $0.name == "round" }?.maximumArguments == 2)
    #expect(Set(catalog.referenceWords) == Set(referenceKeywords.keys))
    #expect(catalog.syntaxCodes.contains("ambiguousSlashDate"))
    #expect(catalog.evaluationCodes.contains("evaluation.divisionByZero"))
    #expect(catalog.units.contains { $0.dimension == "mass" })
    #expect(catalog.units.contains { $0.dimension == "length^3" })
    #expect(!catalog.modelValueOperations)
  }

  @Test func examplesHaveIndependentExpectedResults() throws {
    let context = try sheetContext()
    let catalog = CalculationEngine().assistanceCatalog(for: "tip rate date", context: context)
    #expect(catalog.examples.count == 6)
    let percentage = try #require(catalog.examples.first { $0.source == "200 + 10%" })
    #expect(
      assistanceValuesEqual(
        percentage.result.value, .number(.integer(IntegerValue(220))), context: context))
    let money = try #require(catalog.examples.first { $0.source == "(2400 INR + 10%) / 4" })
    #expect(
      assistanceValuesEqual(
        money.result.value,
        .money(MoneyValue(amount: .integer(IntegerValue(660)), currency: "INR")), context: context))
    let rate = try #require(catalog.examples.first { $0.source == "6% / 12" })
    let half = try RationalValue(numerator: IntegerValue(1), denominator: IntegerValue(2))
    #expect(
      assistanceValuesEqual(
        rate.result.value,
        .percentage(PercentageValue(points: .rational(half))), context: context))
    for source in ["base = 40\nbase + 2", "40\n@1 + 2"] {
      let reference = try #require(catalog.examples.first { $0.source == source })
      #expect(reference.result.value == .number(.integer(IntegerValue(42))))
    }
    let date = try #require(catalog.examples.first { $0.source == "2024-02-29 + 1 year" })
    #expect(date.result.value == .date(try DateValue(year: 2025, month: 2, day: 28)))
  }
}
