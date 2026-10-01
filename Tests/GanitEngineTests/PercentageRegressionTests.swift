import Testing

@testable import GanitEngine

@Suite
struct PercentageRegressionTests {
  @Test
  func seededScalingMatchesIndependentIntegerArithmetic() throws {
    var generator = SeededGenerator(seed: 0x5045_5243_454E_5401)
    for _ in 0..<500 {
      let points = generator.next(below: 401) - 200
      let factor = generator.next(below: 41) - 20
      let adjustment = generator.next(below: 101) - 50
      let product = points * factor
      try expectEquivalent("(\(points))% * (\(factor))", "(\(product))%")
      try expectEquivalent(
        "((\(points))% * (\(factor))) + (\(adjustment))%", "(\(product + adjustment))%")
      try expectEquivalent(
        "((\(points))% * (\(factor))) - (\(adjustment))%", "(\(product - adjustment))%")
      try expectEquivalent("(\(factor)) * (\(points))%", "(\(product)) / 100")
      try expectEquivalent("(\(points))% of (\(factor))", "(\(product)) / 100")
      try expectEquivalent(
        "(\(points))% * (\(adjustment))%", "(\(points * adjustment)) / 10000")
      if factor != 0 {
        try expectEquivalent("((\(points))% / (\(factor))) * (\(factor))", "(\(points))%")
        try expectEquivalent("((\(points))% * (\(factor))) / (\(factor))", "(\(points))%")
      }
    }
  }

  @Test
  func composesWithMoneyUnitsStatisticsAndFinance() throws {
    let cases = [
      ("100 USD * (8% * 5)", "40 USD"),
      ("(8% * 5) * 100 USD", "40 USD"),
      ("100 USD / (8% * 5)", "250 USD"),
      ("100 USD + (8% * 5)", "140 USD"),
      ("100 USD - (8% * 5)", "60 USD"),
      ("(8% * 5) of 100 USD", "40 USD"),
      ("200 kg * (8% * 5)", "80 kg"),
      ("200 kg / (8% * 5)", "500 kg"),
      ("200 kg + (8% * 5)", "280 kg"),
      ("200 kg - (8% * 5)", "120 kg"),
      ("(8% * 5) of 200 kg", "80 kg"),
      ("(8% * 5) off 200 kg", "120 kg"),
      ("(8% * 5) on 200 kg", "280 kg"),
      ("(200 kg * (8% * 5)) in g", "80000 g"),
      ("sum(8% * 5, 20%)", "60%"),
      ("avg(8% * 5, 20%)", "30%"),
      ("median(8% * 5, 20%, 30%)", "30%"),
      ("median(8% * 5, 20%)", "30%"),
      ("count(8% * 5, 20%)", "2"),
      ("avg(10%, 20%) * 2", "30%"),
      ("fv(1000, 2% * 5, 2)", "1210"),
      ("pv(1210, 2% * 5, 2)", "1000"),
      ("pmt(1000, 1% * 5, 3)", "pmt(1000, 5%, 3)"),
      ("npv(2% * 5, -1000, 300, 400, 500)", "npv(10%, -1000, 300, 400, 500)"),
      ("fv(1000 USD, 2% * 5, 2)", "1210 USD"),
      ("200 + (8% * 5)", "280"),
      ("200 - (8% * 5)", "120"),
      ("200 / (8% * 5)", "500"),
      ("(8% * 5) / 20%", "2"),
      ("8% * 5 * 2 + 3%", "83%"),
      ("8% * (5 * 2) + 3%", "83%"),
      ("8% * (5 + 3)", "64%"),
      ("8% * 0.25", "2%"),
      ("8% * (1 / 3) * 3", "8%"),
      ("8 percent * 5", "40%"),
      ("8 pct * 5", "40%"),
    ]
    for (source, expected) in cases {
      try expectEquivalent(source, expected)
    }
  }

