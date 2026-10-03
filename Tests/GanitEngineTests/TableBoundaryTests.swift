import Foundation
import Testing

@testable import GanitEngine

/// M3 task 5: where tables are calculated (only in workspace sheets), what a
/// reader sees of a block (titles and search), and deleting a table, by
/// command or by deleting its text, without orphaning the tables and prose
/// that read it.
@Suite struct TableBoundaryTests {
  // MARK: - Support

  static func apply(_ edit: TableSourceEdit, to source: String) throws -> String {
    let result = try edit.applying(to: source)
    #expect(TableSourceDocument(result).diagnostics.isEmpty)
    return result
  }

  static func applying(_ edits: [(range: NSRange, replacement: String)], to text: String) -> String
  {
    let updated = NSMutableString(string: text)
    for edit in edits.reversed() {
      updated.replaceCharacters(in: edit.range, with: edit.replacement)
    }
    return updated as String
  }

  /// `base = 10`, table Rates (lines 2–4), `k = 4` (line 5), table Items
  /// reading Rates and line 5, then prose reading both tables and line 5.
  static func readerSheet() throws -> (source: String, rates: TableID, items: TableID) {
    var source = "base = 10\n"
    let rates = try TableSourceDocument(source).createTable(
      name: "Rates", headers: [("Rate", .value)], rowCount: 2, atUTF8: source.utf8.count)
    source = try apply(rates, to: source)
    let ratesID = try #require(rates.createdTable)
    source = try apply(
      TableSourceDocument(source).setCell(
        table: ratesID, at: .init(row: 0, column: 0), source: "2"),
      to: source)
    source = try apply(
      TableSourceDocument(source).setCell(
        table: ratesID, at: .init(row: 1, column: 0), source: "3"),
      to: source)
    source += "k = 4\n"
    let items = try TableSourceDocument(source).createTable(
      name: "Items", headers: [("Qty", .value), ("Total", .value)], rowCount: 2,
      atUTF8: source.utf8.count)
    source = try apply(items, to: source)
    let itemsID = try #require(items.createdTable)
    for (row, column, formula) in [
      (0, 0, "1"), (0, 1, "=Rates!A2 + @5"), (1, 0, "=sum(Rates[Rate])"),
      (1, 1, "=sum(Rates!A2:A3) + A2"),
    ] {
      source = try apply(
        TableSourceDocument(source).setCell(
          table: itemsID, at: .init(row: row, column: column), source: formula), to: source)
    }
    source +=
      "x = Rates!A2 + 1\ny = sum(Rates[Rate])\nw = @5 + 1\nz = Items!A2\n// Rates!A2 stays\n"
    return (source, ratesID, itemsID)
  }

  /// Prose range markers name a binding minted by the edit that wrote them.
  static func normalized(_ source: String) -> String {
    source.replacingOccurrences(
      of: "#REF!\\{range:[0-9a-f-]{36}\\}", with: "#REF!{range:*}", options: .regularExpression)
  }

  static func evaluate(_ source: String, surface: SheetSurface = .workspace) throws
    -> SheetEvaluation
  {
    var calculator = SheetCalculator(surface: surface)
    return try calculator.evaluate(SheetSource(source), context: try sheetContext())
  }

  static func problem(_ result: CalculationResult?) -> TableReferenceProblem? {
    guard case .evaluationFailure(let error) = result, error.code == .tableReference,
      case .tableReference(let problem) = error.context
    else { return nil }
    return problem
  }

  // MARK: - Surfaces

  static let tableThenProse: String = {
    let table = TableSheetFoldTests.table("Items", headers: ["Amount"], rows: [["4"], ["6"]])
    return (try! TableSheetFoldTests.block(table))
      + "total = sum(Items[Amount])\nfirst = Items!A2\nrate = 2\nf(x) = x * 2\n"
  }()

