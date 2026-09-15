import Testing

@testable import GanitEngine

@Suite
struct NumericValueTests {
  @Test
  func constructsArbitrarySizeIntegersInSupportedRadices() throws {
    let decimalDigits = String(repeating: "1234567890", count: 20)
    let decimal = try IntegerValue(decimalDigits)

    #expect(decimal.canonicalDigits == decimalDigits)
    #expect(try IntegerValue("-00042") == IntegerValue(-42))
    #expect(try IntegerValue("101010", radix: .binary) == IntegerValue(42))
    #expect(try IntegerValue("52", radix: .octal) == IntegerValue(42))
    #expect(try IntegerValue("2a", radix: .hexadecimal) == IntegerValue(42))
    #expect(throws: EngineError(code: .invalidIntegerLiteral)) {
      try IntegerValue("", radix: .decimal)
    }
    #expect(throws: EngineError(code: .invalidIntegerLiteral)) {
      try IntegerValue("2", radix: .binary)
    }
  }

  @Test
  func boundsIntegerTextConversionBeforeBigIntParsing() throws {
    let maximumLength =
      "-"
      + String(repeating: "9", count: IntegerValue.maximumTextDigits)
    let oversized = String(
      repeating: "9",
      count: IntegerValue.maximumTextDigits + 1
    )

    #expect(try IntegerValue(maximumLength).isNegative)
    #expect(
      throws: EngineError(
        code: .integerLiteralTooLong,
        context: .maximumIntegerDigits(IntegerValue.maximumTextDigits)
      )
    ) {
      try IntegerValue(oversized)
    }
  }

  @Test
  func reducesRationalsAndCanonicalizesTheirSigns() throws {
    let reduced = try RationalValue(
      numerator: IntegerValue(-6),
      denominator: IntegerValue(-8)
    )
    let zero = try RationalValue(
      numerator: IntegerValue(0),
      denominator: IntegerValue(-9)
    )

    #expect(reduced.numerator == IntegerValue(3))
    #expect(reduced.denominator == IntegerValue(4))
    #expect(zero.numerator == IntegerValue(0))
    #expect(zero.denominator == IntegerValue(1))
  }

  @Test
  func rejectsAZeroRationalDenominatorWithTypedError() {
    #expect(throws: EngineError(code: .zeroDenominator)) {
      try RationalValue(
        numerator: IntegerValue(1),
        denominator: IntegerValue(0)
      )
    }
  }

  @Test
  func preservesDecimalScaleAsUserIntent() throws {
    let onePointZero = try DecimalValue(
      coefficient: IntegerValue(10),
      scale: 1
    )
    let onePointZeroZero = try DecimalValue(
      coefficient: IntegerValue(100),
      scale: 2
    )
    let oneThousand = try DecimalValue(
      coefficient: IntegerValue(1),
      scale: -3
    )

    #expect(onePointZero != onePointZeroZero)
    #expect(Set([onePointZero, onePointZeroZero]).count == 2)
    #expect(oneThousand.scale == -3)
    #expect(throws: EngineError(code: .invalidDecimalScale)) {
      try DecimalValue(coefficient: IntegerValue(1), scale: .min)
    }
  }

  @Test
  func validatesApproximationMetadata() throws {
    let errorBound = try DecimalValue(
      coefficient: IntegerValue(1),
      scale: 12
    )
    let negativeErrorBound = try DecimalValue(
      coefficient: IntegerValue(-1),
      scale: 3
    )
    let approximate = try ApproximateValue(
      estimate: -0.0,
      source: .transcendentalFunction,
      precision: .absoluteErrorBound(errorBound)
    )

    #expect(approximate.estimate.bitPattern == 0.0.bitPattern)
    #expect(approximate.precision == .absoluteErrorBound(errorBound))
    #expect(
      try ApproximateValue(
        estimate: 1,
        source: .explicitRounding,
        precision: .significantDecimalDigits(1)
      ).precision == .significantDecimalDigits(1)
    )
    #expect(
      try ApproximateValue(
        estimate: 1,
        source: .explicitRounding,
        precision: .significantDecimalDigits(
          ApproximateValue.maximumSignificantDecimalDigits
        )
      ).precision
        == .significantDecimalDigits(
          ApproximateValue.maximumSignificantDecimalDigits
        )
    )

    #expect(throws: EngineError(code: .nonFiniteApproximation)) {
      try ApproximateValue(
        estimate: .infinity,
        source: .iterativeMethod,
        precision: .unspecified
      )
    }
    #expect(
      throws: EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(0)
      )
    ) {
      try ApproximateValue(
        estimate: 1,
        source: .mathematicalConstant,
        precision: .significantDecimalDigits(0)
      )
    }
    #expect(
      throws: EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(
          ApproximateValue.maximumSignificantDecimalDigits + 1
        )
      )
    ) {
      try ApproximateValue(
        estimate: 1,
        source: .mathematicalConstant,
        precision: .significantDecimalDigits(
          ApproximateValue.maximumSignificantDecimalDigits + 1
        )
      )
    }
    #expect(throws: EngineError(code: .negativeApproximationErrorBound)) {
      try ApproximateValue(
        estimate: 1,
        source: .binaryFloatingPointConversion,
        precision: .absoluteErrorBound(negativeErrorBound)
      )
    }
  }

  @Test
  func carriesStableDiagnosticMetadataWithoutSourceText() {
    let range = SourceRange(
      lowerBound: 2,
      upperBound: 3,
      graphemeLowerBound: 2,
      graphemeUpperBound: 3
    )
    let fixIt = DiagnosticFixIt(
      range: range,
      replacement: "1",
      messageKey: "fix.insertNonzeroDenominator"
    )
    let error = EngineError(
      code: .divisionByZero,
      severity: .error,
      ranges: [range],
      fixIts: [fixIt]
    )

    #expect(error.code.rawValue == "evaluation.divisionByZero")
    #expect(error.messageKey == "error.evaluation.divisionByZero")
    #expect(error.ranges == [range])
    #expect(error.fixIts == [fixIt])
  }

  @Test
  func roundsFractionsToSignificantDigitsWithoutTrailingZeroes() throws {
    func decimalText(
      _ numerator: Int,
      _ denominator: Int,
      digits: Int = 15,
      rule: RoundingRule = .toNearestOrEven
    ) throws -> String {
      let value = try RationalValue(
        numerator: IntegerValue(numerator),
        denominator: IntegerValue(denominator)
      ).decimal(significantDigits: digits, rule: rule)
      return "\(value.coefficient.canonicalDigits)e-\(value.scale)"
    }

    #expect(try decimalText(31_250, 4_191) == "745645430684801e-14")
    #expect(try decimalText(1, 3) == "333333333333333e-15")
    #expect(try decimalText(-1, 3) == "-333333333333333e-15")
    // An exact decimal keeps only the digits it needs.
    #expect(try decimalText(10, 4) == "25e-1")
    #expect(try decimalText(-10, 4) == "-25e-1")
    #expect(try decimalText(0, 7) == "0e-0")
    // A tiny value keeps its significant digits rather than rounding to zero.
    #expect(try decimalText(1, 1_000_000, digits: 2) == "1e-6")
    #expect(try decimalText(1, 3_000_000, digits: 2) == "33e-8")
    // Rounding that carries into another digit drops the trailing zeroes.
    #expect(try decimalText(999, 100, digits: 2) == "10e-0")
    #expect(try decimalText(1_999, 1_000, digits: 3) == "2e-0")
    // Ties round to even, and directed rules follow the sign.
    #expect(try decimalText(25, 10, digits: 1) == "2e-0")
    #expect(try decimalText(35, 10, digits: 1) == "4e-0")
    #expect(try decimalText(1, 3, digits: 2, rule: .up) == "34e-2")
    #expect(try decimalText(1, 3, digits: 2, rule: .down) == "33e-2")
    #expect(try decimalText(-1, 3, digits: 2, rule: .down) == "-34e-2")
    #expect(try decimalText(-1, 3, digits: 2, rule: .towardZero) == "-33e-2")

    #expect(
      throws: EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(0)
      )
    ) {
      try RationalValue(
        numerator: IntegerValue(1),
        denominator: IntegerValue(3)
      ).decimal(significantDigits: 0)
    }
  }

  @Test
  func numericValuesAreSendableAndHashable() {
    requireSendableAndHashable(IntegerValue.self)
    requireSendableAndHashable(RationalValue.self)
    requireSendableAndHashable(DecimalValue.self)
    requireSendableAndHashable(ApproximateValue.self)
    requireSendableAndHashable(EngineError.self)
  }

  private func requireSendableAndHashable<T: Sendable & Hashable>(
    _: T.Type
  ) {}
}
