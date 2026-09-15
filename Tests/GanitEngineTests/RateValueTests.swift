import Foundation
import Testing

@testable import GanitEngine

@Suite
struct RateValueTests {
  @Test
  func convertsFixedAndCalendarRateDenominatorsExactly() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let hour = try unit("h", catalog: catalog, algebra: algebra)
    let minute = try unit("min", catalog: catalog, algebra: algebra)
    let hourly = try RateValue(
      amount: .number(integer(60)),
      denominator: .unit(hour)
    )
    let yearly = try RateValue(
      amount: .percentage(
        PercentageValue(points: integer(6))
      ),
      denominator: .calendar(.year)
    )

    #expect(
      try algebra.converted(hourly, to: .unit(minute)).amount
        == .number(integer(1))
    )
    #expect(
      try algebra.converted(yearly, to: .calendar(.month)).amount
        == .percentage(
          PercentageValue(points: try fraction(1, 2))
        )
    )
  }

  @Test
  func appliesDimensionedRatesToCompatibleQuantities() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let second = try unit("s", catalog: catalog, algebra: algebra)
    let byteDefinition = try definition("B", catalog: catalog)
    let mega = try #require(catalog.prefix(matching: "M")?.prefix)
    let megabyte = try algebra.unit(
      algebra.applying(mega, to: byteDefinition)
    )
    let dataRate = try algebra.divided(megabyte, by: second)
    let throughput = QuantityValue(
      magnitude: integer(75),
      unit: dataRate
    )

    #expect(
      try algebra.multiplying(
        throughput,
        QuantityValue(magnitude: integer(2), unit: second)
      )
        == QuantityValue(magnitude: integer(150), unit: megabyte)
    )
  }

  @Test
  func rejectsDimensionAndPeriodMismatches() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let second = try unit("s", catalog: catalog, algebra: algebra)
    let meter = try unit("m", catalog: catalog, algebra: algebra)
    let rate = try RateValue(
      amount: .number(integer(1)),
      denominator: .unit(second)
    )

    #expect(throws: EngineError.self) {
      try algebra.applying(
        rate,
        to: QuantityValue(magnitude: integer(1), unit: meter)
      )
    }
    #expect(throws: EngineError.self) {
      try algebra.converted(rate, to: .calendar(.year))
    }
    #expect(throws: EngineError.self) {
      try algebra.applying(rate, toPeriodCount: integer(2))
    }

    let annual = try RateValue(
      amount: .percentage(PercentageValue(points: integer(6))),
      denominator: .calendar(.year)
    )
    #expect(
      try algebra.applying(annual, toPeriodCount: integer(2))
        == .percentage(PercentageValue(points: integer(12)))
    )
  }

  @Test
  func rejectsAffineDenominators() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let celsius = try unit("°C", catalog: catalog, algebra: algebra)

    #expect(throws: EngineError.self) {
      try RateValue(
        amount: .number(integer(1)),
        denominator: .unit(celsius)
      )
    }
  }

  private func unit(
    _ alias: String,
    catalog: UnitCatalog,
    algebra: UnitAlgebra
  ) throws -> UnitExpression {
    try algebra.unit(try definition(alias, catalog: catalog))
  }

  private func definition(
    _ alias: String,
    catalog: UnitCatalog
  ) throws -> UnitDefinition {
    try #require(catalog.unit(matching: alias)?.definition)
  }

  private func integer(_ value: Int) -> NumericValue {
    .integer(IntegerValue(value))
  }

  private func fraction(
    _ numerator: Int,
    _ denominator: Int
  ) throws -> NumericValue {
    .rational(
      try RationalValue(
        numerator: IntegerValue(numerator),
        denominator: IntegerValue(denominator)
      )
    )
  }

  private func unitAlgebra() throws -> UnitAlgebra {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return UnitAlgebra(
      context: try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: try PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 1_700_000_000),
        calendar: Calendar(identifier: .gregorian),
        timeZone: timeZone
      )
    )
  }
}
