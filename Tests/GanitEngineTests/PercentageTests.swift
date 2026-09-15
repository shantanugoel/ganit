import Foundation
import Testing

@testable import GanitEngine

@Suite
struct PercentageTests {
  @Test
  func evaluatesStandalonePercentagesAndCommonPhrases() throws {
    #expect(try evaluate("20%") == percentage(20))
    #expect(try evaluate("20% of 50") == number(10))
    #expect(try evaluate("20% off 50") == number(40))
    #expect(try evaluate("20% on 50") == number(60))
    #expect(try evaluate("50 + 8%") == number(54))
    #expect(try evaluate("50 - 20%") == number(40))
    #expect(try evaluate("50 is what % of 200") == percentage(25))
    #expect(
      try evaluate("percentage change from 80 to 100") == percentage(25)
    )
    #expect(try evaluate("80 after 20% off") == number(100))
    #expect(try evaluate("120 after 20% on") == number(100))
  }

  @Test
  func composesPercentagesWithoutLosingTheirType() throws {
    #expect(try evaluate("20% + 5%") == percentage(25))
    #expect(try evaluate("20% / 2") == percentage(10))
    #expect(try evaluate("20% * 50") == number(10))
    #expect(try evaluate("(20% of 50) + 2") == number(12))
    #expect(try evaluate("-20% of 50") == number(-10))
    #expect(try evaluate("-20% off 50") == number(60))
    #expect(try evaluate("-20% on 50") == number(40))
    #expect(try evaluate("(20% + 5%) of 100") == number(25))
    #expect(try evaluate("(20% / 2) of 100") == number(10))
    #expect(
      try evaluate("1% of 1")
        == .number(
          .rational(
            try RationalValue(
              numerator: IntegerValue(1),
              denominator: IntegerValue(100)
            )
          )
        )
    )
  }

  @Test
  func rejectsNonsensicalMixedTypeOperationsWithAnExactRange() throws {
    guard
      case .evaluationFailure(let error) = engine.evaluate(
        "20% + 5",
        context: try context()
      )
    else {
      Issue.record("Expected a type mismatch")
      return
    }

    #expect(error.code == .typeMismatch)
    #expect(error.context == .typeMismatch(expected: .percentage, actual: .number))
    #expect(error.ranges.first?.lowerBound == 4)
    #expect(error.ranges.first?.upperBound == 5)
  }

  @Test
  func locatesZeroDivisorsInPercentagePhrases() throws {
    let cases = [
      ("50 is what % of 0", 16, 17),
      ("percentage change from 0 to 100", 23, 24),
      ("80 after 100% off", 9, 13),
    ]

    for (source, lowerBound, upperBound) in cases {
      guard
        case .evaluationFailure(let error) = engine.evaluate(
          source,
          context: try context()
        )
      else {
        Issue.record("Expected division by zero for \(source)")
        continue
      }
      #expect(error.code == .divisionByZero)
      #expect(error.ranges.first?.lowerBound == lowerBound)
      #expect(error.ranges.first?.upperBound == upperBound)
    }
  }

  /// A tenth of fifty kilograms is five kilograms, but a tenth of twenty
  /// degrees Celsius is a point on no scale.
  @Test
  func scalesQuantitiesThatCountAndRefusesThoseOnAScale() throws {
    #expect(try evaluate("10% of 50 kg") == (try evaluate("5 kg")))
    #expect(try evaluate("10% off 50 kg") == (try evaluate("45 kg")))
    #expect(try evaluate("10% on 20 m") == (try evaluate("22 m")))
    #expect(try evaluate("50 kg - 10%") == (try evaluate("45 kg")))
    #expect(try evaluate("50 kg + 10%") == (try evaluate("55 kg")))
    #expect(try evaluate("50 kg * 10%") == (try evaluate("5 kg")))

    for source in ["10% of 20 °C", "20 °C - 10%"] {
      guard
        case .evaluationFailure(let error) = engine.evaluate(
          source, context: try context())
      else {
        Issue.record("Expected a refusal for \(source)")
        continue
      }
      #expect(error.code == .invalidAbsoluteQuantityOperation)
    }
  }

  @Test
  func neverTreatsPercentAsModulo() throws {
    let result = engine.evaluate("50 % 20", context: try context())
    guard case .syntaxFailure = result else {
      Issue.record("Percent must not be interpreted as modulo: \(result)")
      return
    }
  }

  private var engine: CalculationEngine {
    CalculationEngine()
  }

  private func evaluate(_ source: String) throws -> EngineValue {
    guard
      case .value(let value) = engine.evaluate(source, context: try context())
    else {
      Issue.record("Expected value for \(source)")
      throw EngineError(code: .internalFailure)
    }
    return value
  }

  private func number(_ value: Int) -> EngineValue {
    .number(.integer(IntegerValue(value)))
  }

  private func percentage(_ points: Int) -> EngineValue {
    .percentage(
      PercentageValue(points: .integer(IntegerValue(points)))
    )
  }

  private func context() throws -> EvaluationContext {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: try PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }
}
