import Foundation
import Testing

@testable import GanitEngine

/// One calculator evaluating a sheet edit by edit, as the editor's
/// scheduler does, so block reuse and incremental line caches are exercised.
private struct EditRun {
  var sheet: SheetSource
  var calculator = SheetCalculator()
  let context: EvaluationContext

  init(_ text: String, markdown: Bool = false) throws {
    sheet = SheetSource(text)
    context = try sheetContext(isMarkdownMode: markdown)
  }

  /// Replaces only the bytes that differ, keeping the other lines' IDs.
  mutating func evaluate(_ text: String) throws -> SheetEvaluation {
    let old = Array(sheet.text.utf8)
    let new = Array(text.utf8)
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix,
      old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
      suffix += 1
    }
    sheet.replace(
      utf8Range: prefix..<(old.count - suffix),
      with: String(decoding: new[prefix..<(new.count - suffix)], as: UTF8.self))
    #expect(sheet.text.utf8.elementsEqual(text.utf8))
    return try calculator.evaluate(sheet, context: context)
  }
}

/// Editing must never show a table's last valid projection for a block that
/// is now invalid: each generation reports its own diagnostics, withholds
/// the projection and keeps every block line out of ordinary calculation.
@Suite struct TableNoStaleProjectionTests {
  typealias Sample = TableSample

  static let above = "rate = 2\n"
  static let below = "rate * 3"

  static func sheet(_ blocks: String...) -> String {
    above + blocks.joined() + below
  }

  /// Every block line is quarantined, whatever its state, and prose around
  /// the blocks still calculates.
  static func expectQuarantined(_ evaluation: SheetEvaluation, prose: Bool = true) {
    for table in evaluation.tables {
      #expect(table.projection == nil || table.diagnostics.isEmpty)
      for line in table.physicalLines {
        let result = evaluation.lines[line]
        #expect(result.result == nil && result.declaredVariableName == nil)
        #expect(result.assistantPrompts.isEmpty)
      }
    }
    #expect(evaluation.tableDiagnostics == evaluation.tables.flatMap(\.diagnostics))
    if prose {
      #expect(evaluation.lines.last?.result == .value(.number(.integer(IntegerValue(6)))))
    }
  }

