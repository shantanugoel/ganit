import Foundation
import Testing

@testable import GanitEngine

@Suite
struct SheetCalculatorTests {
  @Test
  func firstGenerationEvaluatesEveryExpression() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("# Costs\nrent = 2100\nfood = 500\n\n// note\ntotal")

    let evaluation = try calculator.evaluate(sheet, context: try sheetContext())

    #expect(evaluation.generation == 1)
    #expect(evaluation.evaluatedLineIDs == [1, 2, 5].map { sheet.lines[$0].id })
  }

  @Test
  func recalculatesClockReadingLinesOnlyAtTheirBoundaries() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("a = 1\nstart = today\nnow\nstart + 1 day\na + 1")
    let ids = sheet.lines.map(\.id)
    let context = try sheetContext().at(Date(timeIntervalSince1970: 1_700_000_000.25))

    let first = try calculator.evaluate(sheet, context: context)
    #expect(first.nextRecalculation == Date(timeIntervalSince1970: 1_700_000_001))

    let sameSecond = try calculator.evaluate(
      sheet, context: context.at(Date(timeIntervalSince1970: 1_700_000_000.75)))
    #expect(sameSecond.evaluatedLineIDs.isEmpty)

    let nextSecond = try calculator.evaluate(
      sheet, context: context.at(Date(timeIntervalSince1970: 1_700_000_001)))
    #expect(nextSecond.evaluatedLineIDs == [ids[2]])
    #expect(nextSecond.nextRecalculation == Date(timeIntervalSince1970: 1_700_000_002))

    // Midnight UTC after the frozen day re-evaluates `today` and its dependent.
    let nextDay = try calculator.evaluate(
      sheet, context: context.at(Date(timeIntervalSince1970: 1_700_006_400)))
    #expect(nextDay.evaluatedLineIDs == [ids[1], ids[2], ids[3]])
  }

  @Test
  func schedulesDayBoundariesInTheContextZoneAndNothingWithoutClockReads() throws {
    var calculator = SheetCalculator()
    let tokyo = try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 1_700_000_000),
      calendar: Calendar(identifier: .gregorian),
      timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))
    )
    let dated = try calculator.evaluate(SheetSource("next friday\n3 days ago"), context: tokyo)
    // Midnight on Nov 16, 2023 in Tokyo.
    #expect(dated.nextRecalculation == Date(timeIntervalSince1970: 1_700_060_400))

    let plain = SheetSource("1 + 1\n2024-03-09")
    #expect(try calculator.evaluate(plain, context: tokyo).nextRecalculation == nil)
    let later = try calculator.evaluate(plain, context: tokyo.at(.distantFuture))
    #expect(later.evaluatedLineIDs.isEmpty)
  }

  @Test
  func unchangedSheetReusesEveryResult() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("a = 1\nb = a + 1\nline 2 * 2\nsum")
    let first = try calculator.evaluate(sheet, context: try sheetContext())

    let second = try calculator.evaluate(sheet, context: try sheetContext())

    #expect(second.generation == 2)
    #expect(second.evaluatedLineIDs.isEmpty)
    #expect(second.lines == first.lines)
  }

  @Test
  func editingAVariableReevaluatesOnlyItsDependents() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("a = 1\nb = 10\nc = a + 1\nd = b + 1\nc * 2\n\n5\nsum")
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    sheet.replace(utf8Range: 4..<5, with: "2")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(evaluation.evaluatedLineIDs == [0, 2, 4].map { sheet.lines[$0].id })
    #expect(evaluation.parsedLineIDs == [sheet.lines[0].id])
    #expect(try summary(evaluation)[4] == "6")
  }

  @Test
  func editsAboveShiftNoRangesAndReuseUnaffectedLines() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("1\n2 +\nx = 3")
    let context = try sheetContext()
    let first = try calculator.evaluate(sheet, context: context)

    sheet.replace(utf8Range: 0..<1, with: "100")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(evaluation.evaluatedLineIDs == [sheet.lines[0].id])
    #expect(evaluation.lines[1] == first.lines[1])
    #expect(evaluation.lines[2] == first.lines[2])
  }

  @Test
  func referencesTrackTheOutcomesTheyRead() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("1\n2\nsubtotal\n3\nprevious\nline 1\n\ncount")
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    // Changing line 4 affects `previous` and nothing else: the subtotal,
    // `line 1`, and the next block's count read other outcomes.
    sheet.replace(utf8Range: 13..<14, with: "4")
    var evaluation = try calculator.evaluate(sheet, context: context)
    #expect(evaluation.evaluatedLineIDs == [3, 4].map { sheet.lines[$0].id })

    // Inserting a line above shifts which line `line 1` names.
    sheet.replace(utf8Range: 0..<0, with: "7\n")
    evaluation = try calculator.evaluate(sheet, context: context)
    #expect(evaluation.evaluatedLineIDs.contains(sheet.lines[6].id))
    #expect(try summary(evaluation)[6] == "7")
  }

  @Test
  func declaringAMultiWordNameReparsesLinesThatCanUseIt() throws {
    var calculator = SheetCalculator()
    var sheet = SheetSource("rent = 1\nmonthly = 2\n\nmonthly rent\nrent")
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    sheet.replace(utf8Range: 21..<21, with: "monthly rent = 5\n")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(evaluation.evaluatedLineIDs == [2, 4].map { sheet.lines[$0].id })
    #expect(try summary(evaluation)[4] == "5")
    #expect(try summary(evaluation)[5] == "1")
  }

  @Test
  func incrementalResultsMatchFreshEvaluationAcrossRandomEdits() throws {
    var generator = SeededGenerator(seed: 0x494E_4352_4501)
    let fragments = [
      "\n", "\n\n", "---\n", "# h\n", "// c\n", "a = ", "a b = ", "b", "a b", "a",
      " + ", "1", "2%", " km", " in m", "line 2", "prev", "sum", "subtotal", "avg",
      "median", "count", "Label: ", "x",
    ]
    let context = try sheetContext()
    var sheet = SheetSource("a = 1\nb = 2\na b = 3\na b + b\nsum")
    var calculator = SheetCalculator()

    for _ in 0..<600 {
      let bytes = Array(sheet.text.utf8)
      var lower = generator.next(below: bytes.count + 1)
      var upper = min(bytes.count, lower + generator.next(below: 4))
      if generator.next(below: 3) == 0 {
        upper = lower
      }
      while lower > 0, lower < bytes.count, bytes[lower] & 0b1100_0000 == 0b1000_0000 {
        lower -= 1
      }
      while upper < bytes.count, bytes[upper] & 0b1100_0000 == 0b1000_0000 {
        upper += 1
      }
      sheet.replace(
        utf8Range: lower..<upper,
        with: fragments[generator.next(below: fragments.count)]
      )

      var fresh = SheetCalculator()
      #expect(
        try calculator.evaluate(sheet, context: context).lines
          == fresh.evaluate(sheet, context: context).lines,
        "\(sheet.text.debugDescription)"
      )
    }
  }

  @Test
  func contextChangesInvalidateEverything() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("1\n2")
    _ = try calculator.evaluate(sheet, context: try sheetContext())

    let evaluation = try calculator.evaluate(
      sheet,
      context: try sheetContext(angleMode: .degrees)
    )

    #expect(evaluation.evaluatedLineIDs == sheet.lines.map(\.id))
  }

  @Test
  func cancellationStopsWithoutAnEvaluation() async throws {
    let context = try sheetContext()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var calculator = SheetCalculator()
      return try calculator.evaluate(SheetSource("1"), context: context)
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  private func summary(_ evaluation: SheetEvaluation) throws -> [String?] {
    evaluation.lines.map {
      guard case .value(.number(.integer(let integer))) = $0.result else {
        return nil
      }
      return integer.canonicalDigits
    }
  }
}