  @Test func definitionsRejectTablesAndExportNothingFromThem() throws {
    let evaluation = try Self.evaluate(Self.tableThenProse, surface: .definitions)
    // The opener explains; every other block line has no answer.
    #expect(Self.problem(evaluation.lines[0].result) == .definitions)
    #expect(evaluation.lines[1].result == nil && evaluation.lines[2].result == nil)
    // Readers fail with the same explanation and nothing they read exports.
    #expect(Self.problem(evaluation.lines[3].result) == .definitions)
    #expect(Self.problem(evaluation.lines[4].result) == .definitions)
    #expect(evaluation.definitions.variables.keys.sorted() == ["rate"])
    #expect(evaluation.definitions.functions.keys.sorted() == ["f"])
    let result = try #require(evaluation.tableResults.first)
    #expect(!result.isCalculated && result.diagnostics.isEmpty)
    #expect(result.calculationFailure?.context == .tableReference(.definitions))
    #expect(evaluation.calculatedTables.isEmpty)

    // The app's launch path agrees.
    let definitions = try SheetDefinitions(source: Self.tableThenProse, context: sheetContext())
    #expect(definitions.variables.keys.sorted() == ["rate"])
    // The same text in a sheet calculates and would have shared the total.
    let sheet = try Self.evaluate(Self.tableThenProse)
    #expect(sheet.lines[0].result == nil)
    #expect(sheet.definitions.variables.keys.sorted() == ["first", "rate", "total"])
  }

  @Test func definitionsFunctionsAndUnitsCannotCaptureTables() throws {
    let source =
      Self.tableThenProse + "g(x) = x + Items!A2\n1 crate = Items!A2 kg\nh = @2\n"
    let evaluation = try Self.evaluate(source, surface: .definitions)
    #expect(evaluation.definitions.units.isEmpty)
    #expect(evaluation.definitions.functions["g"] == nil)
    #expect(evaluation.definitions.variables["h"] == nil)
    // A sheet that inherits these definitions and has its own Items table
    // never reads it through them.
    #expect(evaluation.definitions.variables.keys.sorted() == ["rate"])
  }

  @Test func quickGanitKeepsBlocksExplainsAndCalculatesProse() throws {
    let malformed = "@ganit-table 1\n{\"ids\":[}\n@end-ganit-table\n"
    let source = Self.tableThenProse + "\n2 + 2\n" + malformed + "5\nsum\n"
    let evaluation = try Self.evaluate(source, surface: .quickGanit)
    let blocks = TableSourceDocument.blockLineRanges(in: SheetSource(source))
    #expect(blocks == [0..<3, 9..<12])
    for block in blocks {
      #expect(Self.problem(evaluation.lines[block.lowerBound].result) == .quickGanit)
      #expect(block.dropFirst().allSatisfy { evaluation.lines[$0].result == nil })
    }
    #expect(Self.problem(evaluation.lines[3].result) == .quickGanit)
    #expect(TableSheetFoldTests.describe(evaluation.lines[8].result) == "4")
    // Block lines never join an aggregate: `sum` adds only the line above.
    #expect(TableSheetFoldTests.describe(evaluation.lines[13].result) == "5")
    #expect(evaluation.tableDiagnostics.count == 1)
    #expect(evaluation.calculatedTables.isEmpty)
  }

  // MARK: - Display text

