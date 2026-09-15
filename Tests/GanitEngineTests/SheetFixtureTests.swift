import Foundation
import Testing

@testable import GanitEngine

/// Affected-only evaluation over the checked-in benchmark sheets.
@Suite
struct SheetFixtureTests {
  @Test
  func mixedSheetIsOrdinaryAndEditsStayInTheirBlock() throws {
    var sheet = try fixture("mixed-sheet-1k")
    var calculator = SheetCalculator()
    let context = try sheetContext()
    let first = try calculator.evaluate(sheet, context: context)

    #expect(sheet.lines.count == 1_001)
    let failures = first.lines.enumerated().compactMap { index, line -> String? in
      switch line.result {
      case .syntaxFailure, .evaluationFailure:
        return "\(index + 1): \(sheet.lines[index].text)"
      case .value, nil:
        return nil
      }
    }
    #expect(failures.isEmpty, "\(failures)")

    // Section 21, `Meals:` (line 511): the subtotal, `line 511 + 1`, the
    // `previous` that reads it, and the block aggregates depend on it.
    let meals = 510
    try replaceNumber(in: &sheet, line: meals, with: "Meals: 1 * 42.50")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(
      evaluation.evaluatedLineIDs
        == [510, 512, 513, 514, 515, 516, 517, 518].map { sheet.lines[$0].id }
    )
  }

  @Test
  func independentSheetEditEvaluatesOneLine() throws {
    var sheet = try fixture("independent-sheet-10k")
    var calculator = SheetCalculator()
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    try replaceNumber(in: &sheet, line: 5_000, with: "1 + 1")
    let evaluation = try calculator.evaluate(sheet, context: context)

    #expect(sheet.lines.count == 10_001)
    #expect(evaluation.evaluatedLineIDs == [sheet.lines[5_000].id])
  }

  @Test
  func chainedSheetPropagatesOnlyWhileValuesChange() throws {
    var sheet = try fixture("chained-sheet-10k")
    var calculator = SheetCalculator()
    let context = try sheetContext()
    _ = try calculator.evaluate(sheet, context: context)

    // A leaf edit touches one line.
    try replaceNumber(in: &sheet, line: 9_999, with: "v9999 = v9998 + 100")
    var evaluation = try calculator.evaluate(sheet, context: context)
    #expect(evaluation.evaluatedLineIDs == [sheet.lines[9_999].id])

    // A value change in the middle re-evaluates exactly the chain below it.
    try replaceNumber(in: &sheet, line: 9_000, with: "v9000 = v8999 + 100")
    evaluation = try calculator.evaluate(sheet, context: context)
    #expect(evaluation.evaluatedLineIDs == sheet.lines[9_000..<10_000].map(\.id))
    // Dependents' text is unchanged, so only the edited line is reparsed.
    #expect(evaluation.parsedLineIDs == [sheet.lines[9_000].id])

    // Rewriting a line without changing its value stops propagation there.
    try replaceNumber(in: &sheet, line: 9_000, with: "v9000 = 100 + v8999")
    evaluation = try calculator.evaluate(sheet, context: context)
    #expect(evaluation.evaluatedLineIDs == [sheet.lines[9_000].id])
  }

  private func fixture(_ name: String) throws -> SheetSource {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Benchmarks/Fixtures/\(name).txt")
    return SheetSource(try String(contentsOf: url, encoding: .utf8))
  }

  private func replaceNumber(
    in sheet: inout SheetSource,
    line index: Int,
    with text: String
  ) throws {
    let range = sheet.lines[index].range
    sheet.replace(utf8Range: range.lowerBound..<range.upperBound, with: text)
  }
}
