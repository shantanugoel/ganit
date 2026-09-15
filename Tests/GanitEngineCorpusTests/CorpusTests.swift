import Foundation
import GanitEngine
import GanitFormatting
import Testing

@Suite
struct GoldenCorpusTests {
  @Test(arguments: [
    "phase-1-golden",
    "phase-2-percentages",
    "phase-2-conversions",
    "phase-2-ambiguities",
  ])
  func matchesVersionedCorpus(named fixture: String) throws {
    let corpus = try loadFixture(GoldenCorpus.self, named: fixture)
    #expect(corpus.schemaVersion == 1)
    let context = try fixedContext()
    let engine = CalculationEngine()
    let formatter = ResultFormatter(context: context)

    for testCase in corpus.cases {
      let actual = try outcome(
        for: testCase.expression,
        engine: engine,
        formatter: formatter,
        context: context
      )
      #expect(
        actual == testCase.expected,
        "\(fixture) case failed: \(testCase.name)"
      )
    }
  }
}

@Suite
struct ArithmeticPropertyTests {
  @Test
  func exactIntegerArithmeticObeysCoreProperties() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    var generator = SeededGenerator(seed: 0x4741_4E49_5401)

    for _ in 0..<500 {
      let left = generator.integer(in: -10_000...10_000)
      var right = generator.integer(in: -10_000...10_000)
      if right == 0 {
        right = 1
      }

      let sum = try value(
        "(\(left)) + (\(right))",
        engine: engine,
        context: context
      )
      let reversedSum = try value(
        "(\(right)) + (\(left))",
        engine: engine,
        context: context
      )
      let product = try value(
        "(\(left)) * (\(right))",
        engine: engine,
        context: context
      )
      let reversedProduct = try value(
        "(\(right)) * (\(left))",
        engine: engine,
        context: context
      )
      let restored = try value(
        "((\(left)) + (\(right))) - (\(right))",
        engine: engine,
        context: context
      )
      let quotient = try value(
        "((\(left)) * (\(right))) / (\(right))",
        engine: engine,
        context: context
      )

      #expect(sum == reversedSum)
      #expect(product == reversedProduct)
      #expect(restored == .integer(IntegerValue(left)))
      #expect(quotient == .integer(IntegerValue(left)))
    }
  }

  @Test
  func insignificantWhitespaceDoesNotChangeMeaning() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    var generator = SeededGenerator(seed: 0x5748_4954_4553_5043)

    for _ in 0..<300 {
      let left = generator.integer(in: 0...10_000)
      let right = generator.integer(in: 1...10_000)
      let compact = "\(left)+\(right)*2"
      let spaced = "  \(left) + \(right) * 2  "

      #expect(
        try value(compact, engine: engine, context: context)
          == value(spaced, engine: engine, context: context)
      )
    }
  }

  @Test
  func rationalAndDecimalIdentitiesRemainExact() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    var generator = SeededGenerator(seed: 0x5241_5444_4543_3101)

    for _ in 0..<250 {
      let left = generator.integer(in: -1_000...1_000)
      let right = generator.integer(in: -1_000...1_000)
      let denominator = generator.integer(in: 1...100)
      let rationalSum = try value(
        "(\(left) / \(denominator)) + (\(right) / \(denominator))",
        engine: engine,
        context: context
      )
      let expectedRational = try RationalValue(
        numerator: IntegerValue(left + right),
        denominator: IntegerValue(denominator)
      )
      let expectedSum: NumericValue =
        expectedRational.denominator == IntegerValue(1)
        ? .integer(expectedRational.numerator)
        : .rational(expectedRational)
      #expect(rationalSum == expectedSum)

      let scale = generator.integer(in: 1...4)
      let leftDecimal = exactDecimalLiteral(
        coefficient: left,
        scale: scale
      )
      let rightDecimal = exactDecimalLiteral(
        coefficient: right,
        scale: scale
      )
      let restored = try value(
        "(\(leftDecimal) + \(rightDecimal)) - \(rightDecimal)",
        engine: engine,
        context: context
      )
      #expect(
        restored
          == .decimal(
            try DecimalValue(
              coefficient: IntegerValue(left),
              scale: scale
            )
          )
      )
    }
  }

  @Test
  func canonicalExactFormattingRoundTrips() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    let formatter = NumericResultFormatter(context: context)
    let expressions = [
      "-12345678901234567890",
      "1 / 7",
      "12.3400",
      "0xff * 0b101",
      "2^-20",
    ]

    for expression in expressions {
      let original = try value(expression, engine: engine, context: context)
      let formatted = try formatter.format(original)
      #expect(!formatted.isApproximate)
      #expect(
        try value(
          formatted.fullPrecision,
          engine: engine,
          context: context
        ) == original
      )
    }
  }

  @Test
  func boundedIntegersMatchNativeArithmeticDifferentially() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    var generator = SeededGenerator(seed: 0x4449_4646_494E_5431)

    for _ in 0..<1_000 {
      let left = Int64(generator.integer(in: -1_000_000_000...1_000_000_000))
      var right = Int64(
        generator.integer(in: -1_000_000_000...1_000_000_000)
      )
      if right == 0 {
        right = 1
      }

      #expect(
        try value("\(left) + \(right)", engine: engine, context: context)
          == .integer(try IntegerValue(String(left + right)))
      )
      #expect(
        try value("\(left) - \(right)", engine: engine, context: context)
          == .integer(try IntegerValue(String(left - right)))
      )
      #expect(
        try value("\(left) * \(right)", engine: engine, context: context)
          == .integer(try IntegerValue(String(left * right)))
      )

      let divisor = greatestCommonDivisor(abs(left), abs(right))
      let denominatorSign: Int64 = right < 0 ? -1 : 1
      let expectedNumerator = left / divisor * denominatorSign
      let expectedDenominator = abs(right) / divisor
      let expectedDivision =
        expectedDenominator == 1
        ? String(expectedNumerator)
        : "\(expectedNumerator)/\(expectedDenominator)"
      let division = try value(
        "\(left) / \(right)",
        engine: engine,
        context: context
      )
      #expect(
        try NumericResultFormatter(context: context).format(division)
          .fullPrecision == expectedDivision
      )
    }
  }

  @Test
  func numericBoundaryFuzzPreservesExactnessAndEnforcesBitLimits() throws {
    let context = try fixedContext()
    let engine = CalculationEngine()
    var generator = SeededGenerator(seed: 0x424F_554E_4441_5259)

    for _ in 0..<500 {
      let bit = generator.integer(in: 2...62)
      let delta = generator.integer(in: -1...1)
      let boundary = (UInt64(1) << UInt64(bit)) + UInt64(delta + 1) - 1
      let expected = boundary + 1
      #expect(
        try value(
          "\(boundary) + 1",
          engine: engine,
          context: context
        ) == .integer(try IntegerValue(String(expected)))
      )
    }

    for maximumBits in 2...63 {
      let boundary = UInt64(1) << UInt64(maximumBits - 1)
      let limits = EvaluationLimits(maximumIntegerBits: maximumBits)
      let accepted = CalculationEngine(evaluationLimits: limits).evaluate(
        String(boundary),
        context: context
      )
      #expect(
        accepted
          == .value(.number(.integer(try IntegerValue(String(boundary)))))
      )

      guard
        case .evaluationFailure(let error) = CalculationEngine(
          evaluationLimits: limits
        ).evaluate("\(boundary) * 2", context: context)
      else {
        Issue.record("Expected bit-limit failure at \(maximumBits) bits")
        continue
      }
      #expect(error.context == .resourceLimit(.integerBits))
      #expect(!error.ranges.isEmpty)
    }
  }
}

