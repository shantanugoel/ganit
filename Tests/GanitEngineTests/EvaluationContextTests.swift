import Foundation
import Testing

@testable import GanitEngine

@Suite
struct EvaluationContextTests {
  @Test
  func carriesEveryDeterministicInputImmutably() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let context = try makeContext(
      localeIdentifier: "fr-FR",
      lexingConfiguration: LexingConfiguration(
        decimalSeparator: ",",
        groupingSeparator: " "
      ),
      angleMode: .degrees,
      significantDigits: 12,
      roundingRule: .awayFromZero,
      now: now,
      calendarIdentifier: .iso8601,
      timeZoneIdentifier: "Europe/Paris"
    )

    #expect(context.localeIdentifier == "fr-FR")
    #expect(context.lexingConfiguration.decimalSeparator == ",")
    #expect(context.angleMode == .degrees)
    #expect(context.precision.significantDecimalDigits == 12)
    #expect(context.precision.roundingRule == .awayFromZero)
    #expect(context.now == now)
    #expect(context.calendarIdentifier == .iso8601)
    #expect(context.timeZoneIdentifier == "Europe/Paris")
    #expect(context.calendar.timeZone == context.timeZone)
    #expect(context.calendar.locale?.identifier == "fr-FR")
    requireSendableAndHashable(EvaluationContext.self)
  }

  @Test
  func rejectsUnsupportedApproximationPrecision() {
    #expect(
      throws: EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(18)
      )
    ) {
      try PrecisionContext(significantDecimalDigits: 18)
    }
  }

  @Test
  func rejectsAmbientOrNonreflexiveContextValues() throws {
    let precision = try PrecisionContext(significantDecimalDigits: 15)
    let calendar = Calendar(identifier: .gregorian)

    #expect(
      throws: EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.timeZone)
      )
    ) {
      try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: precision,
        now: Date(timeIntervalSince1970: 0),
        calendar: calendar,
        timeZone: .autoupdatingCurrent
      )
    }
    #expect(
      throws: EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.locale)
      )
    ) {
      try EvaluationContext(
        localeIdentifier: "",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: precision,
        now: Date(timeIntervalSince1970: 0),
        calendar: calendar,
        timeZone: try #require(TimeZone(identifier: "UTC"))
      )
    }
    #expect(
      throws: EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.locale)
      )
    ) {
      try EvaluationContext(
        localeIdentifier: "not valid",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: precision,
        now: Date(timeIntervalSince1970: 0),
        calendar: calendar,
        timeZone: try #require(TimeZone(identifier: "UTC"))
      )
    }
    #expect(
      throws: EngineError(
        code: .invalidEvaluationContext,
        context: .evaluationContext(.now)
      )
    ) {
      try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: precision,
        now: Date(timeIntervalSince1970: .nan),
        calendar: calendar,
        timeZone: try #require(TimeZone(identifier: "UTC"))
      )
    }
  }

  @Test
  func validatesBCP47StructureIncludingLegacyAndPrivateUseTags() throws {
    #expect(try makeContext(localeIdentifier: "x-private").localeIdentifier == "x-private")
    #expect(try makeContext(localeIdentifier: "i-klingon").localeIdentifier == "i-klingon")

    for invalidIdentifier in ["en-u", "en-0", "en-US-en-US", "en--US"] {
      #expect(
        throws: EngineError(
          code: .invalidEvaluationContext,
          context: .evaluationContext(.locale)
        )
      ) {
        try makeContext(localeIdentifier: invalidIdentifier)
      }
    }
  }

  @Test
  func calculationEngineUsesOnlyTheInjectedLocale() throws {
    let french = try makeContext(
      localeIdentifier: "fr-FR",
      lexingConfiguration: LexingConfiguration(
        decimalSeparator: ",",
        groupingSeparator: " "
      )
    )
    let result = CalculationEngine().evaluate("1,5 + 2,5", context: french)
    let parsing = CalculationEngine().parse("1,5", context: french)

    #expect(parsing.diagnostics.isEmpty)
    #expect(parsing.expression != nil)
    #expect(
      result
        == .value(
          .number(
            .decimal(
              try DecimalValue(coefficient: IntegerValue(40), scale: 1)
            )
          )
        )
    )
  }

  @Test
  func angleModeChangesTrigonometricInterpretation() throws {
    let degrees = try makeContext(angleMode: .degrees)
    let radians = try makeContext(angleMode: .radians)
    let degreeResult = try value("sin(90)", context: degrees)
    let radianResult = try value("sin(90)", context: radians)
    let inverse = try value("asin(1)", context: degrees)

    #expect(try approximate(degreeResult).estimate == 1)
    #expect(abs(try approximate(radianResult).estimate - 1) > 0.1)
    #expect(try approximate(inverse).estimate == 90)
  }

  @Test
  func precisionAndRoundingComeFromContext() throws {
    let context = try makeContext(
      significantDigits: 7,
      roundingRule: .awayFromZero
    )
    let sine = try approximate(try value("sin(1)", context: context))

    #expect(sine.precision == .requestedSignificantDecimalDigits(7))
    #expect(
      try value("round(2.1)", context: context)
        == .integer(IntegerValue(3))
    )
    #expect(
      try value("round(-2.1)", context: context)
        == .integer(IntegerValue(-3))
    )
    #expect(
      try value("round(2.11, 1)", context: context)
        == .decimal(try DecimalValue(coefficient: IntegerValue(22), scale: 1))
    )
  }

  @Test
  func capsReportedTranscendentalAccuracyWithoutIgnoringRequest() throws {
    let context = try makeContext(significantDigits: 17)
    let sine = try approximate(try value("sin(1)", context: context))

    #expect(sine.precision == .requestedSignificantDecimalDigits(15))
    #expect(context.precision.significantDecimalDigits == 17)
  }

  @Test
  func evaluatesLogarithmicFunctionsWithExplicitDomains() throws {
    let context = try makeContext()

    #expect(
      abs(try approximate(try value("log(100)", context: context)).estimate - 2)
        < 1e-14
    )
    #expect(
      abs(try approximate(try value("ln(e)", context: context)).estimate - 1)
        < 1e-14
    )
    #expect(
      abs(
        try approximate(try value("ln(1e400)", context: context)).estimate
          - 400 * log(10)
      ) < 1e-12
    )
    #expect(
      abs(
        try approximate(try value("ln(1e-1000)", context: context)).estimate
          + 1000 * log(10)
      ) < 1e-12
    )
    #expect(
      abs(
        try approximate(try value("atan(1e400)", context: context)).estimate
          - .pi / 2
      ) < 1e-14
    )
    #expect(
      error("atan(1e-1000)", context: context).code
        == .approximationOutOfRange
    )
    #expect(
      error("ln(0)", context: context).code == .invalidDomain
    )
    #expect(
      error("tan(90)", context: try makeContext(angleMode: .degrees)).code
        == .invalidDomain
    )
    #expect(
      error(
        "tan(9000000000000090)",
        context: try makeContext(angleMode: .degrees)
      ).code == .invalidDomain
    )
    #expect(
      error(
        "asin(1.0000000000000000000000001)",
        context: context
      ).code == .invalidDomain
    )
  }

  private func makeContext(
    localeIdentifier: String = "en-US",
    lexingConfiguration: LexingConfiguration = .englishUnitedStates,
    angleMode: AngleMode = .radians,
    significantDigits: Int = 15,
    roundingRule: RoundingRule = .toNearestOrEven,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    calendarIdentifier: Calendar.Identifier = .gregorian,
    timeZoneIdentifier: String = "UTC"
  ) throws -> EvaluationContext {
    let timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
    return try EvaluationContext(
      localeIdentifier: localeIdentifier,
      lexingConfiguration: lexingConfiguration,
      angleMode: angleMode,
      precision: try PrecisionContext(
        significantDecimalDigits: significantDigits,
        roundingRule: roundingRule
      ),
      now: now,
      calendar: Calendar(identifier: calendarIdentifier),
      timeZone: timeZone
    )
  }

  private func value(
    _ source: String,
    context: EvaluationContext
  ) throws -> NumericValue {
    let result = CalculationEngine().evaluate(source, context: context)
    guard case .value(let value) = result else {
      Issue.record("Expected value, got \(result)")
      throw EngineError(code: .internalFailure)
    }
    guard case .number(let number) = value else {
      Issue.record("Expected numeric result")
      throw EngineError(code: .typeMismatch)
    }
    return number
  }

  private func error(
    _ source: String,
    context: EvaluationContext
  ) -> EngineError {
    let result = CalculationEngine().evaluate(source, context: context)
    guard case .evaluationFailure(let error) = result else {
      Issue.record("Expected evaluation error, got \(result)")
      return EngineError(code: .internalFailure)
    }
    return error
  }

  private func approximate(_ value: NumericValue) throws -> ApproximateValue {
    guard case .approximate(let approximate) = value else {
      Issue.record("Expected approximate value, got \(value)")
      throw EngineError(code: .internalFailure)
    }
    return approximate
  }

  private func requireSendableAndHashable<T: Sendable & Hashable>(
    _: T.Type
  ) {}
}