  @Test func displayLinesUseTableTextNotIdentities() throws {
    let (source, _, _) = try Self.readerSheet()
    let lines = TableSourceDocument.displayLines(of: SheetSource(source))
    #expect(lines.first == .prose("base = 10"))
    guard case .table(let name, let text) = lines[1] else {
      Issue.record("expected a table")
      return
    }
    #expect(name == "Rates" && text == ["Rate", "2", "3"])
    guard case .table(let items, let cells) = lines[3] else {
      Issue.record("expected a table")
      return
    }
    #expect(items == "Items")
    #expect(cells.contains("=sum(Rates[Rate])") && cells.contains("Total"))
    let joined = lines.map { "\($0)" }.joined()
    #expect(!joined.contains("\"ids\"") && !joined.contains("ganit-table"))
    // A quarantined block is shown raw, as the editor shows it.
    let quarantined = TableSourceDocument.displayLines(
      of: SheetSource("@ganit-table 2\n{}\n@end-ganit-table\nx"))
    #expect(
      quarantined == [.quarantined(["@ganit-table 2", "{}", "@end-ganit-table"]), .prose("x")])
  }

  // MARK: - Table deletion

  @Test func deleteTableBreaksReadersAndFollowsLines() throws {
    let (source, rates, items) = try Self.readerSheet()
    let document = TableSourceDocument(source)
    let ratesModel = try #require(document.blocks[0].table)
    let edit = try document.deleteTable(rates)
    let deleted = try Self.apply(edit, to: source)
    let after = TableSourceDocument(deleted)
    #expect(after.blocks.count == 1 && after.diagnostics.isEmpty)
    let table = try #require(after.blocks[0].table)
    #expect(table.id == items)
    func cell(_ row: Int, _ column: Int) -> String? {
      table.cells.first { $0.row == table.rows[row] && $0.column == table.columns[column].id }?
        .source
    }
    let marker =
      "#REF!{\(rates.string)/\(ratesModel.rows[0].string)/\(ratesModel.columns[0].id.string)}"
    #expect(cell(0, 1) == "=\(marker) + @2")
    #expect(cell(1, 0)?.hasPrefix("=sum(#REF!{range:") == true)
    #expect(cell(1, 1)?.hasPrefix("=sum(#REF!{range:") == true)
    #expect(cell(1, 1)?.hasSuffix(") + A2") == true)
    #expect(deleted.hasPrefix("base = 10\nk = 4\n@ganit-table 1\n"))
    #expect(deleted.contains("\nx = \(marker) + 1\ny = sum(#REF!{range:"))
    #expect(deleted.contains("\nw = @2 + 1\nz = Items!A2\n// Rates!A2 stays\n"))

    // Deleted bindings keep the original members, which no table has now.
    let range = try #require(
      table.ledger.flatMap(\.bindings).first {
        if case .namedColumn = $0.target { return true }
        return false
      })
    #expect(range.isDeleted && range.target.table == rates)

    // The readers calculate with explicit failures instead of being
    // quarantined, and independent cells still answer.
    let evaluation = try Self.evaluate(deleted)
    let snapshot = try #require(evaluation.tableResult(items))
    #expect(snapshot.diagnostics.isEmpty && snapshot.isCalculated)
    if case .value(let value) = snapshot.value(row: table.rows[0], column: table.columns[0].id) {
      #expect(TableSheetFoldTests.describe(value) == "1")
    } else {
      Issue.record("an independent cell answers")
    }
    if case .failure = snapshot.value(row: table.rows[0], column: table.columns[1].id) {
    } else {
      Issue.record("a broken cell reference fails")
    }
    let lines = evaluation.lines
    #expect(Self.problem(lines[5].result) == .malformed)
    #expect(Self.problem(lines[6].result) == .malformed)
    #expect(TableSheetFoldTests.describe(lines[7].result) == "5")
    #expect(TableSheetFoldTests.describe(lines[8].result) == "1")

    // The reader stays editable: later structural edits keep its markers.
    var edited = try Self.apply(
      TableSourceDocument(deleted).insertRows(table: items, at: 0), to: deleted)
    edited = try Self.apply(
      TableSourceDocument(edited).setCell(table: items, at: .init(row: 0, column: 0), source: "7"),
      to: edited)
    #expect(edited.contains("\(marker) + @2"))
    #expect(TableSourceDocument(edited).diagnostics.isEmpty)

    // A new table with the same name revives nothing.
    let recreated = try Self.apply(
      TableSourceDocument(deleted).createTable(
        name: "Rates", headers: [("Rate", .value)], rowCount: 2, atUTF8: "base = 10\n".utf8.count),
      to: deleted)
    let revived = try Self.evaluate(recreated)
    #expect(Self.problem(revived.lines[8].result) == .malformed)
    #expect(recreated.contains("x = \(marker) + 1"))

    // Undo is the original bytes; redo recomputes the same bytes; reload
    // reads the same tables.
    #expect(
      Self.normalized(try TableSourceDocument(source).deleteTable(rates).applying(to: source))
        == Self.normalized(deleted))
    #expect(TableSourceDocument(deleted).blocks == after.blocks)
  }

  @Test func deletingTheBlockTextBreaksReadersInTheSameEdit() throws {
    let (source, rates, _) = try Self.readerSheet()
    let block = TableSourceDocument(source).blocks[0]
    let utf16Start = String(decoding: source.utf8.prefix(block.utf8Range.lowerBound), as: UTF8.self)
      .utf16.count
    let range = NSRange(location: utf16Start, length: block.rawSource.utf16.count)
    let removed = (source as NSString).replacingCharacters(in: range, with: "")
    let edits = LineReferenceRenumbering.edits(
      replacing: range, in: source, with: "", configuration: .englishUnitedStates)
    let typed = Self.applying(edits, to: removed)
    #expect(
      Self.normalized(typed)
        == Self.normalized(try TableSourceDocument(source).deleteTable(rates).applying(to: source)))
    #expect(TableSourceDocument(typed).diagnostics.isEmpty)

    // Selecting the lines through the closer's text, leaving its line
    // break, is the same deletion.
    let partial = NSRange(location: range.location, length: range.length - 1)
    let partialEdits = LineReferenceRenumbering.edits(
      replacing: partial, in: source, with: "", configuration: .englishUnitedStates)
    #expect(partialEdits.contains { $0.replacement.hasPrefix("#REF!{") })

    // Pasting the same block over itself keeps the table.
    let same = LineReferenceRenumbering.edits(
      replacing: range, in: source, with: block.rawSource, configuration: .englishUnitedStates)
    #expect(!same.contains { $0.replacement.contains("#REF!") })

    // Deleting only the closer keeps every reference: the block becomes
    // unterminated, its readers are quarantined, and Undo repairs it.
    let closer = (source as NSString).range(of: "@end-ganit-table\n", options: [], range: range)
    let unclosed = LineReferenceRenumbering.edits(
      replacing: closer, in: source, with: "", configuration: .englishUnitedStates)
    #expect(!unclosed.contains { $0.replacement.contains("#REF!") })
  }

  @Test func deletingBothTablesAtOnceLeavesNoOrphans() throws {
    let (source, _, _) = try Self.readerSheet()
    let document = TableSourceDocument(source)
    let first = document.blocks[0]
    let second = document.blocks[1]
    let utf16 = { (offset: Int) in
      String(decoding: source.utf8.prefix(offset), as: UTF8.self).utf16.count
    }
    let range = NSRange(
      location: utf16(first.utf8Range.lowerBound),
      length: utf16(second.utf8Range.upperBound) - utf16(first.utf8Range.lowerBound))
    let edits = LineReferenceRenumbering.edits(
      replacing: range, in: source, with: "", configuration: .englishUnitedStates)
    let result = Self.applying(
      edits, to: (source as NSString).replacingCharacters(in: range, with: ""))
    #expect(TableSourceDocument(result).blocks.isEmpty)
    #expect(result.contains("x = #REF!{") && result.contains("w = @deleted + 1"))
  }

  @Test func deletingATableBreaksFreshReferencesWithoutAPersistedLedger() throws {
    let rates = TableSheetFoldTests.table("Rates", headers: ["Rate"], rows: [["7"]])
    let reader = TableSheetFoldTests.table(
      "Reader", headers: ["Cell", "Range", "Unrelated"],
      rows: [["=Rates!A2", "=sum(Rates[Rate])", "=A1"]])
    let source = try TableSheetFoldTests.block(rates) + TableSheetFoldTests.block(reader)
    #expect(TableSourceDocument(source).diagnostics.isEmpty)
    #expect(reader.ledger.isEmpty)
    let removed = try Self.apply(TableSourceDocument(source).deleteTable(rates.id), to: source)
    let surviving = try #require(TableSourceDocument(removed).blocks.first?.table)
    let block = TableSourceDocument(source).blocks[0]
    let range = NSRange(location: 0, length: block.rawSource.utf16.count)
    let typed = Self.applying(
      LineReferenceRenumbering.edits(
        replacing: range, in: source, with: "", configuration: .englishUnitedStates),
      to: (source as NSString).replacingCharacters(in: range, with: ""))
    // Each independent edit creates its own binding ID for the fresh range.
    // Compare every other byte, including all original target identities.
    let typedTable = try #require(TableSourceDocument(typed).blocks.first?.table)
    let typedBinding = try #require(typedTable.ledger.flatMap(\.bindings).compactMap(\.id).first)
    let removedBinding = try #require(surviving.ledger.flatMap(\.bindings).compactMap(\.id).first)
    #expect(
      typed.replacingOccurrences(of: typedBinding.string, with: removedBinding.string) == removed)
    #expect(surviving.cells[0].source.contains("#REF!{"))
    #expect(surviving.cells[1].source.contains("#REF!{range:"))
    #expect(surviving.cells[2].source == "=A1")
    #expect(
      !surviving.ledger.contains {
        $0.owner == .cell(row: reader.rows[0], column: reader.columns[2].id)
      })
    // Reintroducing the original name and coordinate cannot revive a reader.
    let recreated = try Self.apply(
      TableSourceDocument(removed).createTable(
        name: "Rates", headers: [("Rate", .value)], rowCount: 1, atUTF8: 0), to: removed)
    let snapshot = try #require(Self.evaluate(recreated).tableResult(reader.id))
    for column in reader.columns.prefix(2) {
      if case .failure? = snapshot.value(row: reader.rows[0], column: column.id) {
      } else {
        Issue.record("a deleted fresh target stays broken")
      }
    }
  }

  @Test func deleteTableRejectsUnknownTables() throws {
    let (source, _, _) = try Self.readerSheet()
    #expect(throws: TableTransformError.missingTable) {
      try TableSourceDocument(source).deleteTable(TableID.mint())
    }
  }
}
