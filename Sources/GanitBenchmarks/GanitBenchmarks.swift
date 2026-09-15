import Darwin
import Foundation
import GanitEngine

private struct FixtureTarget: Sendable {
  let name: String
  let target: String
  let purpose: String
}

@main
private enum GanitBenchmarks {
  private static let maximumIterations = 100_000
  private static let maximumEngineIterations = 10_000

  private static let parserExpressions = [
    "1 + 2 * 3",
    "(12 + 8) / 5",
    "-2^8",
    "sqrt(144)",
    "max(1, 2, 3)",
    "0xff + 0b1010",
    "3.50e-2 * 1000",
    "π * 2",
    "12 × 4 ÷ 3",
    "abs(min(-5, -2))",
  ]

  private static let fixtureTargets = [
    FixtureTarget(
      name: "launch-expressions",
      target: "200 expressions",
      purpose: "Representative single-expression evaluation"
    ),
    FixtureTarget(
      name: "ambiguity-invalid",
      target: "200 expressions",
      purpose: "Ambiguous and invalid input handling"
    ),
    FixtureTarget(
      name: "mixed-sheet",
      target: "1,000 lines",
      purpose: "Ordinary incremental sheet evaluation"
    ),
    FixtureTarget(
      name: "independent-sheet",
      target: "10,000 lines",
      purpose: "Large independent-line evaluation"
    ),
    FixtureTarget(
      name: "chained-dependency-sheet",
      target: "10,000 lines",
      purpose: "Large transitive dependency evaluation"
    ),
    FixtureTarget(
      name: "unicode-rtl-ime",
      target: "coverage corpus",
      purpose: "Unicode, bidirectional text, and marked-text source"
    ),
    FixtureTarget(
      name: "currency-date-frozen",
      target: "coverage corpus",
      purpose: "Frozen evaluation context and data snapshots"
    ),
  ]

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--list"] {
      listFixtureTargets()
      return
    }

    if arguments.count == 2,
      arguments[0] == "--parser",
      let iterations = Int(arguments[1]),
      (1...maximumIterations).contains(iterations)
    {
      runParserBenchmark(iterations: iterations)
      return
    }

    if arguments.count == 2,
      arguments[0] == "--engine",
      let iterations = Int(arguments[1]),
      (1...maximumEngineIterations).contains(iterations)
    {
      runEngineBenchmark(iterations: iterations)
      return
    }

    let message = """
      usage:
        GanitBenchmarks --list
        GanitBenchmarks --parser <iteration-count: 1...\(maximumIterations)>
        GanitBenchmarks --engine <iteration-count: 1...\(maximumEngineIterations)>

      Benchmarks record observations without applying a pass threshold.

      """
    FileHandle.standardError.write(Data(message.utf8))
    exit(EX_USAGE)
  }

  private static func listFixtureTargets() {
    print("fixture\ttarget\tstatus\tpurpose")
    for fixture in fixtureTargets {
      let status = fixture.name == "launch-expressions" ? "available" : "unavailable"
      print(
        "\(fixture.name)\t\(fixture.target)\t\(status)\t\(fixture.purpose)"
      )
    }
  }

  private static func runParserBenchmark(iterations: Int) {
    for source in parserExpressions {
      guard Parser(source: source).parse().diagnostics.isEmpty else {
        let message = "Parser benchmark fixture failed to parse: \(source)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EX_SOFTWARE)
      }
    }

    let clock = ContinuousClock()
    let start = clock.now
    var checksum = 0

    for _ in 0..<iterations {
      for source in parserExpressions {
        let result = Parser(source: source).parse()
        guard let expression = result.expression, result.diagnostics.isEmpty else {
          let message = "Parser benchmark became nondeterministic.\n"
          FileHandle.standardError.write(Data(message.utf8))
          exit(EX_SOFTWARE)
        }
        checksum &+= expression.range.utf8Length
      }
    }

    let components = start.duration(to: clock.now).components
    let elapsedNanoseconds =
      Double(components.seconds) * 1_000_000_000
      + Double(components.attoseconds) / 1_000_000_000
    let expressionCount = iterations * parserExpressions.count

    guard expressionCount > 0 else {
      let message = """
        Parser benchmark did not execute any expressions.

        """
      FileHandle.standardError.write(Data(message.utf8))
      exit(EX_SOFTWARE)
    }

    print("expressions=\(expressionCount)")
    print("elapsed_ms=\(String(format: "%.3f", elapsedNanoseconds / 1_000_000))")
    print(
      "nanoseconds_per_expression="
        + String(format: "%.3f", elapsedNanoseconds / Double(expressionCount))
    )
    print("checksum=\(checksum)")
  }

  private static func runEngineBenchmark(iterations: Int) {
    let expressions = engineExpressions()
    guard expressions.count == 200 else {
      fail("Engine benchmark must contain exactly 200 expressions.")
    }
    let context: EvaluationContext
    do {
      context = try benchmarkContext()
    } catch {
      fail("Engine benchmark context is invalid.")
    }
    let engine = CalculationEngine()
    let expectedValues = expressions.map { source -> EngineValue in
      guard case .value(let value) = engine.evaluate(source, context: context)
      else {
        fail("Engine benchmark fixture failed to evaluate: \(source)")
      }
      return value
    }
    let (expressionCount, overflow) = iterations.multipliedReportingOverflow(
      by: expressions.count
    )
    guard !overflow, expressionCount > 0 else {
      fail("Engine benchmark expression count overflowed.")
    }

    let clock = ContinuousClock()
    let start = clock.now
    var checksum = 0
    var latencySamples: [Double] = []
    latencySamples.reserveCapacity(expressionCount)
    for _ in 0..<iterations {
      for (index, source) in expressions.enumerated() {
        let expressionStart = clock.now
        switch engine.evaluate(source, context: context) {
        case .value(let value) where value == expectedValues[index]:
          checksum &+= valueTag(value) + source.utf8.count
        case .value:
          fail("Engine benchmark result changed during measurement.")
        case .syntaxFailure, .evaluationFailure:
          fail("Engine benchmark became nondeterministic.")
        }
        latencySamples.append(
          nanoseconds(expressionStart.duration(to: clock.now))
        )
      }
    }
    let elapsedNanoseconds = nanoseconds(start.duration(to: clock.now))
    latencySamples.sort()

    print("expressions=\(expressionCount)")
    print("elapsed_ms=\(String(format: "%.3f", elapsedNanoseconds / 1_000_000))")
    print(
      "nanoseconds_per_expression="
        + String(format: "%.3f", elapsedNanoseconds / Double(expressionCount))
    )
    print(
      "p50_nanoseconds="
        + String(format: "%.3f", nearestRank(0.50, in: latencySamples))
    )
    print(
      "p95_nanoseconds="
        + String(format: "%.3f", nearestRank(0.95, in: latencySamples))
    )
    print("fixture_checksum=\(fixtureChecksum(expressions))")
    print("checksum=\(checksum)")
  }

  private static func engineExpressions() -> [String] {
    (1...20).flatMap { value in
      [
        "\(value) + \(value + 1) * 3",
        "(\(value * 7) + \(value)) / \(value + 1)",
        "\(value).25 + \(value + 1).75",
        "2^\(value)",
        "sqrt(\(value * value))",
        "root(\(value * value * value), 3)",
        "0x\(String(value * 17, radix: 16)) + 0b\(String(value, radix: 2))",
        "max(\(value), \(value + 2), \(value - 1))"
          + " - min(\(value), \(value + 2), \(value - 1))",
        "\(value)(2 + 3)",
        transcendentalExpression(for: value),
      ]
    }
  }

  private static func transcendentalExpression(for value: Int) -> String {
    switch value % 4 {
    case 0:
      return "sin(\(value))"
    case 1:
      return "ln(\(value + 1))"
    case 2:
      return "sqrt(\(value))"
    default:
      return "π * \(value)"
    }
  }

  private static func benchmarkContext() throws -> EvaluationContext {
    guard let timeZone = TimeZone(identifier: "UTC") else {
      fail("UTC time zone is unavailable.")
    }
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

  private static func valueTag(_ value: EngineValue) -> Int {
    switch value {
    case .number(let number):
      return valueTag(number)
    case .percentage:
      return 5
    }
  }

  private static func valueTag(_ value: NumericValue) -> Int {
    switch value {
    case .integer:
      return 1
    case .rational:
      return 2
    case .decimal:
      return 3
    case .approximate:
      return 4
    }
  }

  private static func fixtureChecksum(_ expressions: [String]) -> String {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for byte in expressions.joined(separator: "\n").utf8 {
      checksum ^= UInt64(byte)
      checksum &*= 1_099_511_628_211
    }
    return String(checksum, radix: 16)
  }

  private static func nanoseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000_000_000
      + Double(components.attoseconds) / 1_000_000_000
  }

  private static func nearestRank(
    _ percentile: Double,
    in sortedSamples: [Double]
  ) -> Double {
    let index = Int(ceil(percentile * Double(sortedSamples.count))) - 1
    return sortedSamples[index]
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EX_SOFTWARE)
  }
}
