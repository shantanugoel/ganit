import AppKit
import Darwin
import Foundation
import GanitEditorUI
import GanitEngine
import GanitQuickUI

private struct FixtureTarget: Sendable {
  let name: String
  let target: String
  let purpose: String
}

/// A checked-in sheet and the one-line edit that simulates a keystroke.
private struct SheetBenchmark: Sendable {
  let fixture: String
  let file: String
  let editedLine: Int
  let replacements: [String]
}

@main
private enum GanitBenchmarks {
  private static let maximumIterations = 100_000
  private static let maximumEngineIterations = 10_000
  private static let maximumSheetIterations = 10_000

  private static let sheetBenchmarks = [
    SheetBenchmark(
      fixture: "mixed-sheet",
      file: "mixed-sheet-1k",
      editedLine: 510,
      replacements: ["Meals: 64 * 42.50", "Meals: 63 * 42.50"]
    ),
    SheetBenchmark(
      fixture: "independent-sheet",
      file: "independent-sheet-10k",
      editedLine: 5_000,
      replacements: ["1 + 2", "1 + 1"]
    ),
    SheetBenchmark(
      fixture: "chained-dependency-sheet",
      file: "chained-sheet-10k",
      editedLine: 0,
      replacements: ["v0 = 2", "v0 = 1"]
    ),
  ]

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

    if arguments.count == 3,
      arguments[0] == "--sheet",
      let benchmark = sheetBenchmarks.first(where: { $0.fixture == arguments[1] }),
      let iterations = Int(arguments[2]),
      (1...maximumSheetIterations).contains(iterations)
    {
      runSheetBenchmark(benchmark, iterations: iterations)
      return
    }

    if arguments.count == 3,
      arguments[0] == "--editor",
      let benchmark = sheetBenchmarks.first(where: { $0.fixture == arguments[1] }),
      let iterations = Int(arguments[2]),
      (1...maximumSheetIterations).contains(iterations)
    {
      MainActor.assumeIsolated {
        runEditorBenchmark(benchmark, iterations: iterations)
      }
      return
    }

    if arguments.count == 2,
      arguments[0] == "--quick",
      let iterations = Int(arguments[1]),
      (1...maximumSheetIterations).contains(iterations)
    {
      MainActor.assumeIsolated {
        runQuickBenchmark(iterations: iterations)
      }
      return
    }

