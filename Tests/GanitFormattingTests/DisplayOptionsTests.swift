import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct DisplayOptionsTests {
  @Test
  func writesTheDigitsASheetAsksFor() throws {
    let cases: [(DisplayOptions, String, String)] = [
      (.standard, "1234567.5", "1,234,567.5"),
      (DisplayOptions(groupsDigits: false), "1234567.5", "1234567.5"),
      (DisplayOptions(groupsInLakhs: true), "123456789.5", "12,34,56,789.5"),
      (DisplayOptions(groupsDigits: false, groupsInLakhs: true), "1234567", "1234567"),
      (DisplayOptions(numbers: .fixedDecimals(2)), "2", "2.00"),
      (DisplayOptions(numbers: .fixedDecimals(2)), "1.005", "1.01"),
      (DisplayOptions(numbers: .fixedDecimals(0)), "1234.6", "1,235"),
      (DisplayOptions(numbers: .fixedDecimals(4)), "1/3", "0.3333"),
      (DisplayOptions(numbers: .scientific), "1200", "1.2e3"),
      (DisplayOptions(numbers: .scientific), "1234.5", "1.2345e3"),
      (DisplayOptions(numbers: .scientific), "0.00012", "1.2e-4"),
      (DisplayOptions(numbers: .scientific), "-7", "-7e0"),
      (DisplayOptions(numbers: .scientific), "0", "0"),
      (DisplayOptions(numbers: .scientific), "1/3", "3.33333333333333e-1"),
    ]

    for (options, source, display) in cases {
      #expect(try format(source, options) == display, "\(source) as \(options)")
    }
  }

  /// A choice about writing is a choice about writing: copying an answer still
  /// yields the value, and the fixed decimals round the fraction rather than a
  /// rounded copy of it.
  @Test
  func keepsTheValueWhateverItLooksLike() throws {
    let engine = CalculationEngine()
    let evaluationContext = try context()
    let formatter = ResultFormatter(
      context: evaluationContext,
      display: DisplayOptions(groupsDigits: false, numbers: .fixedDecimals(2))
    )
    guard case .value(let value) = engine.evaluate("2/3", context: evaluationContext) else {
      Issue.record("Expected a value for 2/3")
      return
    }

    let formatted = try formatter.format(value)
    #expect(formatted.display == "0.67")
    #expect(formatted.fullPrecision == "2/3")
  }

  /// Money is written the way its currency is written, so a sheet's decimals
  /// and powers of ten leave it alone. Its digits still group with the rest.
  @Test
  func leavesMoneyToItsCurrency() throws {
    let cases: [(DisplayOptions, String)] = [
      (DisplayOptions(numbers: .fixedDecimals(4)), "$1,234.50"),
      (DisplayOptions(numbers: .scientific), "$1,234.50"),
      (DisplayOptions(groupsDigits: false), "$1234.50"),
    ]

    for (options, display) in cases {
      #expect(try format("1234.50 USD", options) == display)
    }
    #expect(try format("5000000 INR", DisplayOptions(groupsInLakhs: true)) == "₹50,00,000.00")
  }

  @Test
  func clampsDecimalsToThePrecisionASheetHas() throws {
    let fifteen = try format("1/3", DisplayOptions(numbers: .fixedDecimals(15)))
    #expect(fifteen == "0.333333333333333")
    #expect(try format("1/3", DisplayOptions(numbers: .fixedDecimals(99))) == fifteen)
    #expect(try format("1/3", DisplayOptions(numbers: .fixedDecimals(-1))) == "0")
  }

  /// Scientific answers are re-enterable: the grammar reads `1.2e6` back as the
  /// number that produced it.
  @Test
  func writesPowersOfTenTheGrammarReads() throws {
    let written = try format("1200000", DisplayOptions(numbers: .scientific))
    #expect(written == "1.2e6")
    #expect(try format(written, .standard) == "1,200,000")
  }

  /// German groups with points and separates decimals with a comma, so the
  /// mantissa of a power of ten follows the locale too.
  @Test
  func followsTheLocaleThatWritesTheDigits() throws {
    let german = try context(localeIdentifier: "de-DE")
    let formatter = ResultFormatter(
      context: german,
      display: DisplayOptions(numbers: .scientific)
    )
    guard case .value(let value) = CalculationEngine().evaluate("1234.5", context: try context())
    else {
      Issue.record("Expected a value for 1234.5")
      return
    }
    #expect(try formatter.format(value).display == "1,2345e3")
  }

  private func format(_ source: String, _ options: DisplayOptions) throws -> String {
    let evaluationContext = try context()
    guard
      case .value(let value) = CalculationEngine().evaluate(source, context: evaluationContext)
    else {
      Issue.record("Expected a value for \(source)")
      return ""
    }
    return try ResultFormatter(context: evaluationContext, display: options).format(value).display
  }

  private func context(localeIdentifier: String = "en-US") throws -> EvaluationContext {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return try EvaluationContext(
      localeIdentifier: localeIdentifier,
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }
}
