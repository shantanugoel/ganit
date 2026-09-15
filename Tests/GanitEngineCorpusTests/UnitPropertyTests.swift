import Foundation
import Testing

@testable import GanitEngine

@Suite
struct UnitPropertyTests {
  /// Exact units grouped by dimension. Every family has a distinct dimension.
  private static let families: [String: [String]] = [
    "length": ["m", "km", "mm", "in", "ft", "yd", "mi"],
    "area": ["m^2", "cm²", "ha", "ac", "ft²"],
    "mass": ["kg", "g", "mg", "t", "lb", "st"],
    "time": ["s", "ms", "min", "h"],
    "volume": [
      "L", "l", "mL", "ml", "m^3", "cm³", "gal", "qt", "pt", "cup", "floz", "tbsp", "tsp",
    ],
    "data": ["bit", "B", "kB", "KiB", "Mb", "MiB"],
    "speed": ["m/s", "km/h", "mi/h", "ft/min"],
    "acceleration": ["m/s²", "ft/s^2", "km/(h·s)"],
    "force": ["N", "kN", "kg·m/s²", "g·cm/s^2"],
    "pressure": ["Pa", "kPa", "N/m²", "mbar", "bar", "atm", "psi"],
    "energy": ["J", "kJ", "W·h", "Wh", "kWh", "cal", "kcal", "N·m", "kg·m²/s²"],
    "power": ["W", "kW", "J/s", "MJ/h"],
    "data rate": ["bit/s", "MB/s", "Mb/s", "KiB/min"],
  ]

  private let engine = CalculationEngine()

