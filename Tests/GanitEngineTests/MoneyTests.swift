import Foundation
import Testing

@testable import GanitEngine

@Suite
struct MoneyTests {
  @Test
  func parsesCodesAndUnambiguousSymbols() throws {
    #expect(try same(evaluate("12.50 EUR"), money("12.50", "EUR")))
    #expect(try same(evaluate("€12.50"), money("12.50", "EUR")))
    #expect(try same(evaluate("US$5"), money("5", "USD")))
    #expect(try same(evaluate("-£3"), money("-3", "GBP")))
    #expect(try same(evaluate("₹(2 + 3)"), money("5", "INR")))
    #expect(try same(evaluate("$5"), money("5", "USD")))
    #expect(try same(evaluate("¥5"), money("5", "JPY")))
    #expect(try same(evaluate("USD 1.5"), money("1.5", "USD")))
    #expect(try same(evaluate("5 dollars"), money("5", "USD")))
    #expect(CurrencyCatalog.minorUnits["JPY"] == 0)
    #expect(CurrencyCatalog.minorUnits["KWD"] == 3)
    #expect(CurrencyCatalog.minorUnits["XAU"] == nil)
    let catalog = try UnitCatalog.minimal()
    #expect(CurrencyCatalog.minorUnits.keys.allSatisfy { catalog.resolveUnit(matching: $0) == nil })
  }

  @Test
  func keepsAmountsExactAndCurrenciesSeparate() throws {
    #expect(try same(evaluate("10 EUR + 2.50 EUR"), money("12.50", "EUR")))
    #expect(try same(evaluate("10 EUR / 4"), money("2.5", "EUR")))
    #expect(try same(evaluate("3 * 0.10 EUR"), money("0.30", "EUR")))
    #expect(try same(evaluate("10 EUR / 4 EUR"), .number(exact("2.5"))))
    #expect(try same(evaluate("20% of 50 EUR"), money("10", "EUR")))
    #expect(try same(evaluate("50 EUR + 10%"), money("55", "EUR")))
    #expect(try same(evaluate("50 EUR - 10% off 20 EUR"), money("32", "EUR")))
    #expect(try same(evaluate("1 USD - 0.1 USD - 0.2 USD"), money("0.7", "USD")))
    #expect(try error("10 EUR + 1 USD").code == .currencyRatesUnavailable)
    #expect(try error("10 EUR + 5").code == .typeMismatch)
    #expect(try error("10 EUR * 2 EUR").code == .typeMismatch)
    #expect(try error("10 EUR ^ 2").code == .typeMismatch)
  }

  @Test
  func pricesAQuantityPerUnit() throws {
    guard case .money(let price) = try evaluate("$0.15/kWh") else {
      Issue.record("Expected a price per kWh")
      return
    }
    #expect(price.unit?.symbol == "kWh")
    #expect(try same(evaluate("$30 / 2 kWh * 1 kWh"), money("15", "USD")))
    #expect(try same(evaluate("0.15 USD/kWh * 45 kWh"), money("6.75", "USD")))
    #expect(try same(evaluate("1500 W * 3 h * 30 * 0.15 USD/kWh"), money("20.25", "USD")))
    #expect(try same(evaluate("$0.15/kWh * 2 MWh"), money("300", "USD")))
    #expect(try error("$0.15/kWh + $1").code == .typeMismatch)
    #expect(try error("$0.15/kWh * 3 m").code == .incompatibleDimensions)
  }