    let message = """
      usage:
        GanitBenchmarks --list
        GanitBenchmarks --parser <iteration-count: 1...\(maximumIterations)>
        GanitBenchmarks --engine <iteration-count: 1...\(maximumEngineIterations)>
        GanitBenchmarks --sheet <\(sheetBenchmarks.map(\.fixture).joined(separator: "|"))> \
      <edit-count: 1...\(maximumSheetIterations)>
        GanitBenchmarks --quick <show-count: 1...\(maximumSheetIterations)>
        GanitBenchmarks --editor <\(sheetBenchmarks.map(\.fixture).joined(separator: "|"))> \
      <edit-count: 1...\(maximumSheetIterations)>

      Benchmarks record observations without applying a pass threshold.

      """
    FileHandle.standardError.write(Data(message.utf8))
    exit(EX_USAGE)
  }

  private static func listFixtureTargets() {
    print("fixture\ttarget\tstatus\tpurpose")
    for fixture in fixtureTargets {
      let isAvailable =
        fixture.name == "launch-expressions"
        || sheetBenchmarks.contains { $0.fixture == fixture.name }
      let status = isAvailable ? "available" : "unavailable"
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

  /// Times a full first evaluation, then alternating one-line edits. Each
  /// edit sample covers `SheetSource.replace` and incremental evaluation.
  private static func runSheetBenchmark(_ benchmark: SheetBenchmark, iterations: Int) {
    let text = sheetFixtureText(benchmark)
    let context: EvaluationContext
    do {
      context = try benchmarkContext()
    } catch {
      fail("Sheet benchmark context is invalid.")
    }
    let clock = ContinuousClock()

    // Warm up code paths with a throwaway calculator.
    var warmup = SheetCalculator()
    _ = try? warmup.evaluate(SheetSource(text), context: context)

    var sheet = SheetSource(text)
    var calculator = SheetCalculator()
    let fullStart = clock.now
    guard let first = try? calculator.evaluate(sheet, context: context) else {
      fail("Sheet benchmark evaluation was cancelled.")
    }
    let fullNanoseconds = nanoseconds(fullStart.duration(to: clock.now))
    let failures = first.lines.filter {
      switch $0.result {
      case .syntaxFailure, .evaluationFailure:
        return true
      case .value, nil:
        return false
      }
    }
    guard failures.isEmpty else {
      fail("Sheet benchmark fixture has \(failures.count) failing lines.")
    }

    var evaluatedLines = 0
    var latencySamples: [Double] = []
    latencySamples.reserveCapacity(iterations)
    for iteration in 0..<iterations {
      let range = sheet.lines[benchmark.editedLine].range
      let replacement = benchmark.replacements[iteration % benchmark.replacements.count]
      let editStart = clock.now
      sheet.replace(utf8Range: range.lowerBound..<range.upperBound, with: replacement)
      guard let evaluation = try? calculator.evaluate(sheet, context: context) else {
        fail("Sheet benchmark evaluation was cancelled.")
      }
      latencySamples.append(nanoseconds(editStart.duration(to: clock.now)))
      evaluatedLines += evaluation.evaluatedLineIDs.count
    }
    latencySamples.sort()

    print("fixture=\(benchmark.fixture)")
    print("lines=\(sheet.lines.count)")
    print("full_evaluation_ms=\(String(format: "%.3f", fullNanoseconds / 1_000_000))")
    print("edits=\(iterations)")
    print("evaluated_lines_per_edit=\(evaluatedLines / iterations)")
    print(
      "p50_edit_ms="
        + String(format: "%.3f", nearestRank(0.50, in: latencySamples) / 1_000_000)
    )
    print(
      "p95_edit_ms="
        + String(format: "%.3f", nearestRank(0.95, in: latencySamples) / 1_000_000)
    )
    print("fixture_checksum=\(fixtureChecksum([text]))")
  }

  /// Times edits in a real sheet editor until their answers are drawn, as the
  /// editor reports them. Each edit replaces the benchmark line through the
  /// text view with its line scrolled into view.
  @MainActor
  private static func runEditorBenchmark(_ benchmark: SheetBenchmark, iterations: Int) {
    _ = NSApplication.shared
    let context: EvaluationContext
    do {
      context = try benchmarkContext()
    } catch {
      fail("Editor benchmark context is invalid.")
    }
    let editor = SheetEditorViewController(text: sheetFixtureText(benchmark), context: context)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = editor
    window.layoutIfNeeded()

    var latency: Duration?
    editor.editToAnswerHandler = { latency = $0 }
    func waitForAnswers() {
      let deadline = Date().addingTimeInterval(30)
      while latency == nil {
        guard Date() < deadline else {
          fail("Editor benchmark answers were not drawn.")
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
        window.displayIfNeeded()
      }
    }
    waitForAnswers()

    let textView = editor.textView
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for iteration in 0..<iterations {
      let string = textView.string as NSString
      var lineRange = NSRange(location: 0, length: 0)
      for _ in 0...benchmark.editedLine {
        lineRange = string.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0))
      }
      var contentsEnd = 0
      string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
      let range = NSRange(location: lineRange.location, length: contentsEnd - lineRange.location)
      textView.scrollRangeToVisible(range)
      window.displayIfNeeded()

      latency = nil
      textView.insertText(
        benchmark.replacements[iteration % benchmark.replacements.count],
        replacementRange: range
      )
      waitForAnswers()
      samples.append(nanoseconds(latency!))
    }
    samples.sort()

    print("fixture=\(benchmark.fixture)")
    print("edits=\(iterations)")
    print(
      "p50_edit_to_answer_ms=\(String(format: "%.3f", nearestRank(0.50, in: samples) / 1_000_000))")
    print(
      "p95_edit_to_answer_ms=\(String(format: "%.3f", nearestRank(0.95, in: samples) / 1_000_000))")
  }

  /// Times showing an already created Quick Ganit panel until it is drawn,
  /// with its text focused: the resident invocation path after the global
  /// shortcut handler runs.
  @MainActor
  private static func runQuickBenchmark(iterations: Int) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let context: EvaluationContext
    do {
      context = try benchmarkContext()
    } catch {
      fail("Quick benchmark context is invalid.")
    }
    let clock = ContinuousClock()
    let createStart = clock.now
    let controller = QuickPanelController(context: context)
    let creation = nanoseconds(createStart.duration(to: clock.now))
    guard let panel = controller.window else {
      fail("Quick panel has no window.")
    }
    controller.show()
    panel.displayIfNeeded()
    controller.hide()

    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
      let start = clock.now
      controller.show()
      panel.displayIfNeeded()
      guard panel.isVisible, panel.firstResponder === controller.editor.textView else {
        fail("Quick panel was not shown with its text focused.")
      }
      samples.append(nanoseconds(start.duration(to: clock.now)))
      controller.hide()
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    samples.sort()

    print("panel_creation_ms=\(String(format: "%.3f", creation / 1_000_000))")
    print("shows=\(iterations)")
    print("p50_show_ms=\(String(format: "%.3f", nearestRank(0.50, in: samples) / 1_000_000))")
    print("p95_show_ms=\(String(format: "%.3f", nearestRank(0.95, in: samples) / 1_000_000))")
  }

  private static func sheetFixtureText(_ benchmark: SheetBenchmark) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Benchmarks/Fixtures/\(benchmark.file).txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      fail("Sheet fixture is unreadable: \(url.path)")
    }
    return text
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
    case .quantity:
      return 6
    case .rate:
      return 7
    case .date, .time, .instant, .period:
      return 8
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
