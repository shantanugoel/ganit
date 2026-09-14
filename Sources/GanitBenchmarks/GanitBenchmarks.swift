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
      iterations > 0
    {
      runParserBenchmark(iterations: iterations)
      return
    }

    let message = """
      usage:
        GanitBenchmarks --list
        GanitBenchmarks --parser <positive-iteration-count>

      The parser benchmark records observations without applying a pass threshold.

      """
    FileHandle.standardError.write(Data(message.utf8))
    exit(EX_USAGE)
  }

  private static func listFixtureTargets() {
    print("fixture\ttarget\tstatus\tpurpose")
    for fixture in fixtureTargets {
      print(
        "\(fixture.name)\t\(fixture.target)\tunavailable\t\(fixture.purpose)"
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
}
