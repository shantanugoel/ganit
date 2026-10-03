import Foundation
import Testing

@testable import GanitEngine

/// Independent contract tests for the M3 task 1 structural transformations.
///
/// Every expectation here comes from the normative contracts, not from what the
/// implementation happens to produce:
/// - `docs/plans/tables-implementation.md` "Contract to implement", "Addressing",
///   "Structural edit semantics", "Identity in source and after reload".
/// - `docs/adr/0016-table-semantics-and-editor-ownership.md` "Reference grammar",
///   "Exact structural transformations".
/// - `docs/adr/0017-table-source-and-storage.md` ledger, identity, byte fidelity.
/// - `docs/storage/table-blocks.md` frozen wire format v1.
@Suite struct TableTransformContractTests {
  // MARK: - A1 spelling required by the reference grammar

  /// Column letters are ASCII letters, case-insensitive, one-based (ADR 0016
  /// "Reference grammar"); the header row is 1 and data starts at row 2.
  private func letter(_ column: Int) -> String {
    var number = column + 1
    var result = ""
    while number > 0 {
      number -= 1
      result = String(UnicodeScalar(UInt8(65 + number % 26))) + result
      number /= 26
    }
    return result
  }
  private func address(_ row: Int, _ column: Int) -> String {
    letter(column) + String(row + 2)
  }

  // MARK: - Fixtures