  static func expectWithheld(
    _ evaluation: SheetEvaluation, _ codes: [[TableSourceDiagnostic.Code]],
    prose: Bool = true, sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    #expect(
      evaluation.tables.map { $0.diagnostics.map(\.code) } == codes,
      sourceLocation: sourceLocation)
    #expect(
      evaluation.tables.allSatisfy { $0.projection == nil }, sourceLocation: sourceLocation)
    expectQuarantined(evaluation, prose: prose)
  }

  @Test func malformedJSONWithholdsTheProjectionUntilRepaired() throws {
    let valid = Self.sheet(try Sample.block())
    var run = try EditRun(valid)
    let first = try run.evaluate(valid)
    #expect(first.tables.map(\.projection) == [Sample.model])
    Self.expectQuarantined(first)

    // A valid edit shows the new table, not the old one.
    let renamed = valid.replacingOccurrences(of: "\"n\":\"Items\"", with: "\"n\":\"Goods\"")
    let goods = try run.evaluate(renamed)
    #expect(goods.tables.first?.projection?.name == "Goods")

    let broken = renamed.replacingOccurrences(of: "\"t\":0", with: "\"t\":")
    let malformed = try run.evaluate(broken)
    Self.expectWithheld(malformed, [[.malformed]])
    #expect(malformed.tableWork == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    // Evaluating the same invalid source again reuses the diagnosed block
    // and still has no projection.
    let again = try run.evaluate(broken)
    Self.expectWithheld(again, [[.malformed]])
    #expect(again.tableWork == TableSourceDocument.Work(blocks: 1, decoded: 0, reused: 1))

    let repaired = try run.evaluate(valid)
    #expect(repaired.tables.map(\.projection) == [Sample.model])
    #expect(repaired.tableDiagnostics.isEmpty)
  }

  @Test func aStaleFingerprintWithholdsTheProjection() throws {
    let valid = Self.sheet(try Sample.block())
    var run = try EditRun(valid)
    _ = try run.evaluate(valid)
    // The cell's formula changes without its ledger entry.
    let stale = valid.replacingOccurrences(of: "\"s\":\"=B2 + 1\"", with: "\"s\":\"=B2 + 2\"")
    #expect(stale != valid)
    Self.expectWithheld(try run.evaluate(stale), [[.staleBinding]])
    #expect(try run.evaluate(valid).tables.map(\.projection) == [Sample.model])
  }

  @Test func aDuplicateNameWithholdsBothProjectionsWithoutChoosingOne() throws {
    let valid = Self.sheet(try Sample.block())
    let twin = try Sample.block(TableDocumentTests.table(0x1000, name: "ITEMS"))
    let both = Self.sheet(try Sample.block(), twin)
    var run = try EditRun(valid)
    _ = try run.evaluate(valid)
    let duplicated = try run.evaluate(both)
    Self.expectWithheld(duplicated, [[.duplicateName], [.duplicateName]])
    // The first block's bytes are reused; only sheet-wide checks reject it.
    #expect(duplicated.tableWork == TableSourceDocument.Work(blocks: 2, decoded: 1, reused: 1))
    let restored = try run.evaluate(valid)
    #expect(restored.tables.map(\.projection) == [Sample.model])
    #expect(restored.tableWork == TableSourceDocument.Work(blocks: 1, decoded: 0, reused: 1))
  }

  @Test func readersOfARejectedTableAreRecheckedWhenReused() throws {
    let rates = TableDocumentTests.table(0x1000, name: "Rates", rows: 2)
    let target = TableReferenceTarget.cell(
      table: rates.id, row: rates.rows[1], column: rates.columns[0].id)
    let reader = try Sample.block(TableDocumentTests.reader(0x2000, name: "Items", target: target))
    let valid = Self.sheet(try Sample.block(rates), reader)
    var run = try EditRun(valid)
    #expect(try run.evaluate(valid).tables.allSatisfy { $0.projection != nil })
    let broken = valid.replacingOccurrences(of: "\"n\":\"Rates\"", with: "\"n\":\"Rates\",")
    let orphaned = try run.evaluate(broken)
    Self.expectWithheld(orphaned, [[.malformed], [.orphanTarget]])
    #expect(orphaned.tableWork == TableSourceDocument.Work(blocks: 2, decoded: 1, reused: 1))
    #expect(try run.evaluate(valid).tables.allSatisfy { $0.projection != nil })
  }

  @Test func crossingTheCellCeilingWithholdsEveryProjection() throws {
    let room = TableSourceDocument.maximumPopulatedCells - Sample.model.populatedCellCount
    let atCeiling = Self.sheet(
      try Sample.block(),
      try Sample.block(TableDocumentTests.table(0x10000, name: "Big", rows: room)))
    let over = Self.sheet(
      try Sample.block(),
      try Sample.block(TableDocumentTests.table(0x10000, name: "Big", rows: room + 1)))
    var run = try EditRun(atCeiling)
    let fits = try run.evaluate(atCeiling)
    #expect(fits.tables.allSatisfy { $0.projection != nil })
    let exceeded = try run.evaluate(over)
    Self.expectWithheld(exceeded, [[.cellLimit], [.cellLimit]])
    #expect(exceeded.tableWork == TableSourceDocument.Work(blocks: 2, decoded: 1, reused: 1))
    let back = try run.evaluate(atCeiling)
    #expect(back.tables.map(\.projection) == fits.tables.map(\.projection))
  }

  @Test func crossingTheSourceLimitWithholdsEveryProjection() throws {
    let valid = Self.sheet(try Sample.block())
    let padding = String(repeating: "// padding line for the source limit\n", count: 29_000)
    let oversized = padding + valid
    #expect(oversized.utf8.count > 1_048_576)
    var run = try EditRun(valid)
    _ = try run.evaluate(valid)
    let over = try run.evaluate(oversized)
    #expect(over.tables.map { $0.diagnostics.map(\.code) } == [[.sourceLimit]])
    #expect(over.tables.allSatisfy { $0.projection == nil })
    #expect(over.tableWork == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    #expect(over.lines[29_001..<(29_001 + 3)].allSatisfy { $0.result == nil })
    let back = try run.evaluate(valid)
    #expect(back.tables.map(\.projection) == [Sample.model])
    Self.expectQuarantined(back)
  }

  @Test(arguments: [false, true])
  func deletingTheCloserQuarantinesThroughTheEndUntilRestored(markdown: Bool) throws {
    let valid = Self.sheet(try Sample.block()) + " =>"
    var run = try EditRun(valid, markdown: markdown)
    let first = try run.evaluate(valid)
    #expect(first.lines.last?.result == .value(.number(.integer(IntegerValue(6)))))
    let open = valid.replacingOccurrences(of: "@end-ganit-table\n", with: "")
    let unterminated = try run.evaluate(open)
    Self.expectWithheld(unterminated, [[.unterminated]], prose: false)
    // The prose that followed the block is now block source too.
    #expect(unterminated.tables.first?.physicalLines == 1..<unterminated.lines.count)
    #expect(unterminated.lines.last?.result == nil)
    let restored = try run.evaluate(valid)
    #expect(restored.tables.map(\.projection) == [Sample.model])
    #expect(restored.lines.last?.result == .value(.number(.integer(IntegerValue(6)))))
  }
}