@Suite
struct ParserFuzzSmokeTests {
  @Test
  func corpusAndSeededUnicodeInputsNeverTrapOrEscapeRanges() throws {
    let corpus = try loadFixture([String].self, named: "parser-fuzz-seeds")
    let context = try fixedContext()
    let engine = CalculationEngine(
      syntaxLimits: SyntaxLimits(
        maximumSourceUTF8Length: 512,
        maximumTokenCount: 256,
        maximumParseDepth: 32
      )
    )
    let formatter = ResultFormatter(
      context: context,
      limits: FormattingLimits(maximumCharacters: 2_048)
    )
    var inputs = corpus
    var generator = SeededGenerator(seed: 0x4655_5A5A_5048_3101)
    let fragments = [
      "0", "1", "9", ".", ",", "+", "-", "*", "/", "^", "(", ")", ";",
      "e", "π", "sqrt", "root", "m", "kg", "°C", "·", "²", "³",
      "in", "into", "١", "२", "９", "é", "\u{301}", "💯",
      "\u{200D}", "\u{202E}", "\r", "\n", " ",
    ]
    for _ in 0..<1_000 {
      let count = generator.integer(in: 0...80)
      var source = ""
      for _ in 0..<count {
        source += fragments[generator.integer(in: 0...(fragments.count - 1))]
      }
      inputs.append(source)
    }

    for source in inputs {
      switch engine.evaluate(source, context: context) {
      case .value(let result):
        _ = try? formatter.format(result)
      case .syntaxFailure(let diagnostics):
        #expect(!diagnostics.isEmpty)
        for diagnostic in diagnostics {
          expectValid(
            diagnostic.range,
            in: source
          )
          #expect(!diagnostic.messageKey.isEmpty)
        }
      case .evaluationFailure(let error):
        #expect(error.code != EngineErrorCode.internalFailure)
        #expect(!error.messageKey.isEmpty)
        #expect(!error.ranges.isEmpty)
        for range in error.ranges {
          expectValid(
            range,
            in: source
          )
        }
      }
    }
  }
}

private struct GoldenCorpus: Decodable {
  let schemaVersion: Int
  let cases: [GoldenCase]
}

