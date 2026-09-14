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
    guard CommandLine.arguments.dropFirst() == ["--list"] else {
      let message = """
        No executable engine benchmarks exist before Phase 1.
        Use --list to inspect required fixture targets.

        """
      FileHandle.standardError.write(Data(message.utf8))
      exit(EX_USAGE)
    }

    print("fixture\ttarget\tstatus\tpurpose")
    for fixture in fixtureTargets {
      print(
        "\(fixture.name)\t\(fixture.target)\tunavailable\t\(fixture.purpose)"
      )
    }
  }
}
