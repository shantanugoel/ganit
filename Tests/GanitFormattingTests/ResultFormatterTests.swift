import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct ResultFormatterTests {
  @Test
  func preservesExplicitConversionTargetUnits() throws {
    let evaluationContext = try context()
    let engine = CalculationEngine()
    let formatter = ResultFormatter(context: evaluationContext)
    let cases = [
      ("12 km in miles", "7.45645430684801 mi", "31250/4191 mi"),
      ("1 m + 1 ft in cm", "130.48 cm", "3262/25 cm"),
      ("0 °C as °F", "32 °F", "32 °F"),
      ("75 MB/s", "75 MB/s", "75 MB/s"),
      ("1 kg·m/s²", "1 kg·m/s^2", "1 kg·m/s^2"),
    ]

    for (source, display, fullPrecision) in cases {
      guard
        case .value(let value) = engine.evaluate(
          source,
          context: evaluationContext
        )
      else {
        Issue.record("Expected formatted quantity for \(source)")
        continue
      }
      let formatted = try formatter.format(value)
      #expect(formatted.display == display)
      #expect(formatted.fullPrecision == fullPrecision)
    }
  }

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
  func formatsMoneyInLocaleStyleRoundedToMinorUnits() throws {
    let english = ResultFormatter(context: try context())
    let german = ResultFormatter(context: try context(localeIdentifier: "de-DE"))
    let cases: [(ResultFormatter, MoneyValue, String, String, Bool)] = [
      (english, money(.integer(IntegerValue(1_234)), "USD"), "$1,234.00", "1234 USD", false),
      (english, money(try decimal(11_551, scale: 2), "EUR"), "€115.51", "115.51 EUR", false),
      (english, money(try rational(100, 3), "USD"), "≈ $33.33", "100/3 USD", true),
      (english, money(try decimal(-125, scale: 1), "JPY"), "≈ -¥13", "-12.5 JPY", true),
      (
        english, money(try decimal(1_2345, scale: 4), "KWD"), "≈ KWD\u{A0}1.235", "1.2345 KWD", true
      ),
      (
        german, money(try decimal(123_456, scale: 2), "EUR"), "1.234,56\u{A0}€", "1234.56 EUR",
        false
      ),
    ]
    for (formatter, value, display, fullPrecision, isApproximate) in cases {
      let result = try formatter.format(.money(value))
      #expect(result.display == display)
      #expect(result.fullPrecision == fullPrecision)
      #expect(result.isApproximate == isApproximate)
    }
  }

  /// A monthly payment is an exact fraction with hundreds of digits above and
  /// below the line, and a currency total can outgrow any fixed-width decimal.
  /// Both still have to read as amounts of money.
  @Test
  func roundsMoneyWiderThanAFixedWidthDecimal() throws {
    let formatter = ResultFormatter(context: try context())
    let payment = try rationalDigits(
      String(repeating: "7", count: 60),
      String(repeating: "3", count: 58)
    )
    let wide = NumericValue.integer(try IntegerValue(String(repeating: "9", count: 40)))

    let rounded = try formatter.format(.money(money(payment, "USD")))
    #expect(rounded.display == "≈ $233.33")
    #expect(rounded.isApproximate)

    // Past the currency formatter's reach the digits stay and the symbol goes.
    let total = try formatter.format(.money(money(wide, "USD")))
    #expect(
      total.display == "9,999,999,999,999,999,999,999,999,999,999,999,999,999.00 USD"
    )
    #expect(!total.isApproximate)
  }

  private func rationalDigits(_ numerator: String, _ denominator: String) throws -> NumericValue {
    .rational(
      try RationalValue(
        numerator: try IntegerValue(numerator),
        denominator: try IntegerValue(denominator)
      )
    )
  }

  private func money(_ amount: NumericValue, _ currency: String) -> MoneyValue {
    MoneyValue(amount: amount, currency: currency)
  }

  private func decimal(_ coefficient: Int, scale: Int) throws -> NumericValue {
    .decimal(try DecimalValue(coefficient: IntegerValue(coefficient), scale: scale))
  }

  private func rational(_ numerator: Int, _ denominator: Int) throws -> NumericValue {
    .rational(
      try RationalValue(numerator: IntegerValue(numerator), denominator: IntegerValue(denominator)))
  }

  @Test
  func formatsTemporalValuesWithISOFullPrecision() throws {
    let formatter = ResultFormatter(context: try context())
    let cases: [(EngineValue, String, String)] = [
      (.date(try DateValue(year: 2024, month: 2, day: 29)), "Feb 29, 2024", "2024-02-29"),
      (.time(try LocalTimeValue(hour: 14, minute: 5)), "2:05\u{202F}PM", "14:05:00"),
      (.time(try LocalTimeValue(hour: 9, minute: 0, second: 7)), "9:00:07\u{202F}AM", "09:00:07"),
      (
        .instant(
          InstantValue(
            date: Date(timeIntervalSince1970: 1_710_003_600),
            timeZoneIdentifier: "America/New_York"
          )
        ),
        "Mar 9, 2024 at 12:00\u{202F}PM America/New_York",
        "2024-03-09T12:00:00-05:00[America/New_York]"
      ),
      (.period(CalendarPeriodValue(months: 14, days: 3)), "1 year, 2 months, 3 days", "P1Y2M3D"),
      (.period(CalendarPeriodValue()), "0 days", "P0D"),
      (.period(CalendarPeriodValue(days: -298)), "-298 days", "P-298D"),
      (.period(CalendarPeriodValue(months: 12)), "1 year", "P1Y"),
    ]

    for (value, display, fullPrecision) in cases {
      let result = try formatter.format(value)
      #expect(result.display == display)
      #expect(result.fullPrecision == fullPrecision)
      #expect(!result.isApproximate)
    }
  }

  @Test
  func formatsDimensionedRatesWithoutFlatteningTheirAmounts() throws {
    let evaluationContext = try context()
    let catalog = try UnitCatalog.minimal()
    let algebra = UnitAlgebra(context: evaluationContext)
    let secondDefinition = try #require(
      catalog.unit(matching: "s")?.definition
    )
    let meterDefinition = try #require(
      catalog.unit(matching: "m")?.definition
    )
    let byteDefinition = try #require(
      catalog.unit(matching: "B")?.definition
    )
    let mega = try #require(catalog.prefix(matching: "M")?.prefix)
    let second = try algebra.unit(secondDefinition)
    let meter = try algebra.unit(meterDefinition)
    let megabyte = try algebra.unit(
      algebra.applying(mega, to: byteDefinition)
    )
    let dataRate = try algebra.divided(megabyte, by: second)
    let formatter = ResultFormatter(context: evaluationContext)

    let annualPercentage = try formatter.format(
      .rate(
        try RateValue(
          amount: .percentage(
            PercentageValue(
              points: .decimal(
                try DecimalValue(
                  coefficient: IntegerValue(65),
                  scale: 1
                )
              )
            )
          ),
          denominator: .calendar(.year)
        )
      )
    )
    let throughput = try formatter.format(
      .quantity(
        QuantityValue(
          magnitude: .integer(IntegerValue(75)),
          unit: dataRate
        )
      )
    )
    let inverseSpeed = try formatter.format(
      .rate(
        try RateValue(
          amount: .number(.integer(IntegerValue(2))),
          denominator: .unit(try algebra.divided(meter, by: second))
        )
      )
    )
    let inverseProduct = try formatter.format(
      .rate(
        try RateValue(
          amount: .number(.integer(IntegerValue(2))),
          denominator: .unit(try algebra.multiplied(meter, by: second))
        )
      )
    )
    let turkishAnnual = try ResultFormatter(
      context: try context(localeIdentifier: "tr-TR")
    ).format(
      .rate(
        try RateValue(
          amount: .percentage(
            PercentageValue(
              points: .decimal(
                try DecimalValue(
                  coefficient: IntegerValue(65),
                  scale: 1
                )
              )
            )
          ),
          denominator: .calendar(.year)
        )
      )
    )

    #expect(annualPercentage.display == "6.5%/year")
    #expect(annualPercentage.fullPrecision == "6.5%/year")
    #expect(throughput.display == "75 MB/s")
    #expect(throughput.fullPrecision == "75 MB/s")
    #expect(inverseSpeed.display == "2/(m/s)")
    #expect(inverseSpeed.fullPrecision == "2/(m/s)")
    #expect(inverseProduct.display == "2/(m·s)")
    #expect(inverseProduct.fullPrecision == "2/(m·s)")
    #expect(turkishAnnual.display == "%6,5/yıl")
    #expect(turkishAnnual.fullPrecision == "6.5%/year")
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

    #expect(french.display == "1 234,5")
    #expect(arabic.display == "١٬٢٣٤٫٥")
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

    #expect(trailingZeros.display == "1")
    #expect(trailingZeros.fullPrecision == "1.00")
    #expect(negativeScale.display == "-12,000")
    #expect(negativeScale.fullPrecision == "-12000")
    // A fraction reads as a rounded decimal; the fraction itself stays exact
    // in full precision and the result is not marked approximate.
    #expect(rational.display == "-3,333.33333333333")
    #expect(rational.fullPrecision == "-10000/3")
    #expect(!rational.isApproximate)
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
    #expect(mismatchedParserSyntax.display == "1 234,5")
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
    #expect(
      formatter.format(EngineError(code: .unavailableReference, context: .failedLine(12))).message
        == "Line 12 has an error, so this cannot use it.")
    #expect(
      formatter.format(EngineError(code: .unavailableReference, context: .failedVariable("rent")))
        .message == "rent has an error, so this cannot use it.")

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
