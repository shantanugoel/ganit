import Foundation
import Testing

@testable import GanitEngine

@Suite
struct QuantitySyntaxTests {
  @Test
  func parsesCatalogUnitsPrefixesAndCompounds() throws {
    for source in [
      "12 km",
      "12km",
      "9.81 m/s^2",
      "75 MB/s",
      "1 kg·m/s²",
      "1 kg×m/s³",
      "1 m/(s^2)",
      "1 (m/s)",
      "1 KiB",
      "0 °C",
    ] {
      let result = Parser(source: source).parse()
      #expect(result.diagnostics.isEmpty, "Failed to parse \(source)")
      guard case .quantity = result.expression else {
        Issue.record("Expected quantity AST for \(source)")
        continue
      }
    }
  }

  @Test
  func keepsConstantsAndUnitAliasesUnambiguous() throws {
    let pi = try #require(Parser(source: "2pi").parse().expression)
    guard case .infix(_, .multiply, .identifier("pi", _), _, _) = pi else {
      Issue.record("2pi must remain implicit multiplication")
      return
    }

    let inches = try #require(Parser(source: "12 in").parse().expression)
    guard case .quantity(_, .named(let entry, prefix: nil, _), _) = inches else {
      Issue.record("A terminal in alias must mean inches")
      return
    }
    #expect(entry.definition.canonicalIdentifier == "inch")
    #expect(Parser(source: "12 KM").parse().expression == nil)
  }

  @Test
  func givesConversionsLowerPrecedenceThanArithmetic() throws {
    let expression = try #require(
      Parser(source: "1 m + 1 ft in cm").parse().expression
    )
    guard case .conversion(let value, _, _, _) = expression,
      case .infix(_, .add, _, _, _) = value
    else {
      Issue.record("Conversion must wrap the full arithmetic expression")
      return
    }
  }

  @Test
  func reportsIncompleteAndUnknownConversionTargetsPrecisely() {
    for keyword in ["in", "to", "as", "into"] {
      let source = "1 m \(keyword)"
      let result = Parser(source: source).parse()
      #expect(result.expression == nil)
      #expect(result.diagnostics.first?.code == .expectedConversionUnit)
      #expect(result.diagnostics.first?.severity == .incomplete)
      #expect(result.diagnostics.first?.range.upperBound == source.utf8.count)
    }

    let unknown = Parser(source: "1 m into furlongs").parse()
    #expect(unknown.diagnostics.first?.code == .unknownUnit)
    #expect(unknown.diagnostics.first?.range.text(in: "1 m into furlongs") == "furlongs")

    for source in ["1 m to 2", "1 m to )", "1 m to * s"] {
      let malformed = Parser(source: source).parse()
      #expect(malformed.diagnostics.first?.code == .expectedConversionUnit)
    }
  }

  @Test
  func boundsAndDisambiguatesUnitSyntax() {
    let tooManyFactors =
      "1 "
      + Array(
        repeating: "m",
        count: RatioUnit.maximumFactorCount + 1
      ).joined(separator: "*")
    let bounded = Parser(source: tooManyFactors).parse()
    #expect(bounded.diagnostics.first?.code == .resourceLimitExceeded)

    let repeatedPower = Parser(source: "2 m^2^3").parse()
    #expect(repeatedPower.diagnostics.first?.code == .invalidUnitExponent)
  }

  @Test
  func evaluatesConversionsAndQuantityArithmetic() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()

    let miles = try quantity(engine.evaluate("12 km in miles", context: context))
    #expect(miles.unit.symbol == "mi")
    #expect(
      miles.magnitude
        == .rational(
          try RationalValue(
            numerator: IntegerValue(31_250),
            denominator: IntegerValue(4_191)
          )
        )
    )

    let centimeters = try quantity(
      engine.evaluate("1 m + 1 ft in cm", context: context)
    )
    #expect(centimeters.unit.symbol == "cm")
    #expect(
      centimeters.magnitude
        == .rational(
          try RationalValue(
            numerator: IntegerValue(3_262),
            denominator: IntegerValue(25)
          )
        )
    )

    let fahrenheit = try quantity(
      engine.evaluate("0 °C as °F", context: context)
    )
    #expect(fahrenheit.unit.symbol == "°F")
    #expect(fahrenheit.magnitude == .integer(IntegerValue(32)))

    let negativeFahrenheit = try quantity(
      engine.evaluate("-40 °C in °F", context: context)
    )
    #expect(negativeFahrenheit.kind == .absolute)
    #expect(negativeFahrenheit.magnitude == .integer(IntegerValue(-40)))

    let minute = try quantity(
      engine.evaluate("1 min in s", context: context)
    )
    #expect(minute.magnitude == .integer(IntegerValue(60)))

    for keyword in ["in", "to", "as", "into"] {
      let value = try quantity(
        engine.evaluate("1 m \(keyword) cm", context: context)
      )
      #expect(value.unit.symbol == "cm")
      #expect(value.magnitude == .integer(IntegerValue(100)))
    }
  }

  @Test
  func evaluatesEngineeringArithmeticAndRejectsInvalidDimensions() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()

    let area = try quantity(engine.evaluate("2 m * 3 m", context: context))
    let areaDimension = try Dimension.length.raised(to: 2)
    #expect(area.magnitude == .integer(IntegerValue(6)))
    #expect(area.unit.dimension == areaDimension)

    let acceleration = try quantity(
      engine.evaluate("10 m / 2 s^2", context: context)
    )
    #expect(acceleration.magnitude == .integer(IntegerValue(5)))
    #expect(acceleration.unit.dimension == .acceleration)

    guard
      case .evaluationFailure(let incompatible) = engine.evaluate(
        "1 m to s",
        context: context
      )
    else {
      Issue.record("Expected incompatible conversion failure")
      return
    }
    #expect(incompatible.code == .incompatibleDimensions)
    #expect(incompatible.ranges.first?.text(in: "1 m to s") == "s")

    guard
      case .evaluationFailure(let affine) = engine.evaluate(
        "0 °C * 2",
        context: context
      )
    else {
      Issue.record("Expected affine arithmetic failure")
      return
    }
    #expect(affine.code == .invalidAbsoluteQuantityOperation)
  }

  private func quantity(_ result: CalculationResult) throws -> QuantityValue {
    guard case .value(.quantity(let quantity)) = result else {
      Issue.record("Expected quantity, got \(result)")
      throw EngineError(code: .typeMismatch)
    }
    return quantity
  }

  private func fixedContext() throws -> EvaluationContext {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }
}
