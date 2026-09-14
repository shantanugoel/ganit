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