private struct GoldenCase: Decodable {
  let name: String
  let expression: String
  let expected: GoldenOutcome
}

private struct GoldenOutcome: Codable, Equatable {
  let status: String
  let display: String?
  let fullPrecision: String?
  let approximate: Bool?
  let code: String?
  let messageKey: String?
  let message: String?
  let lowerBound: Int?
  let upperBound: Int?
}

private func outcome(
  for expression: String,
  engine: CalculationEngine,
  formatter: ResultFormatter,
  context: EvaluationContext
) throws -> GoldenOutcome {
  switch engine.evaluate(expression, context: context) {
  case .value(let result):
    let formatted = try formatter.format(result)
    return GoldenOutcome(
      status: "value",
      display: formatted.display,
      fullPrecision: formatted.fullPrecision,
      approximate: formatted.isApproximate,
      code: nil,
      messageKey: nil,
      message: nil,
      lowerBound: nil,
      upperBound: nil
    )
  case .syntaxFailure(let diagnostics):
    let diagnostic = try #require(diagnostics.first)
    let message = DiagnosticFormatter(context: context).format(diagnostic).message
    return GoldenOutcome(
      status: "syntaxFailure",
      display: nil,
      fullPrecision: nil,
      approximate: nil,
      code: diagnostic.code.rawValue,
      messageKey: diagnostic.messageKey,
      message: message,
      lowerBound: diagnostic.range.lowerBound,
      upperBound: diagnostic.range.upperBound
    )
  case .evaluationFailure(let error):
    let range = error.ranges.first
    let message = DiagnosticFormatter(context: context).format(error).message
    return GoldenOutcome(
      status: "evaluationFailure",
      display: nil,
      fullPrecision: nil,
      approximate: nil,
      code: error.code.rawValue,
      messageKey: error.messageKey,
      message: message,
      lowerBound: range?.lowerBound,
      upperBound: range?.upperBound
    )
  }
}

private func value(
  _ expression: String,
  engine: CalculationEngine,
  context: EvaluationContext
) throws -> NumericValue {
  guard case .value(let result) = engine.evaluate(expression, context: context)
  else {
    Issue.record("Expected value for \(expression)")
    throw CorpusFailure.expectedValue
  }
  guard case .number(let number) = result else {
    Issue.record("Expected numeric value for \(expression)")
    throw CorpusFailure.expectedValue
  }
  return number
}

private func expectValid(
  _ range: SourceRange,
  in source: String
) {
  let byteCount = source.utf8.count
  let graphemeCount = source.count
  #expect(range.lowerBound >= 0)
  #expect(range.lowerBound <= range.upperBound)
  #expect(range.upperBound <= byteCount)
  #expect(range.graphemeLowerBound >= 0)
  #expect(range.graphemeLowerBound <= range.graphemeUpperBound)
  #expect(range.graphemeUpperBound <= graphemeCount)
  #expect(range.text(in: source) != nil)

  guard
    range.graphemeLowerBound <= graphemeCount,
    range.graphemeUpperBound <= graphemeCount
  else {
    return
  }
  let lowerIndex = source.index(
    source.startIndex,
    offsetBy: range.graphemeLowerBound
  )
  let upperIndex = source.index(
    source.startIndex,
    offsetBy: range.graphemeUpperBound
  )
  let lowerUTF8 = lowerIndex.samePosition(in: source.utf8)
  let upperUTF8 = upperIndex.samePosition(in: source.utf8)
  #expect(
    lowerUTF8.map {
      source.utf8.distance(from: source.utf8.startIndex, to: $0)
    } == range.lowerBound
  )
  #expect(
    upperUTF8.map {
      source.utf8.distance(from: source.utf8.startIndex, to: $0)
    } == range.upperBound
  )
}

func fixedContext() throws -> EvaluationContext {
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

private func loadFixture<Value: Decodable>(
  _ type: Value.Type,
  named name: String
) throws -> Value {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json")
  )
  return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
}

private func exactDecimalLiteral(coefficient: Int, scale: Int) -> String {
  let sign = coefficient < 0 ? "-" : ""
  let digits = String(abs(coefficient))
  if digits.count <= scale {
    return sign + "0."
      + String(
        repeating: "0",
        count: scale - digits.count
      ) + digits
  }
  let split = digits.index(digits.endIndex, offsetBy: -scale)
  return sign + digits[..<split] + "." + digits[split...]
}

private func greatestCommonDivisor(_ left: Int64, _ right: Int64) -> Int64 {
  var lhs = left
  var rhs = right
  while rhs != 0 {
    (lhs, rhs) = (rhs, lhs % rhs)
  }
  return lhs
}

enum CorpusFailure: Error {
  case expectedValue
}

struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func integer(in range: ClosedRange<Int>) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let width = UInt64(range.upperBound - range.lowerBound + 1)
    return range.lowerBound + Int(state % width)
  }
}
