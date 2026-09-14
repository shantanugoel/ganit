import Foundation
import Testing

@testable import GanitEngine

@Suite
struct EvaluatorTests {
  @Test
  func evaluatesPrecedenceGroupingAndProgrammerLiterals() throws {
    #expect(try evaluate("1 + 2 * 3") == .integer(IntegerValue(7)))
    #expect(try evaluate("(1 + 2) * 3") == .integer(IntegerValue(9)))
    #expect(try evaluate("-2^2") == .integer(IntegerValue(-4)))
    #expect(try evaluate("2^3^2") == .integer(IntegerValue(512)))
    #expect(
      try evaluate("0xff + 0b1010") == .integer(IntegerValue(265))
    )
    #expect(try evaluate("2(3 + 4)") == .integer(IntegerValue(14)))
    #expect(try evaluate("(1 + 1)3") == .integer(IntegerValue(6)))
    guard case .approximate(let doubledPi) = try evaluate("2π") else {
      Issue.record("Implicit multiplication must preserve approximation")
      return
    }
    #expect(abs(doubledPi.estimate - 2 * .pi) < 1e-14)
  }

  @Test
  func preservesExactIntegerRationalAndDecimalResults() throws {
    #expect(
      try evaluate("1 / 3")
        == .rational(
          try RationalValue(
            numerator: IntegerValue(1),
            denominator: IntegerValue(3)
          )
        )
    )
    #expect(try evaluate("4 / 2") == .integer(IntegerValue(2)))
    #expect(
      try evaluate("1 / 2.0")
        == .decimal(
          try DecimalValue(coefficient: IntegerValue(5), scale: 1)
        )
    )
    #expect(
      try evaluate("(1 / 3) + 0.5")
        == .rational(
          try RationalValue(
            numerator: IntegerValue(5),
            denominator: IntegerValue(6)
          )
        )
    )
    #expect(
      try evaluate("1.20 + 2.3")
        == .decimal(
          try DecimalValue(coefficient: IntegerValue(350), scale: 2)
        )
    )
    #expect(
      try evaluate("1.20 * 2.0")
        == .decimal(
          try DecimalValue(coefficient: IntegerValue(2400), scale: 3)
        )
    )
  }

  @Test
  func evaluatesExactAndApproximatePowersAndRoots() throws {
    #expect(
      try evaluate("2^-3")
        == .rational(
          try RationalValue(
            numerator: IntegerValue(1),
            denominator: IntegerValue(8)
          )
        )
    )
    #expect(try evaluate("16^(3/4)") == .integer(IntegerValue(8)))
    #expect(
      try evaluate("2.0^-1")
        == .decimal(
          try DecimalValue(coefficient: IntegerValue(5), scale: 1)
        )
    )
    #expect(try evaluate("sqrt(144)") == .integer(IntegerValue(12)))
    #expect(
      try evaluate("sqrt(1/4)")
        == .rational(
          try RationalValue(
            numerator: IntegerValue(1),
            denominator: IntegerValue(2)
          )
        )
    )
    #expect(try evaluate("root(-8, 3)") == .integer(IntegerValue(-2)))

    guard case .approximate(let squareRoot) = try evaluate("sqrt(2)") else {
      Issue.record("sqrt(2) must be explicitly approximate")
      return
    }
    #expect(abs(squareRoot.estimate - 2.squareRoot()) < 1e-15)
    #expect(squareRoot.precision == .requestedSignificantDecimalDigits(15))

    guard
      case .approximate(let nearOne) =
        try evaluate("sqrt(((2^1024)+1)/((2^1024)-1))")
    else {
      Issue.record("A non-perfect rational root must be approximate")
      return
    }
    #expect(nearOne.estimate.isFinite)
    #expect(abs(nearOne.estimate - 1) < 1e-12)

    guard
      case .approximate(let largeRoot) = try evaluate("root(1e400, 3)"),
      case .approximate(let smallRoot) = try evaluate("root(2e-1000, 10)")
    else {
      Issue.record("Representable roots must survive scaled conversion")
      return
    }
    #expect(largeRoot.estimate.isFinite)
    #expect(largeRoot.estimate > 1e133)
    #expect(smallRoot.estimate.isFinite)
    #expect(smallRoot.estimate > 1e-101)
  }

  @Test
  func evaluatesCoreExactFunctions() throws {
    #expect(try evaluate("abs(-3)") == .integer(IntegerValue(3)))
    #expect(try evaluate("floor(-3/2)") == .integer(IntegerValue(-2)))
    #expect(try evaluate("ceil(-3/2)") == .integer(IntegerValue(-1)))
    #expect(try evaluate("round(2.5)") == .integer(IntegerValue(2)))
    #expect(try evaluate("round(3.5)") == .integer(IntegerValue(4)))
    #expect(try evaluate("round(-2.5)") == .integer(IntegerValue(-2)))
    #expect(
      try evaluate("min(1.00, 1)")
        == .decimal(
          try DecimalValue(coefficient: IntegerValue(100), scale: 2)
        )
    )
    #expect(try evaluate("max(-2, 3, 1)") == .integer(IntegerValue(3)))
  }

  @Test
  func marksConstantsAndDerivedArithmeticAsApproximate() throws {
    guard case .approximate(let pi) = try evaluate("π"),
      case .approximate(let result) = try evaluate("pi + e")
    else {
      Issue.record("Constants must be explicitly approximate")
      return
    }

    #expect(abs(pi.estimate - .pi) < 1e-15)
    #expect(pi.source == .mathematicalConstant)
    #expect(result.source == .derivedArithmetic)
    #expect(result.precision == .unspecified)

    guard case .approximate(let cancellation) = try evaluate("pi - pi") else {
      Issue.record("Approximate cancellation must remain approximate")
      return
    }
    #expect(cancellation.estimate == 0)
  }

  @Test
  func reportsRangedDomainsNamesAndArgumentCounts() throws {
    let zeroPowerZero = try error(evaluating: "0^0")
    #expect(zeroPowerZero.code == .invalidDomain)
    #expect(zeroPowerZero.ranges.first?.lowerBound == 1)

    let divisionByZero = try error(evaluating: "1 / 0")
    #expect(divisionByZero.code == .divisionByZero)
    #expect(divisionByZero.ranges.first?.lowerBound == 4)

    let evenNegativeRoot = try error(evaluating: "root(-8, 2)")
    #expect(evenNegativeRoot.code == .invalidDomain)
    #expect(evenNegativeRoot.ranges.first?.lowerBound == 5)

    let invalidDegree = try error(evaluating: "root(8, 0)")
    #expect(invalidDegree.code == .invalidDomain)
    #expect(invalidDegree.ranges.first?.lowerBound == 8)

    let approximateEvenNegativeRoot = try error(evaluating: "root(-pi, 2)")
    #expect(approximateEvenNegativeRoot.code == .invalidDomain)
    #expect(approximateEvenNegativeRoot.ranges.first?.lowerBound == 5)

    let approximateInvalidPower = try error(evaluating: "(-pi)^0.5")
    #expect(approximateInvalidPower.code == .invalidDomain)
    let uncertainIntegralPower = try error(
      evaluating: "(-2)^(pi + 1e-16 - pi + 3)"
    )
    #expect(uncertainIntegralPower.code == .invalidDomain)

    let approximateDegree = try error(evaluating: "root(8, pi)")
    #expect(approximateDegree.code == .invalidDomain)
    #expect(approximateDegree.ranges.first?.lowerBound == 8)

    let unknownIdentifier = try error(evaluating: "answer")
    #expect(unknownIdentifier.code == .unknownIdentifier)
    #expect(unknownIdentifier.ranges.first?.upperBound == 6)

    let unknownFunction = try error(evaluating: "mean(1, 2)")
    #expect(unknownFunction.code == .unknownFunction)
    #expect(unknownFunction.ranges.first?.upperBound == 4)

    let argumentCount = try error(evaluating: "sqrt(1, 2)")
    #expect(argumentCount.code == .argumentCountMismatch)
    #expect(
      argumentCount.context
        == .argumentCount(function: .squareRoot, expected: 1...1, actual: 2)
    )
  }

  @Test
  func enforcesEvaluationResourceLimits() throws {
    let bitLimits = EvaluationLimits(maximumIntegerBits: 3)
    let bitError = try error(evaluating: "3 * 3", limits: bitLimits)
    #expect(bitError.code == .resourceLimitExceeded)
    #expect(bitError.context == .resourceLimit(.integerBits))

    let exponentLimits = EvaluationLimits(maximumPowerExponent: 3)
    let exponentError = try error(evaluating: "2^4", limits: exponentLimits)
    #expect(exponentError.context == .resourceLimit(.powerExponent))
    let approximateExponentError = try error(
      evaluating: "pi^4",
      limits: exponentLimits
    )
    #expect(
      approximateExponentError.context == .resourceLimit(.powerExponent)
    )

    let scaleLimits = EvaluationLimits(maximumDecimalScaleMagnitude: 2)
    let scaleError = try error(evaluating: "1e3", limits: scaleLimits)
    #expect(scaleError.context == .resourceLimit(.decimalScale))

    let operationLimits = EvaluationLimits(maximumOperations: 2)
    let operationError = try error(evaluating: "1 + 2", limits: operationLimits)
    #expect(operationError.context == .resourceLimit(.operations))
  }

  private func evaluate(
    _ source: String,
    limits: EvaluationLimits = .default
  ) throws -> NumericValue {
    let parsing = Parser(source: source).parse()
    #expect(parsing.diagnostics.isEmpty)
    let expression = try #require(parsing.expression)
    return try Evaluator(
      context: fixedContext(),
      limits: limits
    ).evaluate(expression)
  }

  private func fixedContext() throws -> EvaluationContext {
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

  private func error(
    evaluating source: String,
    limits: EvaluationLimits = .default
  ) throws -> EngineError {
    do {
      let value = try evaluate(source, limits: limits)
      Issue.record("Expected an error, got \(value)")
      throw EngineError(code: .invalidDomain)
    } catch let error as EngineError {
      return error
    }
  }
}