  @Test
  func ratioConversionsRoundTripAndComposeExactly() throws {
    let context = try fixedContext()
    var generator = SeededGenerator(seed: 0x554E_4954_5201)

    for (family, units) in Self.families.sorted(by: { $0.key < $1.key }) {
      for _ in 0..<40 {
        let magnitude = randomMagnitude(&generator)
        let source = pick(units, &generator)
        let middle = pick(units, &generator)
        let target = pick(units, &generator)
        let original = try quantity("\(magnitude) \(source)", context)

        #expect(
          try same(quantity("\(magnitude) \(source) in \(middle) in \(source)", context), original),
          "\(family) round trip: \(magnitude) \(source) via \(middle)"
        )
        #expect(
          try same(
            quantity("\(magnitude) \(source) in \(middle) in \(target)", context),
            quantity("\(magnitude) \(source) in \(target)", context)),
          "\(family) composition: \(source) → \(middle) → \(target)"
        )
      }
    }
  }

  @Test
  func additionIsDimensionallyCommutativeAndInvertible() throws {
    let context = try fixedContext()
    var generator = SeededGenerator(seed: 0x554E_4954_4101)

    for (family, units) in Self.families.sorted(by: { $0.key < $1.key }) {
      for _ in 0..<25 {
        let a = "\(randomMagnitude(&generator)) \(pick(units, &generator))"
        let b = "\(randomMagnitude(&generator)) \(pick(units, &generator))"
        let target = pick(units, &generator)

        #expect(
          try same(
            quantity("(\(a) + \(b)) in \(target)", context),
            quantity("(\(b) + \(a)) in \(target)", context)),
          "\(family) commutativity: \(a) + \(b)"
        )
        #expect(
          try same(quantity("(\(a) + \(b)) - \(b)", context), quantity(a, context)),
          "\(family) inverse: \(a) + \(b) - \(b)"
        )
      }
    }
  }

  @Test
  func productsAndPowersPreserveCompoundUnitsThroughConversion() throws {
    let context = try fixedContext()
    var generator = SeededGenerator(seed: 0x554E_4954_5801)
    let names = Self.families.keys.sorted()

    for _ in 0..<200 {
      let leftUnits = try #require(Self.families[pick(names, &generator)])
      let rightUnits = try #require(Self.families[pick(names, &generator)])
      let leftUnit = pick(leftUnits, &generator)
      let rightUnit = pick(rightUnits, &generator)
      let leftTarget = pick(leftUnits, &generator)
      let rightTarget = pick(rightUnits, &generator)
      let a = "\(randomMagnitude(&generator)) \(leftUnit)"
      let b = "\(randomMagnitude(&generator)) \(rightUnit)"

      #expect(
        try same(
          quantity("(\(a)) * (\(b)) / (\(b)) in \(leftTarget)", context),
          quantity("\(a) in \(leftTarget)", context)),
        "cancellation: \(a) * \(b) / \(b)"
      )
      #expect(
        try same(
          quantity(
            "(\(a)) * (\(b)) in (\(leftTarget))·(\(rightTarget))",
            context
          ),
          quantity(
            "(\(a) in \(leftTarget)) * (\(b) in \(rightTarget))",
            context
          )),
        "product conversion: \(a) * \(b)"
      )
      #expect(
        try same(
          quantity("(\(a))^2 in (\(leftTarget))^2", context),
          quantity("(\(a) in \(leftTarget))^2", context)),
        "power conversion: (\(a))^2"
      )
    }
  }

  @Test
  func incompatibleDimensionsFailForEveryFamilyPair() throws {
    let context = try fixedContext()
    let samples = Self.families.sorted(by: { $0.key < $1.key })
      .map { ($0.key, $0.value[$0.value.count - 1]) }

    for (leftFamily, leftUnit) in samples {
      for (rightFamily, rightUnit) in samples where leftFamily != rightFamily {
        for source in [
          "1 \(leftUnit) + 1 \(rightUnit)",
          "1 \(leftUnit) - 1 \(rightUnit)",
          "1 \(leftUnit) in \(rightUnit)",
        ] {
          guard
            case .evaluationFailure(let error) = engine.evaluate(
              source,
              context: context
            )
          else {
            Issue.record("Expected dimension failure for \(source)")
            continue
          }
          #expect(error.code == .incompatibleDimensions, "\(source)")
        }
      }
    }
  }

  @Test
  func affineTemperaturesRoundTripExactly() throws {
    let context = try fixedContext()
    var generator = SeededGenerator(seed: 0x554E_4954_5401)
    let units = ["°C", "°F", "K", "mK"]

    for _ in 0..<100 {
      let magnitude = randomMagnitude(&generator)
      let source = pick(units, &generator)
      let middle = pick(units, &generator)
      let target = pick(units, &generator)

      #expect(
        try same(
          quantity("\(magnitude) \(source) in \(middle) in \(source)", context),
          quantity("\(magnitude) \(source)", context)),
        "temperature round trip: \(magnitude) \(source) via \(middle)"
      )
      #expect(
        try same(
          quantity("\(magnitude) \(source) in \(middle) in \(target)", context),
          quantity("\(magnitude) \(source) in \(target)", context)),
        "temperature composition: \(source) → \(middle) → \(target)"
      )
    }
  }

  private func same(
    _ lhs: QuantityValue,
    _ rhs: QuantityValue
  ) throws -> Bool {
    guard lhs.unit == rhs.unit, lhs.kind == rhs.kind else {
      return false
    }
    let operations = NumericOperations(
      context: try fixedContext(),
      limits: .default
    )
    switch try operations.applying(
      .subtract,
      left: lhs.magnitude,
      right: rhs.magnitude
    ) {
    case .integer(let difference):
      return difference.isZero
    case .rational(let difference):
      return difference.numerator.isZero
    case .decimal(let difference):
      return difference.coefficient.isZero
    case .approximate:
      return false
    }
  }

  private func quantity(
    _ source: String,
    _ context: EvaluationContext
  ) throws -> QuantityValue {
    guard
      case .value(.quantity(let quantity)) = engine.evaluate(
        source,
        context: context
      )
    else {
      Issue.record("Expected quantity for \(source)")
      throw CorpusFailure.expectedValue
    }
    return quantity
  }
}

/// Produces signed integer, decimal, or grouped rational magnitudes.
private func randomMagnitude(_ generator: inout SeededGenerator) -> String {
  let numerator = generator.integer(in: -9_999...9_999)
  switch generator.integer(in: 0...2) {
  case 0:
    return "(\(numerator))"
  case 1:
    return "(\(numerator).\(generator.integer(in: 0...999)))"
  default:
    return "(\(numerator)/\(generator.integer(in: 1...97)))"
  }
}

private func pick<Element>(
  _ elements: [Element],
  _ generator: inout SeededGenerator
) -> Element {
  elements[generator.integer(in: 0...(elements.count - 1))]
}