  @Test
  func convertsExactlyThroughEuroReferenceRates() throws {
    let rates = try reference(["USD": "1.1551", "JPY": "178.52"])
    #expect(try same(evaluate("100 EUR in USD", rates: rates), money("115.51", "USD")))
    #expect(try same(evaluate("115.51 USD to EUR", rates: rates), money("100", "EUR")))
    #expect(try same(evaluate("11551 USD in JPY", rates: rates), money("1785200", "JPY")))
    #expect(try same(evaluate("5 EUR in EUR", rates: rates), money("5", "EUR")))
    #expect(try error("100 USD in INR", rates: rates).code == .missingCurrencyRate)
    #expect(try error("100 USD in INR").code == .currencyRatesUnavailable)
    #expect(try error("100 in USD", rates: rates).code == .typeMismatch)
    // A second currency adds in the first, at the same rates.
    #expect(try same(evaluate("100 EUR + 115.51 USD", rates: rates), money("200", "EUR")))
    #expect(try same(evaluate("$115.51 - €100 in EUR", rates: rates), money("0", "EUR")))
    #expect(try same(evaluate("$10 in EUR", rates: rates), evaluate("10 USD in EUR", rates: rates)))
    let inrRates = try reference(["USD": "1.2", "INR": "100"])
    #expect(
      try same(
        evaluate("$1.1m to INR", rates: inrRates), evaluate("1100000 USD to INR", rates: inrRates)))
    #expect(
      try same(
        evaluate("usd 1.1mn to inr", rates: inrRates), evaluate("$1.1m to INR", rates: inrRates)))
    #expect(throws: EngineError(code: .invalidCurrencyRate)) {
      try reference(["USD": "1.2.3"])
    }
  }

  @Test
  func declaresManualRatesThatOverrideReferenceRates() throws {
    let rates = try reference(["USD": "1.1551", "INR": "101.8120"])
    var calculator = SheetCalculator()
    let results = try calculator.evaluate(
      SheetSource("1 USD = 83.25 INR\n100 USD in INR\n8325 INR in USD\n---\n100 USD in INR"),
      context: context(rates)
    ).lines.map(\.result)
    #expect(try same(results[0], money("83.25", "INR")))
    #expect(try same(results[1], money("8325", "INR")))
    #expect(try same(results[2], money("100", "USD")))
    let symbols = try calculator.evaluate(
      SheetSource("1 USD = 83.25 INR\n$1 + ₹83.25"), context: context(rates)
    ).lines.map(\.result)
    #expect(try same(symbols[1], money("2", "USD")))
    // A divider ends the manual rate, so reference rates apply again.
    #expect(try !same(results[4], money("8325", "INR")))

    for source in ["1 USD = 5", "1 USD = 2 USD", "1 USD = -2 INR", "1 USD = 0 INR"] {
      #expect(
        try sheetOutcomes(source)[0] == "error.evaluation.invalidCurrencyRate", "\(source)")
    }
    #expect(try sheetOutcomes("USD = 1")[0] == "syntax.invalidVariableName")
  }

  @Test
  func recordsWhichKindsOfRateEachLineUsed() throws {
    var calculator = SheetCalculator()
    let lines = try calculator.evaluate(
      SheetSource(
        "1 USD = 83 INR\n1 EUR in USD\n1 USD in JPY\n1 USD in INR + 1 INR\n1 USD in USD\n2 USD"),
      context: context(reference(["USD": "1.1551", "JPY": "178.52"]))
    ).lines
    #expect(lines.map(\.rateUses) == [[], [.reference], [.crossReference], [.manual], [], []])
  }

  @Test
  func reevaluatesOnlyConversionsThatUseAnEditedRate() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("1 USD = 83 INR\n100 USD in INR\n2 EUR + 1 EUR\n5 USD")
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    sheet.replace(utf8Range: 8..<10, with: "84")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(evaluation.evaluatedLineIDs == [0, 1, 3].map { sheet.lines[$0].id })
  }

  /// Whether two values are the same kind and numerically equal.
  private func same(_ value: EngineValue, _ expected: EngineValue) throws -> Bool {
    let operations = NumericOperations(context: try sheetContext(), limits: .default)
    switch (value, expected) {
    case (.money(let lhs), .money(let rhs)):
      return try lhs.currency == rhs.currency && lhs.unit == rhs.unit
        && operations.applying(.subtract, left: lhs.amount, right: rhs.amount).isZero
    case (.number(let lhs), .number(let rhs)):
      return try operations.applying(.subtract, left: lhs, right: rhs).isZero
    default:
      return false
    }
  }

  private func same(_ result: CalculationResult?, _ expected: EngineValue) throws -> Bool {
    guard case .value(let value) = result else {
      return false
    }
    return try same(value, expected)
  }

  private func reference(_ unitsPerEuro: [String: String]) throws -> CurrencyRates {
    try CurrencyRates(
      unitsPerEuro: unitsPerEuro, observationDate: "1970-01-01",
      retrievedAt: Date(timeIntervalSince1970: 0))
  }

  private func money(_ amount: String, _ currency: String) throws -> EngineValue {
    .money(MoneyValue(amount: try exact(amount), currency: currency))
  }

  private func exact(_ text: String) throws -> NumericValue {
    let parsing = Parser(source: text.hasPrefix("-") ? "(\(text))" : text).parse()
    return try requireNumber(
      try Evaluator(context: sheetContext()).evaluate(#require(parsing.expression)))
  }

  private func requireNumber(_ value: EngineValue) throws -> NumericValue {
    guard case .number(let number) = value else {
      throw EngineError(code: .typeMismatch)
    }
    return number
  }

  private func evaluate(_ source: String, rates: CurrencyRates = .none) throws -> EngineValue {
    let parsing = Parser(source: source).parse()
    #expect(parsing.diagnostics.isEmpty, "\(source)")
    return try Evaluator(context: context(rates)).evaluate(try #require(parsing.expression))
  }

  private func error(_ source: String, rates: CurrencyRates = .none) throws -> EngineError {
    do {
      let value = try evaluate(source, rates: rates)
      Issue.record("Expected an error for \(source), got \(value)")
      throw EngineError(code: .invalidDomain)
    } catch let error as EngineError {
      return error
    }
  }

  private func context(_ rates: CurrencyRates) throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0),
      calendar: Calendar(identifier: .gregorian),
      timeZone: try #require(TimeZone(identifier: "UTC")),
      currencyRates: rates
    )
  }
}
