import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct ResultFormatterTests {
  @Test
  func formatsTypedPercentagesUsingLocalePlacement() throws {
    let value = EngineValue.percentage(
      PercentageValue(points: .integer(IntegerValue(20)))
    )
    let english = try ResultFormatter(context: context()).format(value)
    let turkish = try ResultFormatter(
      context: context(localeIdentifier: "tr-TR")
    ).format(value)

    #expect(english.display == "20%")
    #expect(turkish.display == "%20")
    #expect(english.fullPrecision == "20%")
    #expect(!english.isApproximate)
  }

  @Test
  func keepsLocaleSignsAndApproximationOutsidePercentAffixes() throws {
    let formatter = ResultFormatter(
      context: try context(localeIdentifier: "tr-TR")
    )
    let negative = try formatter.format(
      .percentage(
        PercentageValue(points: .integer(IntegerValue(-20)))
      )
    )
    let approximate = try formatter.format(
      .percentage(
        PercentageValue(
          points: .approximate(
            try ApproximateValue(
              estimate: -20,
              source: .derivedArithmetic,
              precision: .significantDecimalDigits(2)
            )
          )
        )
      )
    )

    #expect(negative.display == "-%20")
    #expect(approximate.display == "≈ -%20")
    #expect(approximate.fullPrecision == "≈ -20.0%")
  }

  @Test
  func formatsIntegersWithWesternAndIndianGrouping() throws {
    let value = NumericValue.integer(try IntegerValue("1234567"))
    let western = try NumericResultFormatter(context: context()).format(value)
    let indian = try NumericResultFormatter(
      context: context(
        localeIdentifier: "en-IN",
        lexingConfiguration: LexingConfiguration(
          decimalSeparator: ".",
          groupingSeparator: ",",
          primaryGroupingSize: 3,
          secondaryGroupingSize: 2
        )
      )
    ).format(value)

    #expect(western.display == "1,234,567")
    #expect(indian.display == "12,34,567")
    #expect(western.fullPrecision == "1234567")
    #expect(!western.isApproximate)
  }

  @Test
  func localizesDecimalSeparatorsAndDigitsWithoutChangingCanonicalValue() throws {
    let decimal = try DecimalValue(
      coefficient: IntegerValue(123_450),
      scale: 2
    )
    let french = try NumericResultFormatter(
      context: context(
        localeIdentifier: "fr-FR",
        lexingConfiguration: LexingConfiguration(
          decimalSeparator: ",",
          groupingSeparator: " "
        )
      )
    ).format(.decimal(decimal))
    let arabic = try NumericResultFormatter(
      context: context(
        localeIdentifier: "ar-EG",
        lexingConfiguration: LexingConfiguration(
          decimalSeparator: "٫",
          groupingSeparator: "٬"
        )
      )
    ).format(.decimal(decimal))

    #expect(french.display == "1 234,50")
    #expect(arabic.display == "١٬٢٣٤٫٥٠")
    #expect(french.fullPrecision == "1234.50")
    #expect(arabic.fullPrecision == "1234.50")
    #expect(decimal.coefficient == IntegerValue(123_450))
    #expect(decimal.scale == 2)
  }

  @Test
  func preservesExactDecimalScaleAndRationalStructure() throws {
    let trailingZeros = try NumericResultFormatter(context: context()).format(
      .decimal(
        try DecimalValue(coefficient: IntegerValue(100), scale: 2)
      )
    )
    let negativeScale = try NumericResultFormatter(context: context()).format(
      .decimal(
        try DecimalValue(coefficient: IntegerValue(-12), scale: -3)
      )
    )
    let rational = try NumericResultFormatter(context: context()).format(
      .rational(
        try RationalValue(
          numerator: IntegerValue(-10_000),
          denominator: IntegerValue(3)
        )
      )
    )

    #expect(trailingZeros.display == "1.00")
    #expect(trailingZeros.fullPrecision == "1.00")
    #expect(negativeScale.display == "-12,000")
    #expect(negativeScale.fullPrecision == "-12000")
    #expect(rational.display == "-10,000/3")
    #expect(rational.fullPrecision == "-10000/3")
  }

  @Test
  func distinguishesApproximateDisplayFromFullPrecision() throws {
    let approximate = try ApproximateValue(
      estimate: 12_345.678_901_234_5,
      source: .transcendentalFunction,
      precision: .significantDecimalDigits(5)
    )
    let result = try NumericResultFormatter(
      context: context(significantDigits: 17)
    ).format(.approximate(approximate))

    #expect(result.display == "≈ 12,346")
    #expect(result.fullPrecision == "≈ 12345.6789012345")
    #expect(result.display != result.fullPrecision)
    #expect(result.isApproximate)
  }

  @Test
  func boundsOutputBeforeLargeScaleAllocation() throws {
    let formatter = NumericResultFormatter(
      context: try context(),
      limits: FormattingLimits(maximumCharacters: 10)
    )
    let largeInteger = NumericValue.integer(
      try IntegerValue("12345678901")
    )
    let hugeScale = NumericValue.decimal(
      try DecimalValue(coefficient: IntegerValue(1), scale: .max)
    )

    #expect(throws: FormattingError.outputTooLong) {
      try formatter.format(largeInteger)
    }
    #expect(throws: FormattingError.outputTooLong) {
      try formatter.format(hugeScale)
    }
  }

  @Test
  func acceptsExactCharacterLimitAndUsesLocalePresentationOnly() throws {
    let exactFit = try NumericResultFormatter(
      context: context(),
      limits: FormattingLimits(maximumCharacters: 3)
    ).format(.integer(IntegerValue(512)))
    let mismatchedParserSyntax = try NumericResultFormatter(
      context: context(
        localeIdentifier: "fr-FR",
        lexingConfiguration: .englishUnitedStates
      )
    ).format(
      .decimal(
        try DecimalValue(coefficient: IntegerValue(123_450), scale: 2)
      )
    )
    let arabicNegative = try NumericResultFormatter(
      context: context(localeIdentifier: "ar-EG")
    ).format(.integer(IntegerValue(-12)))

    #expect(exactFit.display == "512")
    #expect(mismatchedParserSyntax.display == "1 234,50")
    #expect(arabicNegative.display == "؜-١٢")
    #expect(arabicNegative.fullPrecision == "-12")
  }

  @Test
  func keepsTinyNonzeroApproximationsVisible() throws {
    let value = try ApproximateValue(
      estimate: 1e-300,
      source: .derivedArithmetic,
      precision: .requestedSignificantDecimalDigits(3)
    )
    let result = try NumericResultFormatter(
      context: context(significantDigits: 17)
    ).format(.approximate(value))

    #expect(result.display == "≈ 1E-300")
    #expect(result.fullPrecision == "≈ 1e-300")
  }

  @Test
  func honorsAbsoluteErrorAndLocaleMinimumGroupingDigits() throws {
    let errorBound = try DecimalValue(
      coefficient: IntegerValue(10),
      scale: 0
    )
    let approximate = try ApproximateValue(
      estimate: 123.456,
      source: .iterativeMethod,
      precision: .absoluteErrorBound(errorBound)
    )
    let formattedApproximation = try NumericResultFormatter(
      context: context(significantDigits: 17)
    ).format(.approximate(approximate))
    let spanish = NumericResultFormatter(
      context: try context(localeIdentifier: "es-ES")
    )

    #expect(formattedApproximation.display == "≈ 120")
    #expect(
      try spanish.format(.integer(IntegerValue(1_234))).display == "1234"
    )
    #expect(
      try spanish.format(.integer(IntegerValue(12_345))).display == "12.345"
    )
  }

  @Test
  func formatsFailuresWithCodeSeverityRangeAndLocalizedMessage() throws {
    let evaluationContext = try context()
    let engine = CalculationEngine()
    let formatter = DiagnosticFormatter(context: evaluationContext)

    guard
      case .evaluationFailure(let evaluationError) = engine.evaluate(
        "1 / 0",
        context: evaluationContext
      )
    else {
      Issue.record("Expected division-by-zero failure")
      return
    }
    let formattedEvaluation = formatter.format(evaluationError)
    #expect(formattedEvaluation.code == "evaluation.divisionByZero")
    #expect(formattedEvaluation.severity == .error)
    #expect(formattedEvaluation.ranges.count == 1)
    #expect(formattedEvaluation.message == "Cannot divide by zero.")

    guard
      case .syntaxFailure(let syntaxErrors) = engine.evaluate(
        "1 +",
        context: evaluationContext
      ),
      let syntaxError = syntaxErrors.first
    else {
      Issue.record("Expected incomplete-expression failure")
      return
    }
    let formattedSyntax = formatter.format(syntaxError)
    #expect(formattedSyntax.code == "expectedExpression")
    #expect(formattedSyntax.severity == .incomplete)
    #expect(formattedSyntax.ranges.count == 1)
    #expect(formattedSyntax.message == "Enter an expression here.")

    let formattedOutputLimit = formatter.format(
      .outputTooLong,
      ranges: formattedSyntax.ranges
    )
    #expect(formattedOutputLimit.code == "formatting.outputTooLong")
    #expect(formattedOutputLimit.ranges == formattedSyntax.ranges)
    #expect(
      formattedOutputLimit.message
        == "The formatted result is too long to display."
    )
  }

  private func context(
    localeIdentifier: String = "en-US",
    lexingConfiguration: LexingConfiguration = .englishUnitedStates,
    significantDigits: Int = 15
  ) throws -> EvaluationContext {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return try EvaluationContext(
      localeIdentifier: localeIdentifier,
      lexingConfiguration: lexingConfiguration,
      angleMode: .radians,
      precision: PrecisionContext(
        significantDecimalDigits: significantDigits
      ),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }
}
