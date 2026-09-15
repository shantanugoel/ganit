import Foundation
import Testing

@testable import GanitEngine

@Suite
struct UnitAlgebraTests {
  @Test
  func derivesNamedAndCompoundDimensions() throws {
    #expect(try Dimension.length.multiplied(by: .length) == .area)
    #expect(try Dimension.area.multiplied(by: .length) == .volume)
    #expect(
      try Dimension.length.divided(by: .time) == .speed
    )
    #expect(try Dimension.speed.divided(by: .time) == .acceleration)
    #expect(try Dimension.mass.multiplied(by: .acceleration) == .force)
    #expect(
      try Dimension.force.divided(by: .area) == .pressure
    )
    #expect(
      try Dimension.energy.divided(by: .time) == .power
    )
    #expect(try Dimension.force.multiplied(by: .length) == .energy)
    #expect(
      try Dimension.data.divided(by: .time) == .dataRate
    )
  }

  @Test
  func composesAndCancelsRatioUnits() throws {
    let algebra = try unitAlgebra()
    let meter = try algebra.unit(Self.meter)
    let second = try algebra.unit(Self.second)
    let speed = try algebra.divided(meter, by: second)
    let acceleration = try algebra.divided(speed, by: second)
    let cancelled = try algebra.divided(meter, by: meter)

    #expect(speed.dimension == .speed)
    #expect(speed.symbol == "m/s")
    #expect(acceleration.dimension == .acceleration)
    #expect(acceleration.symbol == "m/s^2")
    #expect(cancelled.dimension == .dimensionless)
    #expect(cancelled.symbol == "1")
  }

  @Test
  func appliesExactPrefixesAndRatioConversions() throws {
    let algebra = try unitAlgebra()
    let kilometerDefinition = try algebra.applying(
      Self.kilo,
      to: Self.meter
    )
    let kilometer = try algebra.unit(kilometerDefinition)
    let meter = try algebra.unit(Self.meter)
    let foot = try algebra.unit(Self.foot)

    let inMeters = try algebra.converted(
      QuantityValue(magnitude: integer(2), unit: kilometer),
      to: meter
    )
    let inFeet = try algebra.converted(
      QuantityValue(magnitude: integer(381), unit: meter),
      to: foot
    )

    #expect(kilometer.symbol == "km")
    #expect(inMeters.magnitude == integer(2_000))
    #expect(inFeet.magnitude == integer(1_250))
    #expect(
      try algebra.converted(inFeet, to: meter).magnitude == integer(381)
    )

    let kibibyte = try algebra.unit(
      algebra.applying(Self.kibi, to: Self.byte)
    )
    let byte = try algebra.unit(Self.byte)
    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(2), unit: kibibyte),
        to: byte
      ).magnitude == integer(2_048)
    )
  }

  @Test
  func multipliesQuantitiesAndRejectsIncompatibleAddition() throws {
    let algebra = try unitAlgebra()
    let meter = try algebra.unit(Self.meter)
    let second = try algebra.unit(Self.second)
    let area = try algebra.multiplying(
      QuantityValue(magnitude: integer(6), unit: meter),
      QuantityValue(magnitude: integer(4), unit: meter)
    )

    #expect(area.magnitude == integer(24))
    #expect(area.unit.dimension == .area)
    #expect(area.unit.symbol == "m^2")

    let foot = try algebra.unit(Self.foot)
    let sum = try algebra.adding(
      QuantityValue(magnitude: integer(1), unit: meter),
      QuantityValue(magnitude: integer(1), unit: foot)
    )
    #expect(
      sum.magnitude
        == .rational(
          try RationalValue(
            numerator: IntegerValue(1_631),
            denominator: IntegerValue(1_250)
          )
        )
    )

    do {
      _ = try algebra.adding(
        QuantityValue(magnitude: integer(1), unit: meter),
        QuantityValue(magnitude: integer(1), unit: second)
      )
      Issue.record("Expected incompatible dimensions")
    } catch let error as EngineError {
      #expect(error.code == .incompatibleDimensions)
    }

    do {
      _ = try algebra.converted(
        QuantityValue(magnitude: integer(1), unit: meter),
        to: second
      )
      Issue.record("Expected incompatible dimensions")
    } catch let error as EngineError {
      #expect(error.code == .incompatibleDimensions)
      #expect(
        error.context
          == .dimensionMismatch(expected: .time, actual: .length)
      )
    }
  }

  @Test
  func keepsAffineConversionsSeparateFromCompoundAlgebra() throws {
    let algebra = try unitAlgebra()
    let celsius = try algebra.unit(Self.celsius)
    let fahrenheit = try algebra.unit(Self.fahrenheit)
    let kelvin = try algebra.unit(Self.kelvin)
    let meter = try algebra.unit(Self.meter)

    let freezing = try algebra.converted(
      QuantityValue(magnitude: integer(0), unit: celsius),
      to: fahrenheit
    )
    let boiling = try algebra.converted(
      QuantityValue(magnitude: integer(100), unit: celsius),
      to: fahrenheit
    )

    #expect(freezing.magnitude == integer(32))
    #expect(boiling.magnitude == integer(212))
    #expect(
      try algebra.converted(freezing, to: celsius).magnitude == integer(0)
    )
    #expect(throws: EngineError.self) {
      try algebra.multiplied(celsius, by: meter)
    }
    #expect(throws: EngineError.self) {
      try algebra.adding(
        QuantityValue(magnitude: integer(20), unit: celsius),
        QuantityValue(magnitude: integer(10), unit: celsius)
      )
    }
    #expect(throws: EngineError.self) {
      try algebra.subtracting(
        QuantityValue(magnitude: integer(20), unit: celsius),
        QuantityValue(magnitude: integer(10), unit: celsius)
      )
    }

    let absoluteKelvin = try algebra.converted(
      QuantityValue(magnitude: integer(0), unit: celsius),
      to: kelvin
    )
    #expect(absoluteKelvin.kind == .absolute)
    #expect(throws: EngineError.self) {
      try algebra.multiplying(
        absoluteKelvin,
        QuantityValue(magnitude: integer(1), unit: meter)
      )
    }
    #expect(throws: EngineError.self) {
      try algebra.dividing(
        QuantityValue(magnitude: integer(1), unit: meter),
        QuantityValue(magnitude: integer(0), unit: celsius)
      )
    }

    let fahrenheitDifference = try algebra.converted(
      QuantityValue(
        magnitude: integer(10),
        unit: celsius,
        kind: .relative
      ),
      to: fahrenheit
    )
    #expect(fahrenheitDifference.magnitude == integer(18))
    #expect(fahrenheitDifference.kind == .relative)

    let summedDifference = try algebra.adding(
      QuantityValue(
        magnitude: integer(10),
        unit: celsius,
        kind: .relative
      ),
      QuantityValue(
        magnitude: integer(5),
        unit: celsius,
        kind: .relative
      )
    )
    #expect(summedDifference.kind == .relative)
    #expect(
      try algebra.converted(summedDifference, to: fahrenheit).magnitude
        == integer(27)
    )
  }

  @Test
  func rendersUnambiguousEngineeringCompounds() throws {
    let algebra = try unitAlgebra()
    let meter = try algebra.unit(Self.meter)
    let second = try algebra.unit(Self.second)
    let kilogram = try algebra.unit(Self.kilogram)
    let denominator = try algebra.multiplied(kilogram, by: second)
    let compound = try algebra.divided(meter, by: denominator)
    let force = try algebra.divided(
      try algebra.multiplied(kilogram, by: meter),
      by: try algebra.raised(second, to: 2)
    )

    #expect(compound.symbol == "m/(kg·s)")
    #expect(force.symbol == "kg·m/s^2")
    #expect(force.dimension == .force)
  }

  @Test
  func boundsDimensionExponentGrowth() throws {
    #expect(throws: EngineError.self) {
      try Dimension.length.raised(
        to: Dimension.maximumExponentMagnitude + 1
      )
    }
    let algebra = try unitAlgebra()
    #expect(throws: EngineError.self) {
      try algebra.raised(
        algebra.unit(Self.meter),
        to: Dimension.maximumExponentMagnitude + 1
      )
    }
  }

  @Test
  func boundsCompoundFactorAndDefinitionGrowth() throws {
    let algebra = try unitAlgebra()
    var compound = try algebra.unit(
      dimensionlessUnit(identifier: "unit0")
    )
    for index in 1..<RatioUnit.maximumFactorCount {
      compound = try algebra.multiplied(
        compound,
        by: algebra.unit(dimensionlessUnit(identifier: "unit\(index)"))
      )
    }
    #expect(throws: EngineError.self) {
      try algebra.multiplied(
        compound,
        by: algebra.unit(
          dimensionlessUnit(
            identifier: "unit\(RatioUnit.maximumFactorCount)"
          )
        )
      )
    }
    #expect(throws: EngineError.self) {
      try UnitDefinition(
        canonicalIdentifier: String(
          repeating: "x",
          count: UnitDefinition.maximumIdentifierLength + 1
        ),
        symbol: "x",
        dimension: .dimensionless,
        transform: .ratio(scale: integer(1))
      )
    }
    #expect(throws: EngineError.self) {
      try UnitDefinition(
        canonicalIdentifier:
          "a" + String(repeating: "\u{0301}", count: 128),
        symbol: "x",
        dimension: .dimensionless,
        transform: .ratio(scale: integer(1))
      )
    }
  }

  @Test
  func rejectsNonpositiveScalesAndPrefixes() {
    #expect(throws: EngineError.self) {
      try UnitDefinition(
        canonicalIdentifier: "invalid",
        symbol: "x",
        dimension: .length,
        transform: .ratio(scale: integer(0))
      )
    }
    #expect(throws: EngineError.self) {
      try UnitPrefix(
        canonicalIdentifier: "invalid",
        symbol: "x",
        scale: integer(-1),
        family: .decimal
      )
    }
  }

  private static let meter = try! UnitDefinition(
    canonicalIdentifier: "meter",
    symbol: "m",
    dimension: .length,
    transform: .ratio(scale: integer(1)),
    allowedPrefixFamilies: [.decimal]
  )

  private static let foot = try! UnitDefinition(
    canonicalIdentifier: "foot",
    symbol: "ft",
    dimension: .length,
    transform: .ratio(
      scale: .rational(
        try! RationalValue(
          numerator: IntegerValue(381),
          denominator: IntegerValue(1_250)
        )
      )
    )
  )

  private static let second = try! UnitDefinition(
    canonicalIdentifier: "second",
    symbol: "s",
    dimension: .time,
    transform: .ratio(scale: integer(1)),
    allowedPrefixFamilies: [.decimal]
  )

  private static let kilogram = try! UnitDefinition(
    canonicalIdentifier: "kilogram",
    symbol: "kg",
    dimension: .mass,
    transform: .ratio(scale: integer(1))
  )

  private static let byte = try! UnitDefinition(
    canonicalIdentifier: "byte",
    symbol: "B",
    dimension: .data,
    transform: .ratio(scale: integer(1)),
    allowedPrefixFamilies: [.decimal, .binary]
  )

  private static let celsius = try! UnitDefinition(
    canonicalIdentifier: "degree-celsius",
    symbol: "°C",
    dimension: .temperature,
    transform: .affine(
      scale: integer(1),
      offset: .decimal(
        try! DecimalValue(coefficient: IntegerValue(27_315), scale: 2)
      )
    )
  )

  private static let fahrenheit = try! UnitDefinition(
    canonicalIdentifier: "degree-fahrenheit",
    symbol: "°F",
    dimension: .temperature,
    transform: .affine(
      scale: .rational(
        try! RationalValue(
          numerator: IntegerValue(5),
          denominator: IntegerValue(9)
        )
      ),
      offset: .rational(
        try! RationalValue(
          numerator: IntegerValue(45_967),
          denominator: IntegerValue(180)
        )
      )
    )
  )

  private static let kelvin = try! UnitDefinition(
    canonicalIdentifier: "kelvin",
    symbol: "K",
    dimension: .temperature,
    transform: .ratio(scale: integer(1))
  )

  private static let kilo = try! UnitPrefix(
    canonicalIdentifier: "kilo",
    symbol: "k",
    scale: integer(1_000),
    family: .decimal
  )

  private static let kibi = try! UnitPrefix(
    canonicalIdentifier: "kibi",
    symbol: "Ki",
    scale: integer(1_024),
    family: .binary
  )

  private static func integer(_ value: Int) -> NumericValue {
    .integer(IntegerValue(value))
  }

  private func integer(_ value: Int) -> NumericValue {
    Self.integer(value)
  }

  private func dimensionlessUnit(
    identifier: String
  ) throws -> UnitDefinition {
    try UnitDefinition(
      canonicalIdentifier: identifier,
      symbol: identifier,
      dimension: .dimensionless,
      transform: .ratio(scale: integer(1))
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
