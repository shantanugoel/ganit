import Foundation
import Testing

@testable import GanitEngine

/// M3 task 4: ordinary line-reference renumbering never scans table block
/// text as prose, while a table formula's deliberate `@N`/`line N` read of
/// earlier prose follows its target through the table transformation path,
/// rewriting the formula and its ledger together.
@Suite struct TableLineReferenceTests {
  typealias Fold = TableSheetFoldTests

  /// Applies a user edit and its automatic rewrites, as the editor does.
  static func edit(_ source: String, _ start: Int, _ length: Int, _ replacement: String)
    -> String
  {
    let range = NSRange(location: start, length: length)
    let edits = LineReferenceRenumbering.edits(
      replacing: range, in: source, with: replacement, configuration: .englishUnitedStates)
    #expect(
      zip(edits, edits.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.location })
    let text = NSMutableString(string: source)
    text.replaceCharacters(in: range, with: replacement)
    for edit in edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacement) }
    return text as String
  }

  /// The valid table in `source` with this ID.
  static func model(_ source: String, _ id: TableID) throws -> TableModel {
    let document = TableSourceDocument(source)
    return try #require(document.blocks.compactMap(\.table).first { $0.id == id })
  }

  static func formula(_ table: TableModel, row: Int, column: Int) -> String? {
    table.cells.first { $0.row == table.rows[row] && $0.column == table.columns[column].id }?
      .source
  }

  /// `Items` with Qty literals and an Amount formula per row, entered through
  /// `setCell` so bound operands get ledger entries.
  static func sheet(head: String, amounts: [String], tail: String) throws -> (String, TableID) {
    let table = Fold.table("Items", headers: ["Qty", "Amount", "Note"], rows: [["2"], ["4"]])
    var source = head + (try Fold.block(table)) + tail
    for (row, amount) in amounts.enumerated() {
      source = try TableSourceDocument(source).setCell(
        table: table.id, at: TableCellPosition(row: row, column: 1), source: amount
      ).applying(to: source)
    }
    return (source, table.id)
  }

  @Test func formulaLineReadsFollowInsertedAndDeletedProse() throws {
    // Lines: 1 `rate = 3`, 2 `bonus = 10`, then the block, then prose.
    let (source, id) = try Self.sheet(
      head: "rate = 3\nbonus = 10\n", amounts: ["=[@Qty] * @1", "=line 2 + [@Qty]"],
      tail: "@1 + @2\n")
    let before = try Self.model(source, id)
    #expect(before.ledger.count == 2)
    var run = try Fold.Run()
    let original = try run.evaluate(source)
    #expect(Fold.cell(original, id, row: 0, column: 1) == "6")
    #expect(Fold.cell(original, id, row: 1, column: 1) == "14")

    // Eight lines above make `@1` stay and `line 2` become `line 10`, so the
    // bound `[@Qty]` after it moves one byte in the fingerprint.
    let inserted = Self.edit(source, 9, 0, String(repeating: "0\n", count: 8))
    let after = try Self.model(inserted, id)
    #expect(Self.formula(after, row: 0, column: 1) == "=[@Qty] * @1")
    #expect(Self.formula(after, row: 1, column: 1) == "=line 10 + [@Qty]")
    let entry = try #require(
      after.ledger.first {
        $0.owner.column == after.columns[1].id && $0.fingerprint.hasPrefix("=line")
      })
    #expect(entry.fingerprint == "=line 10 + [@Qty]")
    #expect(entry.bindings.map(\.operand) == [11..<17])
    #expect(after.ledger.map(\.bindings.count) == before.ledger.map(\.bindings.count))
    // Identities and every other byte of the block are unchanged.
    #expect(after.rows == before.rows && after.columns.map(\.id) == before.columns.map(\.id))
    let evaluation = try run.evaluate(inserted)
    #expect(Fold.cell(evaluation, id, row: 0, column: 1) == "6")
    #expect(Fold.cell(evaluation, id, row: 1, column: 1) == "14")
    // Prose below follows as before.
    #expect(inserted.hasSuffix("@1 + @10\n"))

    // Deleting the target marks the read broken, like prose.
    let deleted = Self.edit(source, 9, 11, "")
    let broken = try Self.model(deleted, id)
    #expect(Self.formula(broken, row: 1, column: 1) == "=@deleted + [@Qty]")
    #expect(
      broken.ledger.first { $0.fingerprint.hasPrefix("=@deleted") }?.bindings.map(\.operand) == [
        12..<18
      ])
    let failed = try run.evaluate(deleted)
    #expect(Fold.cell(failed, id, row: 1, column: 1) == "failure:evaluation")
    #expect(Fold.cell(failed, id, row: 0, column: 1) == "6")
    #expect(deleted.hasSuffix("@1 + @deleted\n"))
  }

  @Test func columnRulesFollowAndTextCellsHeadersAndOperandsNeverDo() throws {
    var table = Fold.table(
      "Items", headers: ["Qty", "line 2", "Note"], rows: [["2"], ["4"]], rules: [1: "=@1 * [@Qty]"])
    table.columns[2].input = .text
    table.cells.append(
      TableCell(row: table.rows[0], column: table.columns[2].id, source: "see @1 and line 1"))
    table.cells.append(
      TableCell(row: table.rows[1], column: table.columns[2].id, source: "=sum(Items[line 2]) + @1")
    )
    // A formula in a text column is still a formula.
    let source = "3\n" + (try Fold.block(table)) + "@1\n"
    let edited = Self.edit(source, 0, 0, "1\n")
    let after = try Self.model(edited, table.id)
    #expect(after.columns[1].rule == "=@2 * [@Qty]")
    #expect(after.columns[1].header == "line 2")
    #expect(Self.formula(after, row: 0, column: 2) == "see @1 and line 1")
    #expect(Self.formula(after, row: 1, column: 2) == "=sum(Items[line 2]) + @2")
    #expect(edited.hasSuffix("@2\n"))
  }

  @Test func quarantinedAndEditedBlocksAreNeverRewritten() throws {
    let (valid, id) = try Self.sheet(head: "5\n", amounts: ["=@1 * [@Qty]"], tail: "")
    let quarantined = "@ganit-table 9\n{\"f\": \"=@1\"}\n@end-ganit-table\n"
    let source = valid + quarantined + "@1\n"
    let edited = Self.edit(source, 0, 0, "0\n")
    #expect(edited.contains(quarantined))
    #expect(Self.formula(try Self.model(edited, id), row: 0, column: 1) == "=@2 * [@Qty]")
    #expect(edited.hasSuffix("@2\n"))

    // An edit inside the block is the user's own; nothing in it is rewritten,
    // even when it adds a line to the payload.
    let block = (source as NSString).range(of: "\"r\"")
    let inside = Self.edit(source, block.location, 0, "\n")
    #expect(inside == (source as NSString).replacingCharacters(in: block, with: "\n\"r\""))
    // An edit that joins the opener to the line above destroys the block, so
    // nothing in it is rewritten either.
    let joined = Self.edit(source, 1, 1, "")
    #expect(joined.contains("=@1 * [@Qty]"))
  }

  @Test func insertingAndRemovingWholeBlocksRenumbersProseBelow() throws {
    let table = Fold.table("Items", headers: ["Qty"], rows: [["2"]])
    let block = try Fold.block(table)
    let count = SheetSource(block).lines.count - 1
    let source = "10\n20\n@2 + @1\n"
    let inserted = Self.edit(source, 3, 0, block)
    #expect(inserted == "10\n" + block + "20\n@\(2 + count) + @1\n")
    let removed = Self.edit(inserted, 3, (block as NSString).length, "")
    #expect(removed == source)
    // A table formula below an inserted block follows the shifted prose.
    let (sheet, id) = try Self.sheet(head: "10\n20\n", amounts: ["=@2 * [@Qty]"], tail: "")
    let above = Self.edit(sheet, 3, 0, block.replacingOccurrences(of: "Items", with: "Other"))
    #expect(Self.formula(try Self.model(above, id), row: 0, column: 1) == "=@\(2 + count) * [@Qty]")
  }

  @Test func reloadKeepsFollowedFormulasBound() throws {
    let (source, id) = try Self.sheet(
      head: "rate = 3\n", amounts: ["=[@Qty] * @1"], tail: "Items!B2 + @1\n")
    let inserted = Self.edit(source, 0, 0, "x = 1\n")
    // Reload: the rewritten block decodes, binds and calculates afresh.
    var run = try Fold.Run()
    let evaluation = try run.evaluate(inserted)
    #expect(Fold.cell(evaluation, id, row: 0, column: 1) == "6")
    #expect(Fold.answers(evaluation).last == "9")
    let reloaded = try Self.model(String(decoding: Array(inserted.utf8), as: UTF8.self), id)
    #expect(reloaded.ledger.first?.fingerprint == "=[@Qty] * @2")
    #expect(inserted.hasSuffix("Items!B2 + @2\n"))
  }
}