  @Test
  func carriesPercentagesThroughVariablesReferencesAndCustomFunctions() throws {
    let outcomes = try sheetOutcomes(
      """
      rate = 8%
      scaled = rate * 5
      scaled + 3%
      scaled of 200
      line 2 * 2
      previous + 3%
      @2 / 5
      scale(x) = x * 5
      scale(rate) + 3%
      tax(amount) = amount * scaled
      tax(200)
      """
    )
    #expect(outcomes == ["8%", "40%", "43%", "80", "80%", "83%", "8%", nil, "43%", nil, "80"])
  }

  @Test
  func keepsInvalidOperationsAndZeroDivisorsRanged() throws {
    let engine = CalculationEngine()
    let cases: [(String, EngineErrorCode)] = [
      ("(8% * 5) + 2", .typeMismatch),
      ("(8% * 5) - 2", .typeMismatch),
      ("(8% * 5) ^ 2", .typeMismatch),
      ("(8% * 5) / 0", .divisionByZero),
      ("200 / (8% * 0)", .divisionByZero),
      ("200 USD / (8% * 0)", .divisionByZero),
      ("200 kg / (8% * 0)", .divisionByZero),
      ("20 °C * (8% * 5)", .invalidAbsoluteQuantityOperation),
      ("(8% * 5) of 20 °C", .invalidAbsoluteQuantityOperation),
      ("sum(8% * 5, 2)", .typeMismatch),
    ]
    for (source, code) in cases {
      guard
        case .evaluationFailure(let error) = engine.evaluate(source, context: try sheetContext())
      else {
        Issue.record("Expected \(code) for \(source)")
        continue
      }
      #expect(error.code == code, "\(source)")
      #expect(!error.ranges.isEmpty, "\(source)")
      for range in error.ranges {
        #expect(range.lowerBound >= 0 && range.upperBound <= source.utf8.count)
      }
      if source == "(8% * 5) / 0" {
        #expect(error.ranges.first?.lowerBound == 11)
        #expect(error.ranges.first?.upperBound == 12)
      }
    }
    for source in ["(8% * 5)%", "(8% * 5) percent", "(8% * 5) pct"] {
      guard
        case .syntaxFailure(let diagnostics) = engine.evaluate(source, context: try sheetContext())
      else {
        Issue.record("Expected a repeated percentage marker to be rejected: \(source)")
        continue
      }
      #expect(diagnostics.contains { $0.code == .unexpectedToken })
    }
  }

  @Test
  func incrementalRecalculationMatchesAFreshSheet() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("rate = 8%\nscaled = rate * 5\nscaled + 3%\n200 * scaled\n@2 / 5")
    _ = try calculator.evaluate(sheet, context: sheetContext())
    sheet.replace(utf8Range: 7..<8, with: "9")
    let incremental = try calculator.evaluate(sheet, context: sheetContext())
    let fresh = try evaluateSheet(sheet)
    #expect(incremental.lines.map(\.result) == fresh.map(\.result))
    #expect(
      try sheetOutcomes(sheet.text) == ["9%", "45%", "48%", "90", "9%"])
  }

  private func evaluate(_ source: String) throws -> EngineValue {
    let result = CalculationEngine().evaluate(source, context: try sheetContext())
    guard case .value(let value) = result else {
      Issue.record("Expected a value for \(source): \(result)")
      throw EngineError(code: .internalFailure)
    }
    return value
  }

  private func expectEquivalent(_ source: String, _ expected: String) throws {
    let actual = try evaluate(source)
    let target = try evaluate(expected)
    #expect(actual.kind == target.kind, "\(source) has a different type from \(expected)")
    let difference = try evaluate("(\(source)) - (\(expected))")
    switch difference {
    case .number(let number):
      #expect(number.isZero, "\(source) differs from \(expected)")
    case .percentage(let percentage):
      #expect(percentage.points.isZero, "\(source) differs from \(expected)")
    case .money(let money):
      #expect(money.amount.isZero, "\(source) differs from \(expected)")
    case .quantity(let quantity):
      #expect(quantity.magnitude.isZero, "\(source) differs from \(expected)")
    default:
      Issue.record("Cannot compare \(source) and \(expected)")
    }
  }
}