  /// A sheet holding one valid version 1 block with `columnCount` value columns
  /// headed `A`, `B`, … and `rowCount` data rows.
  private func document(
    named name: String = "Items", columnCount: Int = 2, rowCount: Int = 3,
    cells: [(row: Int, column: Int, source: String)] = [],
    lineEnding: LineTerminator = .lineFeed
  ) throws -> TableSourceDocument {
    var table = TableModel.creating(
      name: name,
      headers: (0..<columnCount).map { ($0, letter($0)) }.map { ($0.1, TableInputPolicy.value) },
      rowCount: rowCount)
    for cell in cells {
      table.cells.append(
        TableCell(
          row: table.rows[cell.row], column: table.columns[cell.column].id, source: cell.source))
    }
    return TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: table, lineEnding: lineEnding))
  }

  /// Applies every returned patch as one transaction, then re-parses the
  /// resulting source, so each test asserts identities after reload rather than
  /// rendered text alone. Contract: `TableSourcePatch.applying` is all-or-nothing
  /// and a successful structural edit leaves a document with no new diagnostic
  /// ("Successful structural edits rewrite both together", plan "Identity in
  /// source and after reload").
  @discardableResult
  private func apply(
    _ edit: TableSourceEdit, to before: TableSourceDocument, note: String = ""
  ) throws -> TableSourceDocument {
    let after = TableSourceDocument(try edit.applying(to: before.source))
    let known = Set(before.diagnostics.map(\.code))
    let unexpected = after.diagnostics.filter { !known.contains($0.code) }
    let detail = unexpected.map { "\($0.code) \($0.detail)" }.joined(separator: "; ")
    #expect(unexpected.isEmpty, "unexpected diagnostics after \(note): \(detail)")
    return after
  }

  struct MissingTable: Error {}

  private func table(_ document: TableSourceDocument, _ name: String = "Items") throws
    -> TableModel
  {
    guard let found = document.blocks.compactMap(\.table).first(where: { $0.name == name }) else {
      Issue.record("no projected table named \(name)")
      throw MissingTable()
    }
    return found
  }

  /// The exact source of one data cell after reload.
  private func source(
    _ table: TableModel, at position: TableCellPosition, inherit: String = ""
  ) -> String {
    let row = table.rows[position.row]
    let column = table.columns[position.column]
    guard
      let cell = table.cells.first(where: { $0.row == row && $0.column == column.id })
    else { return inherit }
    return cell.source
  }

  /// The bound operands of one data cell's formula after reload.
  private func bindings(_ table: TableModel, at position: TableCellPosition) -> [TableBinding] {
    let row = table.rows[position.row]
    let column = table.columns[position.column]
    return table.ledger.first { $0.owner == .cell(row: row, column: column.id) }?.bindings ?? []
  }

  private func ruleBindings(_ table: TableModel, _ column: Int) -> [TableBinding] {
    table.ledger.first { $0.owner == .rule(column: table.columns[column].id) }?.bindings ?? []
  }

  /// The identity a `cell` binding names, as an A1 coordinate of `table`.
  private func coordinate(_ table: TableModel, _ binding: TableBinding) -> String {
    guard case .cell(_, let row, let column) = binding.target,
      let columnIndex = table.columns.firstIndex(where: { $0.id == column })
    else { return "?" }
    let rowNumber = row.flatMap { r in table.rows.firstIndex(of: r).map { $0 + 2 } } ?? 1
    return letter(columnIndex) + String(rowNumber)
  }

  // MARK: - Insertion moves every coordinate, locked ones included

  @Test(arguments: [true, false])
  func rowInsertionMovesLockedAndUnlockedCoordinates(columnInsertion: Bool) throws {
    // ADR 0016 "Exact structural transformations": "Bind scalars to stable
    // target identities, independent of copy locks. Insertions move their
    // rendered coordinates, including locked coordinates."
    let doc = try document(
      columnCount: 3, rowCount: 3,
      cells: [(row: 1, column: 1, source: "=A2+$B$2+B$2+$B2")])
    let id = try table(doc).id
    let edited = try apply(
      columnInsertion
        ? doc.insertColumn(table: id, at: 0, header: "New") : doc.insertRows(table: id, at: 0),
      to: doc, note: "insertion")
    let reloaded = try table(edited)
    // The bound identities are unchanged, so every spelling moves by one: the
    // target's coordinate changes, its copy locks do not. The cell follows its
    // own row/column identity, so a row insertion moves it to row index 2.
    let position = TableCellPosition(row: columnInsertion ? 1 : 2, column: columnInsertion ? 2 : 1)
    let expected = columnInsertion ? "=B2+$C$2+C$2+$C2" : "=A3+$B$3+B$3+$B3"
    #expect(source(reloaded, at: position) == expected)
    // Identity, not text: the same row and column IDs are still bound.
    let bound = bindings(reloaded, at: position)
    #expect(bound.count == 4)
    let original = try table(doc)
    #expect(bound.allSatisfy { !$0.isDeleted })
    #expect(bound[0].target.columnID == original.columns[0].id)
    #expect(bound[0].target.rowID == original.rows[0])
    #expect(bound[1].target.rowID == original.rows[0])
    #expect(bound[1].target.columnID == original.columns[1].id)
  }

  // MARK: - The three insertion boundary cases

  @Test(arguments: [
    BoundaryCase.beforeFirstMember, .beforeLastMember, .appendAfterFinal, .strictlyInside,
  ])
  func rectangleInsertionBoundaries(case kind: BoundaryCase) throws {
    // ADR 0016: "An insertion at index `p` before existing `[a,b]` shifts both
    // bounds when `p <= a`, expands the upper bound when `a < p <= b`, and
    // leaves it unchanged when `p > b` … An insertion immediately before the
    // first member is outside; immediately before the last member is inside.
    // Appending after the final member is outside."
    let doc = try document(
      rowCount: 5, cells: [(row: 4, column: 0, source: "=sum(A3:A5)")])
    let id = try table(doc).id
    let edited = try apply(doc.insertRows(table: id, at: kind.insertionIndex), to: doc)
    #expect(
      source(try table(edited), at: .init(row: kind.expectedFormulaRow, column: 0))
        == kind.expectedSource)
  }
  enum BoundaryCase: CaseIterable {
    case beforeFirstMember, beforeLastMember, appendAfterFinal, strictlyInside

    var insertionIndex: Int {
      switch self {
      case .beforeFirstMember: return 1  // index of the range's first member
      case .beforeLastMember: return 3  // index of the range's last member
      case .appendAfterFinal: return 4  // one past the range's last member
      case .strictlyInside: return 2
      }
    }
    var expectedSource: String {
      switch self {
      case .beforeFirstMember: return "=sum(A4:A6)"  // shifted, so the new row stays outside
      case .beforeLastMember, .strictlyInside: return "=sum(A3:A6)"  // expanded, so it is inside
      case .appendAfterFinal: return "=sum(A3:A5)"  // unchanged
      }
    }
    // Every case puts the new row at or before the formula cell's own row, so
    // the cell ends at row index 5 in all four.
    var expectedFormulaRow: Int { 5 }
  }

  // MARK: - Endpoint deletion shrinks to surviving members

  @Test(arguments: [Endpoint.first, .last])
  func rectangleEndpointDeletionShrinksWithoutAdjacentOutsideMember(case endpoint: Endpoint)
    throws
  {
    // Plan "Structural edit semantics": "Delete a rectangular endpoint |
    // Surviving included rows/columns become the new bounds; do not accidentally
    // include an adjacent outside row". ADR 0016: "take first/last surviving
    // included identities, never an adjacent outside member".
    let doc = try document(
      rowCount: 5, cells: [(row: 4, column: 0, source: "=sum(A3:A5)")])
    let id = try table(doc).id
    let deleted = try apply(
      doc.deleteRows(table: id, in: endpoint.deletionRange), to: doc, note: "endpoint delete")
    let reloaded = try table(deleted)
    // Rows R0,R1,R2,R3,R4 hold the range R1…R3. Removing one endpoint leaves
    // two members: the surviving bounds are A3 and A4. A2 (the outside row
    // above) and A5 (the outside row below) must not join.
    #expect(source(reloaded, at: .init(row: 3, column: 0)) == "=sum(A3:A4)")
    let binding = bindings(reloaded, at: .init(row: 3, column: 0))[0]
    guard case .rectangle(_, let rows, _) = binding.target,
      case .interval(let first, let last) = rows
    else {
      Issue.record("a surviving rectangle keeps interval membership")
      return
    }
    #expect(!binding.isDeleted)
    let survivors: [RowID]
    switch endpoint {
    case .first: survivors = [reloaded.rows[1], reloaded.rows[2]]
    case .last: survivors = [reloaded.rows[1], reloaded.rows[2]]
    }
    #expect(first == survivors[0] && last == survivors[1])
  }
  enum Endpoint {
    case first, last
    var deletionRange: Range<Int> { self == .first ? 1..<2 : 3..<4 }
  }

  @Test func columnEndpointDeletionShrinksWithoutAdjacentOutsideColumn() throws {
    let doc = try document(
      columnCount: 3, rowCount: 3,
      cells: [(row: 2, column: 2, source: "=sum(B2:C3)")])
    let id = try table(doc).id
    let deleted = try apply(doc.deleteColumns(table: id, in: 0..<1), to: doc)
    let reloaded = try table(deleted)
    // Columns A,B were the range; deleting A leaves only B, which becomes A.
    // Column C (the adjacent outside column) must not join.
    #expect(source(reloaded, at: .init(row: 2, column: 1)) == "=sum(A2:B3)")
  }

  // MARK: - Full-axis death produces a broken range that survives reload

  @Test func deletingEveryRangeMemberPersistsABrokenRangeAcrossReload() throws {
    // Plan: "Delete inside a rectangle | … if no referenced data survives,
    // persist a broken range". ADR 0016: "No survivors on either axis produces
    // a broken range." table-blocks.md: "A deleted range keeps its original
    // ordered members … and at least one axis has no surviving member."
    let doc = try document(rowCount: 4, cells: [(row: 3, column: 0, source: "=sum(A2:A3)")])
    let id = try table(doc).id
    let deletedRows = Array(try table(doc).rows[0..<2])
    let broken = try apply(doc.deleteRows(table: id, in: 0..<2), to: doc, note: "range death")
    let reloaded = try table(broken)
    let formula = source(reloaded, at: .init(row: 1, column: 0))
    let binding = bindings(reloaded, at: .init(row: 1, column: 0))[0]
    #expect(binding.isDeleted)
    #expect(formula == "=sum(" + binding.brokenMarker + ")")
    #expect(binding.brokenMarker.hasPrefix("#REF!{range:"))
    // ADR 0017: "Deleted target IDs remain in the dictionary even when their
    // rows disappear. Never omit them and thereby bind an old pointer to a new
    // record."
    let ids = broken.blocks[0].json!["ids"]!.array!.compactMap(\.string)
    for row in deletedRows {
      #expect(ids.contains(row.string), "deleted row identity dropped from the dictionary")
    }
    // A second reload of the same bytes keeps the marker byte for byte.
    let again = TableSourceDocument(broken.source)
    #expect(again.diagnostics.isEmpty)
    #expect(try source(table(again), at: .init(row: 1, column: 0)) == formula)
  }

  @Test func coordinateReuseNeverRepairsABrokenScalarOrRange() throws {
    // ADR 0016: "Deletion writes a persistent broken operand. Reusing an
    // address never repairs it." Plan: "reuse of its old coordinate cannot
    // repair it".
    let doc = try document(
      rowCount: 4,
      cells: [(row: 3, column: 0, source: "=A2"), (row: 2, column: 1, source: "=sum(A2:A3)")])
    let id = try table(doc).id
    let broken = try apply(doc.deleteRows(table: id, in: 0..<2), to: doc, note: "delete targets")
    let scalarMarker = try source(table(broken), at: .init(row: 1, column: 0))
    let rangeMarker = try source(table(broken), at: .init(row: 0, column: 1))
    #expect(scalarMarker.hasPrefix("=#REF!{"))
    #expect(rangeMarker.hasPrefix("=sum(#REF!{"))
    // Recreate the same coordinates at the same position.
    let refilled = try apply(broken.insertRows(table: id, at: 0, count: 2), to: broken)
    #expect(source(try table(refilled), at: .init(row: 3, column: 0)) == scalarMarker)
    #expect(source(try table(refilled), at: .init(row: 2, column: 1)) == rangeMarker)
    let bindings = bindings(try table(refilled), at: .init(row: 2, column: 1))
    #expect(bindings.count == 1 && bindings[0].isDeleted)
  }

  // MARK: - Whole-column and named ranges grow; finite rectangles do not

  @Test(arguments: ["=sum(A:A)", "=sum(Items[A])", "=sum(A2:A3)"])
  func appendingARowGrowsOnlyDynamicRanges(_ formula: String) throws {
    // Plan "Structural edit semantics": "Append a row | Named/whole-column
    // ranges grow; a finite rectangle does not grow merely because a row was
    // appended after it". ADR 0016: "Whole-column and named-column ranges
    // dynamically include all data rows".
    let doc = try document(
      rowCount: 3, cells: [(row: 2, column: 1, source: formula)])
    let id = try table(doc).id
    let appended = try apply(doc.insertRows(table: id, at: 3), to: doc, note: "append")
    let reloaded = try table(appended)
    // None of the three spellings is rewritten by an append: whole-column and
    // named membership is dynamic, and a finite rectangle must not grow.
    // The formula cell keeps its own row identity, so it stays at row index 2:
    // an append after it does not move it.
    #expect(source(reloaded, at: .init(row: 2, column: 1)) == formula)
    let binding = bindings(reloaded, at: .init(row: 2, column: 1))[0]
    #expect(!binding.isDeleted)
    switch formula {
    case "=sum(A:A)":
      #expect(binding.target.kind == "cols")
      guard case .columns(_, let axis) = binding.target, case .interval = axis else {
        Issue.record("a whole-column range stays a live interval")
        return
      }
    case "=sum(Items[A])":
      #expect(binding.target.kind == "named")
    default:
      #expect(binding.target.kind == "rect")
      guard case .rectangle(_, let rows, _) = binding.target,
        case .interval(let first, let last) = rows
      else {
        Issue.record("the finite rectangle keeps interval membership")
        return
      }
      #expect([first, last] == [reloaded.rows[0], reloaded.rows[1]])
    }
  }

  @Test func insertionInsideADynamicRangeKeepsItDynamic() throws {
    let doc = try document(
      rowCount: 3, cells: [(row: 2, column: 1, source: "=sum(A:A)+sum(Items[A])")])
    let id = try table(doc).id
    let inside = try apply(doc.insertRows(table: id, at: 1), to: doc)
    let reloaded = try table(inside)
    #expect(source(reloaded, at: .init(row: 3, column: 1)) == "=sum(A:A)+sum(Items[A])")
    let bound = bindings(reloaded, at: .init(row: 3, column: 1))
    #expect(bound.map(\.target.kind) == ["cols", "named"])
  }

  @Test func qualifiedRowRangeFollowsRowInsertion() throws {
    // The axis rule applies "independently to rows and columns".
    let doc = try document(rowCount: 4, cells: [(row: 3, column: 0, source: "=sum(Items!2:3)")])
    let id = try table(doc).id
    let inside = try apply(doc.insertRows(table: id, at: 1), to: doc)
    #expect(source(try table(inside), at: .init(row: 4, column: 0)) == "=sum(Items!2:4)")
    let outside = try apply(doc.insertRows(table: id, at: 3), to: doc)
    #expect(source(try table(outside), at: .init(row: 4, column: 0)) == "=sum(Items!2:3)")
  }

  // MARK: - Copy translates unlocked axes and holds locked axes

  @Test func copyTranslatesUnlockedAxesAndHoldsLockedAxes() throws {
    // Plan: "Copy/fill formula | Translate unlocked axes from source cell to
    // destination; locked axes stay fixed". ADR 0016: "Copy/fill translates
    // unlocked axis offsets; locks hold targets."
    let doc = try document(
      columnCount: 3, rowCount: 3,
      cells: [(row: 1, column: 1, source: "=A2+$B$2+B$2+$B2")])
    let id = try table(doc).id
    let copied = try apply(
      doc.copyCell(table: id, from: .init(row: 1, column: 1), to: .init(row: 2, column: 2)),
      to: doc, note: "copy diagonally")
    let reloaded = try table(copied)
    #expect(
      source(reloaded, at: .init(row: 2, column: 2)) == "=B3+$B$2+C$2+$B3")
    let bound = bindings(reloaded, at: .init(row: 2, column: 2))
    #expect(bound.count == 4)
    // Unlocked axes moved to new identities; locked axes kept theirs.
    #expect(
      bound[0].target.rowID == reloaded.rows[1]
        && bound[0].target.columnID == reloaded.columns[1].id)
    #expect(
      bound[1].target.rowID == reloaded.rows[0]
        && bound[1].target.columnID == reloaded.columns[1].id)
    #expect(
      bound[2].target.rowID == reloaded.rows[0]
        && bound[2].target.columnID == reloaded.columns[2].id)
    #expect(
      bound[3].target.rowID == reloaded.rows[1]
        && bound[3].target.columnID == reloaded.columns[1].id)
    // The source cell keeps its own formula.
    #expect(source(reloaded, at: .init(row: 1, column: 1)) == "=A2+$B$2+B$2+$B2")
  }

  @Test func fillTranslatesEachDestinationIndependently() throws {
    let doc = try document(
      columnCount: 3, rowCount: 3,
      cells: [(row: 0, column: 0, source: "=A2+B$2")])
    let id = try table(doc).id
    let filled = try apply(
      doc.fill(
        table: id, from: .init(row: 0, column: 0),
        into: TableCellRectangle(rows: 0..<3, columns: 0..<2)),
      to: doc, note: "fill")
    let reloaded = try table(filled)
    for row in 0..<3 {
      for column in 0..<2 {
        let position = TableCellPosition(row: row, column: column)
        guard position != .init(row: 0, column: 0) else { continue }
        let expected =
          "=" + address(row, column) + "+" + letter(1 + column) + "$2"
        #expect(
          source(reloaded, at: position) == expected,
          "fill into \(address(position.row, position.column))")
      }
    }
  }

  @Test(arguments: [OutOfBounds.axisRow, .axisColumn])
  func outOfBoundsCopyPersistsABrokenTarget(case axis: OutOfBounds) throws {
    // Plan: "out-of-bounds translations become persistent broken references".
    // ADR 0016: "Translation outside bounds persists a broken target."
    let doc = try document(
      columnCount: 2, rowCount: 3,
      cells: [(row: axis.sourceRow, column: axis.sourceColumn, source: axis.source)])
    let id = try table(doc).id
    let copied = try apply(
      doc.copyCell(table: id, from: axis.origin, to: axis.destination), to: doc,
      note: "out-of-bounds copy")
    let reloaded = try table(copied)
    let formula = source(reloaded, at: axis.destination)
    #expect(formula.hasPrefix("=#REF!{"))
    #expect(bindings(reloaded, at: axis.destination)[0].isDeleted)
    // Persistence: making the coordinate exist again must not revive it.
    let grown = try apply(
      axis == .axisRow
        ? copied.insertRows(table: id, at: 0)
        : copied.insertColumn(table: id, at: 0, header: "New"),
      to: copied, note: "coordinate reuse")
    #expect(
      source(try table(grown), at: axis.grownDestination) == formula,
      "a broken copy target was repaired by coordinate reuse")
  }
  enum OutOfBounds {
    case axisRow, axisColumn
    var source: String { self == .axisRow ? "=A2" : "=B2" }
    var sourceRow: Int { self == .axisRow ? 2 : 0 }
    var sourceColumn: Int { self == .axisRow ? 0 : 0 }
    var origin: TableCellPosition { .init(row: sourceRow, column: sourceColumn) }
    var destination: TableCellPosition {
      self == .axisRow ? .init(row: 0, column: 0) : .init(row: 0, column: 1)
    }
    /// The broken cell follows the row or column inserted before it, so the
    /// assertion reads the same cell, not the newly created one.
    var grownDestination: TableCellPosition {
      self == .axisRow ? .init(row: 1, column: 0) : .init(row: 0, column: 2)
    }
  }

  // MARK: - Move preserves targets and applies no translation

  @Test func movePreservesTargetIdentitiesAndAppliesNoTranslation() throws {
    // Plan: "Move formula/cell | Preserve referenced identities; do not apply
    // copy translation". ADR 0016: "Move retains bindings."
    let doc = try document(
      columnCount: 3, rowCount: 4,
      cells: [(row: 2, column: 2, source: "=A2+B$2")])
    let id = try table(doc).id
    let original = try table(doc)
    let moved = try apply(
      doc.move(
        table: id, rectangle: .init(rows: 2..<3, columns: 2..<3), to: .init(row: 0, column: 0)),
      to: doc, note: "move")
    let reloaded = try table(moved)
    #expect(source(reloaded, at: .init(row: 0, column: 0)) == "=A2+B$2")
    let bound = bindings(reloaded, at: .init(row: 0, column: 0))
    #expect(bound.count == 2)
    #expect(bound[0].target.rowID == original.rows[0])
    #expect(bound[0].target.columnID == original.columns[0].id)
    #expect(bound[1].target.rowID == original.rows[0])
    #expect(bound[1].target.columnID == original.columns[1].id)
    #expect(bound.map(\.locks) == [[false, false], [true, false]])
    #expect(reloaded.cells.count == 1)
  }

  @Test func ambiguousPartialMoveIsRejected() throws {
    // Plan M3: "Reject ambiguous partial moves rather than guessing".
    let doc = try document(rowCount: 2)
    let id = try table(doc).id
    let column = try table(doc).columns[1].id
    let ruled = try apply(
      doc.setColumnRule(table: id, column: column, source: "=A2"), to: doc, note: "rule")
    let before = ruled.source
    #expect(
      throws: (any Error).self,
      "moving one inherited cell out of a rule column must be rejected, not guessed"
    ) {
      _ = try ruled.move(
        table: id, rectangle: .init(rows: 0..<1, columns: 1..<2), to: .init(row: 0, column: 0))
    }
    #expect(ruled.source == before)
  }
}

extension TableReferenceTarget {
  fileprivate var rowID: RowID? {
    switch self {
    case .cell(_, let row, _): return row
    default: return nil
    }
  }
  fileprivate var columnID: ColumnID? {
    switch self {
    case .cell(_, _, let column): return column
    default: return nil
    }
  }
}
