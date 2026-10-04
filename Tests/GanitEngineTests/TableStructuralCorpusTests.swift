import Foundation
import Testing

@testable import GanitEngine

/// End-to-end engine corpus for M3 task 2: every row of the structural-edit
/// contract (plan "Structural edit semantics", ADR 0016 "Exact structural
/// transformations") runs as edit → Undo → redo → reload.
///
/// Document Undo restores source, so Undo is the edit's inverse patch set
/// (each replacement swapped back for the exact bytes it replaced) and redo
/// re-applies the recorded patches; save/reload re-parses the source. Every
/// committed step checks untouched bytes, ledger consistency, that live
/// targets exist and deleted ones stay deleted, and that both directions
/// reproduce identical bytes and identical projected models.
@Suite struct TableStructuralCorpusTests {
  // MARK: - Sheets

  private enum Part {
    case prose(String)
    case table(TableModel)
  }

  /// A table with value columns, literal or formula cells by `[row][column]`
  /// (empty means no record) and optional column rules.
  private static func table(
    _ name: String, headers: [String], rows: [[String]] = [], rowCount: Int? = nil,
    rules: [Int: String] = [:]
  ) -> TableModel {
    var table = TableModel.creating(
      name: name, headers: headers.map { ($0, .value) }, rowCount: rowCount ?? rows.count)
    for (column, rule) in rules { table.columns[column].rule = rule }
    for (row, sources) in rows.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(
            row: table.rows[row], column: table.columns[column].id, source: source,
            isOverride: table.columns[column].rule != nil))
      }
    }
    return table
  }

  /// Builds the sheet, then binds every table once through a deliberate
  /// no-op rename, so each formula has a persisted ledger before the test.
  private func sheet(_ parts: [Part]) throws -> TableSourceDocument {
    var source = ""
    for part in parts {
      switch part {
      case .prose(let text): source += text
      case .table(let table): source += try TableSourceDocument.canonicalBlock(for: table)
      }
    }
    var document = TableSourceDocument(source)
    #expect(document.diagnostics.isEmpty)
    for table in document.blocks.compactMap(\.table) {
      document = try commit(document.renameTable(table.id, to: table.name), on: document)
    }
    return document
  }

  /// Items (Qty, Price, Amount = `[@Qty] * [@Price]`), prose, then Summary
  /// reading Items through structured, finite, locked and whole-column forms.
  private func budget() throws -> TableSourceDocument {
    try sheet([
      .prose("# Budget\nrate = 3\n"),
      .table(
        Self.table(
          "Items", headers: ["Qty", "Price", "Amount"],
          rows: [["2", "5"], ["3", "7"], ["4", "11"]], rules: [2: "=[@Qty] * [@Price]"])),
      .prose("total = sum(Items[Amount]) // Items[Amount] stays\n// Items!A3 comment\n"),
      .table(
        Self.table(
          "Summary", headers: ["Value"],
          rows: [
            ["=sum(Items[Amount])"], ["=sum(Items!C2:C3)"], ["=Items!$A$3"], ["=sum(Items!C:C)"],
          ])),
      .prose("check = Items!A3 + rate\n"),
    ])
  }

  /// `Grid` with columns A…, and a later `Read` table of qualified readers.
  private func grid(
    columns: Int, rows: Int, cells: [[String]] = [], readers: [String] = [],
    prose: String = ""
  ) throws -> TableSourceDocument {
    let grid = Self.table(
      "Grid", headers: (0..<columns).map { Self.letter($0) }, rows: cells, rowCount: rows)
    var parts: [Part] = [.prose("# Grid\n"), .table(grid)]
    if !readers.isEmpty {
      parts.append(.prose("between = 1\n"))
      parts.append(.table(Self.table("Read", headers: ["F"], rows: readers.map { [$0] })))
    }
    if !prose.isEmpty { parts.append(.prose(prose)) }
    return try sheet(parts)
  }

  private static func letter(_ column: Int) -> String {
    var number = column + 1
    var result = ""
    while number > 0 {
      number -= 1
      result = String(UnicodeScalar(UInt8(65 + number % 26))) + result
      number /= 26
    }
    return result
  }

  // MARK: - Edit, Undo, redo and reload

  private struct Recorded {
    let before: String
    let edit: TableSourceEdit
    let after: String
  }

  /// The inverse of a transaction applied to `before`: each patch's
  /// replacement, located in the result, is swapped back for its old bytes.
  private static func inverse(_ patches: [TableSourcePatch]) -> [TableSourcePatch] {
    var delta = 0
    var inverse: [TableSourcePatch] = []
    for patch in patches.sorted(by: {
      ($0.utf8Range.lowerBound, $0.utf8Range.upperBound)
        < ($1.utf8Range.lowerBound, $1.utf8Range.upperBound)
    }) {
      let lower = patch.utf8Range.lowerBound + delta
      inverse.append(
        TableSourcePatch(
          utf8Range: lower..<(lower + patch.replacement.utf8.count), expected: patch.replacement,
          replacement: patch.expected))
      delta += patch.replacement.utf8.count - patch.utf8Range.count
    }
    return inverse
  }

  /// Bytes outside every patch are exactly the old bytes, in order.
  private static func expectUntouched(
    _ before: String, _ after: String, _ patches: [TableSourcePatch]
  ) {
    let old = Array(before.utf8)
    var rebuilt: [UInt8] = []
    var cursor = 0
    for patch in patches.sorted(by: { $0.utf8Range.lowerBound < $1.utf8Range.lowerBound }) {
      #expect(old[patch.utf8Range].elementsEqual(patch.expected.utf8))
      rebuilt += old[cursor..<patch.utf8Range.lowerBound]
      rebuilt += patch.replacement.utf8
      cursor = patch.utf8Range.upperBound
    }
    rebuilt += old[cursor...]
    #expect(rebuilt == Array(after.utf8))
  }

  /// Ledger consistency after reload: each table validates, every live
  /// binding's target (in its own or another table) exists, and every deleted
  /// binding's target is really gone, so no marker revives.
  private static func expectConsistent(_ document: TableSourceDocument, _ note: String = "") {
    let tables = document.blocks.compactMap(\.table)
    for table in tables {
      #expect((try? table.validate()) != nil, "\(note): \(table.name) validates")
      for entry in table.ledger {
        for binding in entry.bindings {
          let id = binding.target.table ?? table.id
          guard let target = tables.first(where: { $0.id == id }) else {
            #expect(binding.isDeleted, "\(note): live binding into a missing table")
            continue
          }
          #expect(
            (try? target.checkTarget(binding, TableAxes(target))) != nil,
            "\(note): binding \(binding.target.kind) in \(table.name) is consistent")
        }
      }
    }
  }

  /// Applies an edit as one transaction and checks it end to end. Returns
  /// the reloaded document after the edit.
  @discardableResult
  private func commit(
    _ edit: TableSourceEdit, on before: TableSourceDocument, _ note: String = ""
  ) throws -> TableSourceDocument {
    let after = try edit.applying(to: before.source)
    Self.expectUntouched(before.source, after, edit.patches)
    let reloaded = TableSourceDocument(after)
    let known = Set(before.diagnostics.map(\.code))
    #expect(reloaded.diagnostics.allSatisfy { known.contains($0.code) }, "\(note) diagnostics")
    Self.expectConsistent(reloaded, note)
    // A second load projects the same models: nothing is minted on parse.
    #expect(TableSourceDocument(after).blocks.map(\.table) == reloaded.blocks.map(\.table))

    let undone = try TableSourcePatch.applying(Self.inverse(edit.patches), to: after)
    #expect(Array(undone.utf8) == Array(before.source.utf8), "\(note) Undo restores bytes")
    #expect(TableSourceDocument(undone).blocks.map(\.table) == before.blocks.map(\.table))
    let redone = try edit.applying(to: undone)
    #expect(Array(redone.utf8) == Array(after.utf8), "\(note) redo reproduces bytes")
    #expect(TableSourceDocument(redone).blocks.map(\.table) == reloaded.blocks.map(\.table))
    return reloaded
  }

  // MARK: - Reading results

  private func named(_ document: TableSourceDocument, _ name: String) throws -> TableModel {
    try #require(document.blocks.compactMap(\.table).first { $0.name == name })
  }
  private func source(_ table: TableModel, _ row: Int, _ column: Int) -> String? {
    table.cells.first { $0.row == table.rows[row] && $0.column == table.columns[column].id }?
      .source
  }
  private func calculate(_ document: TableSourceDocument) throws -> [TableID:
    TableCalculationSnapshot]
  {
    var snapshots: [TableID: TableCalculationSnapshot] = [:]
    var visible: [TableModel] = []
    let context = try sheetContext()
    for table in document.blocks.compactMap(\.table) {
      snapshots[table.id] = try TableCalculator().calculate(
        table, scope: TableFormulaScope(current: table, visible: visible, inherited: [:]),
        context: context, earlier: snapshots)
      visible.append(table)
    }
    return snapshots
  }
  private func value(
    _ snapshots: [TableID: TableCalculationSnapshot], _ table: TableModel, _ row: Int,
    _ column: Int
  ) -> TableCellResult? {
    snapshots[table.id]?.result(
      at: TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id))
  }
  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }
  private static func markers(_ source: String) -> [String] {
    var found: [String] = []
    var rest = Substring(source)
    while let start = rest.range(of: "#REF!{") {
      guard let end = rest[start.upperBound...].firstIndex(of: "}") else { break }
      found.append(String(rest[start.lowerBound...end]))
      rest = rest[rest.index(after: end)...]
    }
    return found
  }

  // MARK: - Edit a value or formula

  @Test func editingValuesAndFormulasKeepsIdentitiesAndRecalculates() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    let summary = try named(doc, "Summary")
    var results = try calculate(doc)
    #expect(value(results, items, 0, 2) == number(10))
    #expect(value(results, summary, 0, 0) == number(75))
    #expect(value(results, summary, 1, 0) == number(31))

    doc = try commit(
      doc.setCell(table: items.id, at: .init(row: 0, column: 0), source: "4"), on: doc)
    var edited = try named(doc, "Items")
    #expect(edited.id == items.id && edited.rows == items.rows)
    #expect(edited.columns.map(\.id) == items.columns.map(\.id))
    #expect(try named(doc, "Summary") == summary)
    results = try calculate(doc)
    #expect(value(results, edited, 0, 2) == number(20))
    #expect(value(results, summary, 0, 0) == number(85))
    #expect(value(results, summary, 1, 0) == number(41))

    doc = try commit(
      doc.setCell(table: items.id, at: .init(row: 1, column: 1), source: "=A2 + 1"), on: doc)
    edited = try named(doc, "Items")
    let entry = try #require(
      edited.ledger.first { $0.owner == .cell(row: items.rows[1], column: items.columns[1].id) })
    #expect(
      entry.bindings.map(\.target) == [
        .cell(table: items.id, row: items.rows[0], column: items.columns[0].id)
      ])
    results = try calculate(doc)
    // Price row 3 is now Qty row 2 + 1 = 5, so Amount there is 3 × 5.
    #expect(value(results, edited, 1, 2) == number(15))
    #expect(value(results, summary, 0, 0) == number(20 + 15 + 44))
  }

  // MARK: - Insertion boundaries on both axes

  @Test func insertionShiftsExpandsOrLeavesRangesOnRowsAndColumns() throws {
    var doc = try grid(
      columns: 4, rows: 5,
      readers: [
        "=sum(Grid!B3:C4)", "=Grid!$B$3", "=sum(Grid!B:C)", "=sum(Grid[B])", "=Grid!B3",
        "=Grid!B1",
      ])
    let id = try named(doc, "Grid").id
    func readers() throws -> [String?] {
      let read = try named(doc, "Read")
      return (0..<6).map { source(read, $0, 0) }
    }
    // Immediately before the first member is outside: everything shifts.
    doc = try commit(doc.insertRows(table: id, at: 1), on: doc, "row before")
    #expect(
      try readers() == [
        "=sum(Grid!B4:C5)", "=Grid!$B$4", "=sum(Grid!B:C)", "=sum(Grid[B])", "=Grid!B4",
        "=Grid!B1",
      ])
    // Immediately before the last member is inside: the rectangle expands.
    doc = try commit(doc.insertRows(table: id, at: 3), on: doc, "row inside")
    #expect(try readers()[0] == "=sum(Grid!B4:C6)")
    #expect(try readers()[1] == "=Grid!$B$4")
    // Just after the last member is outside: no extension.
    doc = try commit(doc.insertRows(table: id, at: 5), on: doc, "row after")
    #expect(try readers()[0] == "=sum(Grid!B4:C6)")

    doc = try commit(doc.insertColumn(table: id, at: 1, header: "X"), on: doc, "column before")
    #expect(
      try readers() == [
        "=sum(Grid!C4:D6)", "=Grid!$C$4", "=sum(Grid!C:D)", "=sum(Grid[B])", "=Grid!C4",
        "=Grid!C1",
      ])
    doc = try commit(doc.insertColumn(table: id, at: 3, header: "Y"), on: doc, "column inside")
    #expect(try readers()[0] == "=sum(Grid!C4:E6)")
    #expect(try readers()[2] == "=sum(Grid!C:E)")
    #expect(try readers()[1] == "=Grid!$C$4")
    doc = try commit(doc.insertColumn(table: id, at: 5, header: "Z"), on: doc, "column after")
    #expect(try readers()[0] == "=sum(Grid!C4:E6)")
    #expect(try readers()[2] == "=sum(Grid!C:E)")
  }

  // MARK: - Append

  @Test func appendedRowsInheritTheRuleAndGrowOnlyDynamicRanges() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    let summary = try named(doc, "Summary")
    let proseBefore = doc.source.components(separatedBy: "\n").filter { !$0.hasPrefix("```") }
      .filter { $0.hasPrefix("total") || $0.hasPrefix("check") || $0.hasPrefix("//") }
    doc = try commit(doc.appendRows(table: items.id), on: doc, "append")
    doc = try commit(
      doc.pastePlainText("5\t13", table: items.id, at: .init(row: 3, column: 0), formulas: false),
      on: doc, "literal paste")
    let appended = try named(doc, "Items")
    #expect(appended.rows.count == 4 && Array(appended.rows.prefix(3)) == items.rows)
    // The new row has no Amount record: it inherits the column rule.
    #expect(source(appended, 3, 2) == nil)
    #expect(
      try doc.plainText(table: items.id, rectangle: .init(rows: 3..<4, columns: 0..<3))
        == "5\t13\t=[@Qty] * [@Price]")
    // The finite rectangle is not extended; the named and whole column are.
    #expect(try named(doc, "Summary") == summary)
    let results = try calculate(doc)
    #expect(value(results, appended, 3, 2) == number(65))
    #expect(value(results, summary, 0, 0) == number(75 + 65))
    #expect(value(results, summary, 1, 0) == number(31))
    #expect(value(results, summary, 3, 0) == number(75 + 65))
    // Later prose reading the named column is untouched source that now spans
    // the new row; evaluating it is the mixed-sheet fold's job.
    let proseAfter = doc.source.components(separatedBy: "\n")
      .filter { $0.hasPrefix("total") || $0.hasPrefix("check") || $0.hasPrefix("//") }
    #expect(proseAfter == proseBefore)
  }

  // MARK: - Deleting scalar targets

  @Test func deletedScalarTargetsPersistMarkersThatCoordinateReuseCannotRepair() throws {
    var doc = try grid(
      columns: 3, rows: 3, cells: [["1", "2", "=A3"], ["3", "4"], ["5", "6"]],
      readers: ["=Grid!A3", "=Grid!B1", "=Grid!$A$3"], prose: "x = Grid!A3 + 1\n")
    let original = try named(doc, "Grid")
    doc = try commit(doc.deleteRows(table: original.id, in: 1..<2), on: doc, "delete row")
    let rowMarker =
      "#REF!{\(original.id.string)/\(original.rows[1].string)/\(original.columns[0].id.string)}"
    var grid = try named(doc, "Grid")
    var read = try named(doc, "Read")
    #expect(source(grid, 0, 2) == "=" + rowMarker)
    #expect(source(read, 0, 0) == "=" + rowMarker)
    #expect(source(read, 2, 0) == "=" + rowMarker)
    #expect(doc.source.contains("x = \(rowMarker) + 1\n"))
    #expect(source(read, 1, 0) == "=Grid!B1")

    doc = try commit(doc.deleteColumns(table: original.id, in: 1..<2), on: doc, "delete column")
    let headerMarker = "#REF!{\(original.id.string)/header/\(original.columns[1].id.string)}"
    read = try named(doc, "Read")
    #expect(source(read, 1, 0) == "=" + headerMarker)
    let markers = Self.markers(doc.source)
    // Four table operands (each in its cell and its ledger fingerprint) and
    // one prose operand.
    #expect(markers.count == 9 && Set(markers) == [rowMarker, headerMarker])

    // Reusing both coordinates never repairs any marker, even with a value.
    doc = try commit(doc.insertRows(table: original.id, at: 1), on: doc, "reuse row")
    doc = try commit(doc.insertColumn(table: original.id, at: 1, header: "B"), on: doc, "reuse col")
    doc = try commit(
      doc.setCell(table: original.id, at: .init(row: 1, column: 0), source: "9"), on: doc)
    #expect(Self.markers(doc.source) == markers)
    grid = try named(doc, "Grid")
    #expect(source(grid, 0, 2) == "=" + rowMarker)
    let results = try calculate(doc)
    if case .failure = value(results, try named(doc, "Read"), 0, 0) {
    } else {
      Issue.record("A broken scalar reference must stay a failure after coordinate reuse")
    }
  }

  // MARK: - Deleting inside and at the ends of ranges

  @Test func deletionInsideARectangleShrinksItUntilItBreaks() throws {
    var doc = try grid(
      columns: 3, rows: 4, readers: ["=sum(Grid!A2:C4)"], prose: "y = sum(Grid!A2:C4)\n")
    let original = try named(doc, "Grid")
    func reader() throws -> String? { source(try named(doc, "Read"), 0, 0) }
    doc = try commit(doc.deleteRows(table: original.id, in: 1..<2), on: doc, "inside row")
    #expect(try reader() == "=sum(Grid!A2:C3)")
    #expect(doc.source.contains("y = sum(Grid!A2:C3)\n"))
    doc = try commit(doc.deleteColumns(table: original.id, in: 1..<2), on: doc, "inside column")
    #expect(try reader() == "=sum(Grid!A2:B3)")
    let read = try named(doc, "Read")
    guard case .rectangle(_, let rows, let columns) = read.ledger[0].bindings[0].target else {
      Issue.record("Expected a rectangle binding")
      return
    }
    #expect(rows == TableMembership.interval(first: original.rows[0], last: original.rows[2]))
    #expect(
      columns
        == TableMembership.interval(first: original.columns[0].id, last: original.columns[2].id))

    doc = try commit(doc.deleteRows(table: original.id, in: 0..<2), on: doc, "every member")
    let broken = try #require(try reader())
    #expect(broken.hasPrefix("=sum(#REF!{range:"))
    doc = try commit(doc.insertRows(table: original.id, at: 0, count: 3), on: doc, "reuse")
    #expect(try reader() == broken)
    #expect(doc.source.contains("y = sum(#REF!{range:"))
  }

  @Test func deletingRangeEndpointsNeverTakesAnAdjacentOutsideMember() throws {
    var doc = try grid(
      columns: 4, rows: 6, readers: ["=sum(Grid!A3:B5)", "=sum(Grid!B2:C2)", "=sum(Grid!B:C)"])
    let original = try named(doc, "Grid")
    func readers() throws -> [String?] {
      let read = try named(doc, "Read")
      return (0..<3).map { source(read, $0, 0) }
    }
    doc = try commit(doc.deleteRows(table: original.id, in: 1..<2), on: doc, "first row member")
    #expect(try readers()[0] == "=sum(Grid!A3:B4)")
    doc = try commit(doc.deleteRows(table: original.id, in: 2..<3), on: doc, "last row member")
    #expect(try readers()[0] == "=sum(Grid!A3:B3)")
    doc = try commit(doc.deleteColumns(table: original.id, in: 1..<2), on: doc, "first column")
    #expect(try readers() == ["=sum(Grid!A3:A3)", "=sum(Grid!B2:B2)", "=sum(Grid!B:B)"])
    let read = try named(doc, "Read")
    #expect(
      read.ledger.first { $0.owner == .cell(row: read.rows[1], column: read.columns[0].id) }?
        .bindings[0].target
        == TableReferenceTarget.rectangle(
          table: original.id, rows: .interval(first: original.rows[0], last: original.rows[0]),
          columns: .interval(first: original.columns[2].id, last: original.columns[2].id)))
    // Column D now sits right after the shrunken ranges and stays outside.
    #expect(try named(doc, "Grid").columns.count == 3)
  }

  // MARK: - Rename

  @Test func renameRewritesBoundOperandsInOneTransactionAndRejectsCollisions() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    doc = try commit(doc.renameTable(items.id, to: "Travel costs"), on: doc, "table rename")
    doc = try commit(
      doc.renameColumn(table: items.id, column: items.columns[2].id, to: "Line total"), on: doc,
      "column rename")
    doc = try commit(
      doc.renameColumn(table: items.id, column: items.columns[1].id, to: "Unit price"), on: doc,
      "column rename")
    let summary = try named(doc, "Summary")
    #expect(source(summary, 0, 0) == "=sum(`Travel costs`[Line total])")
    #expect(source(summary, 1, 0) == "=sum(`Travel costs`!C2:C3)")
    #expect(source(summary, 2, 0) == "=`Travel costs`!$A$3")
    #expect(try named(doc, "Travel costs").columns[2].rule == "=[@Qty] * [@[Unit price]]")
    #expect(doc.source.contains("total = sum(`Travel costs`[Line total]) // Items[Amount] stays\n"))
    #expect(doc.source.contains("// Items!A3 comment\n"))
    #expect(doc.source.contains("check = `Travel costs`!A3 + rate\n"))
    #expect(value(try calculate(doc), summary, 0, 0) == number(75))

    let before = doc.source
    #expect(throws: (any Error).self) {
      try doc.renameTable(summary.id, to: "travel COSTS").applying(to: doc.source)
    }
    #expect(throws: (any Error).self) {
      try doc.renameColumn(table: items.id, column: items.columns[0].id, to: "LINE TOTAL")
        .applying(to: doc.source)
    }
    #expect(doc.source == before)
  }

  // MARK: - Copy, fill and clipboards

  @Test func copyAndFillTranslateUnlockedAxesAndBreakOutOfBounds() throws {
    var doc = try grid(
      columns: 4, rows: 4,
      cells: [["1", "2", "=B2+$B2+B$2+$B$2"], ["3", "4"], ["5", "6", "=B2"], ["7", "8"]])
    let id = try named(doc, "Grid").id
    doc = try commit(
      doc.copyCell(table: id, from: .init(row: 0, column: 2), to: .init(row: 2, column: 3)),
      on: doc, "copy")
    var grid = try named(doc, "Grid")
    #expect(source(grid, 2, 3) == "=C4+$B4+C$2+$B$2")
    #expect(
      grid.ledger.first { $0.owner == .cell(row: grid.rows[2], column: grid.columns[3].id) }?
        .bindings.map(\.locks) == [[false, false], [false, true], [true, false], [true, true]])

    doc = try commit(
      doc.fill(table: id, from: .init(row: 0, column: 2), into: .init(rows: 1..<2, columns: 2..<3)),
      on: doc, "fill")
    grid = try named(doc, "Grid")
    #expect(source(grid, 1, 2) == "=B3+$B3+B$2+$B$2")
    let results = try calculate(doc)
    #expect(value(results, grid, 1, 2) == number(4 + 4 + 2 + 2))

    // Two rows up from row 4 is above the header: a persistent broken target.
    doc = try commit(
      doc.copyCell(table: id, from: .init(row: 2, column: 2), to: .init(row: 0, column: 3)),
      on: doc, "out of bounds")
    grid = try named(doc, "Grid")
    let broken = try #require(source(grid, 0, 3))
    #expect(broken.hasPrefix("=#REF!{\(id.string)/"))
    doc = try commit(doc.insertRows(table: id, at: 0, count: 2), on: doc, "reuse")
    #expect(source(try named(doc, "Grid"), 2, 3) == broken)
  }

  @Test func rectangularClipboardAndPlainTextFallback() throws {
    var doc = try grid(
      columns: 4, rows: 4, cells: [["1", "2", "=A2*2", "=$A$2+B2"], ["3", "4", "5"]])
    let id = try named(doc, "Grid").id
    let rectangle = TableCellRectangle(rows: 0..<2, columns: 2..<4)
    let clipboard = try doc.clipboard(table: id, rectangle: rectangle)
    #expect(clipboard.version == TableClipboardRange.currentVersion && clipboard.originTable == id)
    #expect(clipboard.cells.map { $0.map(\.origin) }.flatMap { $0 }.count == 4)
    doc = try commit(
      doc.paste(clipboard, table: id, at: .init(row: 2, column: 2)), on: doc, "paste")
    var grid = try named(doc, "Grid")
    #expect(source(grid, 2, 2) == "=A4*2")
    #expect(source(grid, 2, 3) == "=$A$2+B4")
    #expect(source(grid, 3, 2) == "5")
    #expect(source(grid, 3, 3) == nil)
    #expect(throws: TableTransformError.invalidPosition) {
      try doc.paste(clipboard, table: id, at: .init(row: 3, column: 2))
    }

    // Plain TSV is the fallback; it has no origin, so formulas need the
    // explicit choice and then bind where they land, untranslated.
    let text = try doc.plainText(table: id, rectangle: rectangle)
    #expect(text == "=A2*2\t=$A$2+B2\n5\t")
    #expect(throws: TableTransformError.formulaPasteNotConfirmed) {
      try doc.pastePlainText(text, table: id, at: .init(row: 2, column: 0), formulas: false)
    }
    doc = try commit(
      doc.pastePlainText(text, table: id, at: .init(row: 2, column: 0), formulas: true), on: doc,
      "formula paste")
    grid = try named(doc, "Grid")
    #expect(source(grid, 2, 0) == "=A2*2")
    #expect(source(grid, 3, 1) == nil)
    let entry = try #require(
      grid.ledger.first { $0.owner == .cell(row: grid.rows[2], column: grid.columns[0].id) })
    #expect(
      entry.bindings.map(\.target) == [
        .cell(table: id, row: grid.rows[0], column: grid.columns[0].id)
      ])
    #expect(throws: TableTransformError.invalidPosition) {
      try doc.pastePlainText("1\t2\t3", table: id, at: .init(row: 0, column: 2), formulas: false)
    }
    #expect(
      TableSourceDocument.tabSeparated("\"a\tb\"\t\"say \"\"hi\"\"\"\r\n1\t\n")
        == [["a\tb", "say \"hi\""], ["1", ""]])
  }

  // MARK: - Move

  @Test func moveKeepsIdentitiesAndRejectsAmbiguousOrOutOfBoundsMoves() throws {
    var doc = try grid(
      columns: 3, rows: 4, cells: [["1", "=A2+$A$3"], ["2", "=sum(A2:A3)"]],
      readers: ["=Grid!A2"])
    let original = try named(doc, "Grid")
    let ledger = original.ledger
    doc = try commit(
      doc.move(
        table: original.id, rectangle: .init(rows: 0..<2, columns: 1..<2),
        to: .init(row: 1, column: 2)), on: doc, "overlapping move")
    let moved = try named(doc, "Grid")
    #expect(source(moved, 1, 2) == "=A2+$A$3")
    #expect(source(moved, 2, 2) == "=sum(A2:A3)")
    #expect(source(moved, 0, 1) == nil && source(moved, 1, 1) == nil)
    #expect(
      moved.ledger.map { $0.bindings.map(\.target) }.sorted { "\($0)" < "\($1)" }
        == ledger.map { $0.bindings.map(\.target) }.sorted { "\($0)" < "\($1)" })
    #expect(source(try named(doc, "Read"), 0, 0) == "=Grid!A2")

    #expect(throws: TableTransformError.invalidPosition) {
      try doc.move(
        table: original.id, rectangle: .init(rows: 0..<2, columns: 0..<2),
        to: .init(row: 3, column: 0))
    }
    let ruled = try commit(
      doc.setColumnRule(table: original.id, column: original.columns[0].id, source: "=C2"),
      on: doc, "rule")
    #expect(throws: TableTransformError.invalidSelection) {
      try ruled.move(
        table: original.id, rectangle: .init(rows: 2..<4, columns: 0..<1),
        to: .init(row: 2, column: 1))
    }
  }

  // MARK: - Copy table and sheet

  @Test func duplicationRemintsAndRebindsOnlyVisibleTargets() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    let summary = try named(doc, "Summary")
    doc = try commit(
      doc.duplicateTable(items.id, named: "Items copy", atUTF8: doc.source.utf8.count), on: doc,
      "duplicate table")
    let copy = try named(doc, "Items copy")
    #expect(copy.id != items.id && Set(copy.rows).isDisjoint(with: items.rows))
    #expect(copy.columns[2].rule == "=[@Qty] * [@Price]")
    #expect(try named(doc, "Summary") == summary)

    // Inserted before Items, a Summary copy cannot see it.
    doc = try commit(
      doc.duplicateTable(summary.id, named: "Early", atUTF8: 0), on: doc, "early duplicate")
    let early = try named(doc, "Early")
    #expect((0..<4).allSatisfy { source(early, $0, 0)?.contains("#REF!{") == true })

    let sheet = try commit(doc.duplicateSheet(), on: doc, "duplicate sheet")
    let tables = sheet.blocks.compactMap(\.table)
    #expect(tables.map(\.name) == ["Early", "Items", "Summary", "Items copy"])
    #expect(
      Set(tables.map(\.id)).isDisjoint(with: doc.blocks.compactMap(\.table).map(\.id)))
    #expect(value(try calculate(sheet), try named(sheet, "Summary"), 0, 0) == number(75))
  }

  // MARK: - Column rules and totals

  @Test func changingARuleUpdatesInheritedCellsAndKeepsMarkedOverrides() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    let amount = items.columns[2].id
    doc = try commit(
      doc.setCell(table: items.id, at: .init(row: 1, column: 2), source: "=100"), on: doc)
    doc = try commit(
      doc.setColumnRule(table: items.id, column: amount, source: "=[@Qty] * [@Price] * 2"),
      on: doc, "rule change")
    var table = try named(doc, "Items")
    #expect(table.cells.first { $0.column == amount }?.isOverride == true)
    var results = try calculate(doc)
    #expect(value(results, table, 0, 2) == number(20))
    #expect(value(results, table, 1, 2) == number(100))
    #expect(value(results, table, 2, 2) == number(88))
    doc = try commit(
      doc.setColumnRule(table: items.id, column: amount, source: nil), on: doc, "rule removed")
    table = try named(doc, "Items")
    #expect(table.cells.filter { $0.column == amount }.map(\.isOverride) == [false])
    results = try calculate(doc)
    #expect(value(results, table, 0, 2) == .blank)
  }

  @Test func totalsAreConfigurationNeverDataMembers() throws {
    var doc = try budget()
    let items = try named(doc, "Items")
    let amount = items.columns[2].id
    doc = try commit(doc.setColumnTotal(table: items.id, column: amount, total: .sum), on: doc)
    #expect(doc.source.contains("\"z\":\"sum\""))
    doc = try commit(doc.insertRows(table: items.id, at: 1), on: doc, "insert")
    doc = try commit(doc.deleteRows(table: items.id, in: 3..<4), on: doc, "delete")
    doc = try commit(doc.appendRows(table: items.id), on: doc, "append")
    for (row, input) in [(1, "1\t1"), (3, "1\t2")] {
      doc = try commit(
        doc.pastePlainText(input, table: items.id, at: .init(row: row, column: 0), formulas: false),
        on: doc)
    }
    let table = try named(doc, "Items")
    #expect(table.columns[2].total == .sum)
    let summary = try named(doc, "Summary")
    // C:C and Items[Amount] read the data rows (2×5, 1×1, 3×7, 1×2) only,
    // never a footer.
    let results = try calculate(doc)
    #expect(value(results, summary, 0, 0) == number(34))
    #expect(value(results, summary, 3, 0) == number(34))
    doc = try commit(doc.setColumnTotal(table: items.id, column: amount, total: nil), on: doc)
    #expect(try named(doc, "Items").columns[2].total == nil)

    doc = try commit(
      doc.setColumnInput(
        table: items.id, column: items.columns[1].id, policy: .value, currency: "USD"),
      on: doc, "currency")
    #expect(try named(doc, "Items").columns[1].currency == "USD")
    #expect(throws: (any Error).self) {
      try doc.setColumnInput(
        table: items.id, column: items.columns[1].id, policy: .text, unit: "kg")
    }
  }

  // MARK: - Rule templates

  @Test func ruleTemplatesAcrossZeroOneAndFirstRowEdits() throws {
    var doc = try grid(columns: 2, rows: 0)
    let id = try named(doc, "Grid").id
    let column = try named(doc, "Grid").columns[1].id
    doc = try commit(doc.setColumnRule(table: id, column: column, source: "=A2*2"), on: doc)
    // Zero rows: the virtual row-2 anchor instantiates on the first append.
    doc = try commit(doc.appendRows(table: id), on: doc, "first append")
    doc = try commit(doc.setCell(table: id, at: .init(row: 0, column: 0), source: "3"), on: doc)
    var results = try calculate(doc)
    var grid = try named(doc, "Grid")
    #expect(value(results, grid, 0, 1) == number(6))
    // One row: delete it, then append again.
    doc = try commit(doc.deleteRows(table: id, in: 0..<1), on: doc, "delete only row")
    #expect(try named(doc, "Grid").columns[1].rule == "=A2*2")
    doc = try commit(doc.appendRows(table: id, count: 2), on: doc, "append two")
    doc = try commit(
      doc.pastePlainText("4\n5", table: id, at: .init(row: 0, column: 0), formulas: false), on: doc)
    #expect(
      try doc.plainText(table: id, rectangle: .init(rows: 0..<2, columns: 0..<2))
        == "4\t=A2*2\n5\t=A3*2")
    // First-row insertion and deletion rebase the template on the first row.
    doc = try commit(doc.insertRows(table: id, at: 0), on: doc, "first insert")
    doc = try commit(doc.setCell(table: id, at: .init(row: 0, column: 0), source: "7"), on: doc)
    grid = try named(doc, "Grid")
    #expect(grid.columns[1].rule == "=A2*2")
    results = try calculate(doc)
    #expect((0..<3).map { value(results, grid, $0, 1) } == [number(14), number(8), number(10)])
    doc = try commit(doc.deleteRows(table: id, in: 0..<1), on: doc, "first delete")
    grid = try named(doc, "Grid")
    results = try calculate(doc)
    #expect((0..<2).map { value(results, grid, $0, 1) } == [number(8), number(10)])
  }

  // MARK: - Seeded random sequences

  private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  /// One random structural edit, or `nil` when the choice is invalid for the
  /// current shape (the API rejects it without changing source).
  private func randomEdit(_ doc: TableSourceDocument, _ rng: inout SplitMix) throws
    -> TableSourceEdit?
  {
    let tables = doc.blocks.compactMap(\.table)
    let table = tables[Int.random(in: 0..<tables.count, using: &rng)]
    let rows = table.rows.count
    let columns = table.columns.count
    func position() -> TableCellPosition? {
      rows == 0
        ? nil
        : .init(
          row: Int.random(in: 0..<rows, using: &rng),
          column: Int.random(in: 0..<columns, using: &rng))
    }
    func address() -> String {
      Self.letter(Int.random(in: 0..<(columns + 1), using: &rng))
        + String(Int.random(in: 1...(rows + 2), using: &rng))
    }
    let header = table.columns[Int.random(in: 0..<columns, using: &rng)].header
    let other = tables.first { $0.id != table.id }
    let formulas = [
      "=" + address(), "=$" + address(), "=sum(\(address()):\(address()))",
      "=sum(A:\(Self.letter(columns - 1)))", "=[@[\(header)]] + 1",
      "=sum(\(table.name)[\(header)])",
      other.map { "=\($0.name)!" + address() } ?? "=1", "=" + address() + " * 2",
    ]
    switch Int.random(in: 0..<15, using: &rng) {
    case 0: return try doc.insertRows(table: table.id, at: Int.random(in: 0...rows, using: &rng))
    case 1:
      guard rows > 0 else { return nil }
      let start = Int.random(in: 0..<rows, using: &rng)
      return try doc.deleteRows(
        table: table.id, in: start..<min(rows, start + Int.random(in: 1...2, using: &rng)))
    case 2: return try doc.appendRows(table: table.id)
    case 3:
      return try doc.insertColumn(
        table: table.id, at: Int.random(in: 0...columns, using: &rng),
        header: "H\(Int.random(in: 0..<1000, using: &rng))")
    case 4:
      guard columns > 1 else { return nil }
      let start = Int.random(in: 0..<columns, using: &rng)
      return try doc.deleteColumns(table: table.id, in: start..<(start + 1))
    case 5, 6:
      guard let position = position() else { return nil }
      return try doc.setCell(
        table: table.id, at: position,
        source: Bool.random(using: &rng)
          ? String(Int.random(in: 0..<100, using: &rng))
          : formulas[Int.random(in: 0..<formulas.count, using: &rng)])
    case 7:
      guard let from = position(), let to = position() else { return nil }
      return try doc.copyCell(table: table.id, from: from, to: to)
    case 8:
      guard let from = position(), let to = position() else { return nil }
      return try doc.fill(
        table: table.id, from: from,
        into: .init(
          rows: min(from.row, to.row)..<(max(from.row, to.row) + 1),
          columns: to.column..<(to.column + 1)))
    case 9:
      guard let from = position(), let to = position() else { return nil }
      return try doc.move(
        table: table.id,
        rectangle: .init(rows: from.row..<(from.row + 1), columns: from.column..<(from.column + 1)),
        to: to)
    case 10:
      return try doc.renameTable(
        table.id,
        to: table.name.hasSuffix(" 2") ? String(table.name.dropLast(2)) : table.name + " 2")
    case 11:
      let column = table.columns[Int.random(in: 0..<columns, using: &rng)]
      return try doc.renameColumn(table: table.id, column: column.id, to: column.header + "x")
    case 12:
      let column = table.columns[Int.random(in: 0..<columns, using: &rng)]
      return try doc.setColumnRule(
        table: table.id, column: column.id,
        source: column.rule == nil ? formulas[Int.random(in: 0..<formulas.count, using: &rng)] : nil
      )
    case 13:
      let column = table.columns[Int.random(in: 0..<columns, using: &rng)]
      return try doc.setColumnTotal(
        table: table.id, column: column.id, total: column.total == nil ? .sum : nil)
    default:
      guard let from = position(), let to = position() else { return nil }
      let clipboard = try doc.clipboard(
        table: table.id,
        rectangle: .init(rows: from.row..<(from.row + 1), columns: 0..<min(2, columns)))
      return try doc.paste(clipboard, table: table.id, at: .init(row: to.row, column: 0))
    }
  }

  @Test(arguments: [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233] as [UInt64])
  func randomSequencesUndoToTheOriginalBytesAndRedoToTheFinalBytes(seed: UInt64) throws {
    var rng = SplitMix(state: seed)
    let original = try grid(
      columns: 3, rows: 3,
      cells: [["1", "2", "=A2+B2"], ["3", "=sum(A2:A4)"], ["5", "6", "=$A$3"]],
      readers: ["=Grid!A3", "=sum(Grid!A2:B3)", "=sum(Grid[A])"],
      prose: "z = Grid!B3 + sum(Grid!A2:B4)\n// Grid!B3 untouched\n")
    var doc = original
    var history: [Recorded] = []
    var applied = 0
    for step in 0..<40 {
      let edit: TableSourceEdit?
      do {
        edit = try randomEdit(doc, &rng)
      } catch is TableTransformError {
        continue
      } catch let error as TableBlockError {
        // A contract rejection (duplicate header/name, admission) is fine.
        #expect(error.code != .staleBinding, "seed \(seed) step \(step): \(error.detail)")
        continue
      } catch {
        Issue.record("seed \(seed) step \(step): unexpected \(error)")
        continue
      }
      guard let edit else { continue }
      let before = doc.source
      doc = try commit(edit, on: doc, "seed \(seed) step \(step)")
      history.append(Recorded(before: before, edit: edit, after: doc.source))
      #expect(doc.source.contains("// Grid!B3 untouched\n"))
      applied += 1
    }
    #expect(applied >= 10, "seed \(seed) applied only \(applied) edits")

    var undone = doc.source
    for recorded in history.reversed() {
      undone = try TableSourcePatch.applying(Self.inverse(recorded.edit.patches), to: undone)
      #expect(Array(undone.utf8) == Array(recorded.before.utf8))
    }
    #expect(Array(undone.utf8) == Array(original.source.utf8))
    #expect(TableSourceDocument(undone).blocks.map(\.table) == original.blocks.map(\.table))
    var redone = undone
    for recorded in history { redone = try recorded.edit.applying(to: redone) }
    #expect(Array(redone.utf8) == Array(doc.source.utf8))
    Self.expectConsistent(TableSourceDocument(redone), "seed \(seed) redone")
  }
}
