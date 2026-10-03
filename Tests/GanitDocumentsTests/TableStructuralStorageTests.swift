import Foundation
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// Structural table edits survive save → reload through the library and
/// plain-source/package exchange (M3 exit: insert/delete/rename/copy/fill →
/// Undo → redo → save → reload preserve intended targets). Document Undo
/// restores source, so Undo and redo save the earlier and later bytes again.
@Suite
final class TableStructuralStorageTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitTableStructural-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private func url(_ path: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appending(path: path)
  }

  /// Items with a rule column, prose that reads it, and a later reader table.
  private func budget() throws -> TableSourceDocument {
    var items = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Price", .value), ("Amount", .value)],
      rowCount: 3)
    items.columns[2].rule = "=[@Qty] * [@Price]"
    for (row, values) in [["2", "5"], ["3", "7"], ["4", "11"]].enumerated() {
      for (column, value) in values.enumerated() {
        items.cells.append(
          TableCell(row: items.rows[row], column: items.columns[column].id, source: value))
      }
    }
    var summary = TableModel.creating(name: "Summary", headers: [("Value", .value)], rowCount: 3)
    for (row, formula) in ["=sum(Items[Amount])", "=Items!$A$3", "=sum(Items!C2:C3)"].enumerated() {
      summary.cells.append(
        TableCell(row: summary.rows[row], column: summary.columns[0].id, source: formula))
    }
    let source =
      "# Budget\r\n" + (try TableSourceDocument.canonicalBlock(for: items))
      + "total = sum(Items[Amount]) // Items[Amount]\n"
      + (try TableSourceDocument.canonicalBlock(for: summary)) + "check = Items!A3\n"
    return TableSourceDocument(source)
  }

  /// Saves `source`, reloads it, and checks the stored bytes and the
  /// projected tables are exactly the saved ones.
  @discardableResult
  private func saveAndReload(
    _ source: String, _ metadata: SheetMetadata, in library: SheetLibrary
  ) throws -> SheetMetadata {
    let saved = try library.save(source: source, metadata: metadata)
    let loaded = try library.load(id: saved.id)
    #expect(Array(loaded.source.utf8) == Array(source.utf8))
    #expect(loaded.isChecksumValid)
    let reloaded = TableSourceDocument(loaded.source)
    #expect(reloaded.diagnostics.isEmpty)
    #expect(reloaded.blocks.map(\.table) == TableSourceDocument(source).blocks.map(\.table))
    return saved
  }

  @Test
  func libraryDuplicationRemintsTablesAndPreservesResultsAndWidths() throws {
    let library = try SheetLibrary(root: try url("DuplicateLibrary"))
    let document = try budget()
    var metadata = try library.create(preferences: .standard)
    let originalTables = document.blocks.compactMap(\.table)
    let items = try #require(originalTables.first)
    metadata.tables.setWidth(172, column: items.columns[0].id.string, table: items.id.string)
    metadata = try library.save(source: document.source, metadata: metadata)
    let copiedMetadata = try library.duplicate(metadata.id)
    let loaded = try library.load(id: copiedMetadata.id)
    let copiedDocument = TableSourceDocument(loaded.source)
    #expect(copiedDocument.diagnostics.isEmpty)
    let copies = copiedDocument.blocks.compactMap(\.table)
    #expect(copies.count == originalTables.count)
    for (original, copy) in zip(originalTables, copies) {
      #expect(original.id != copy.id)
      #expect(Set(original.rows).isDisjoint(with: Set(copy.rows)))
      #expect(Set(original.columns.map(\.id)).isDisjoint(with: Set(copy.columns.map(\.id))))
      #expect(original.name == copy.name)
    }
    let copiedItems = try #require(copies.first)
    #expect(
      loaded.metadata.tables.byTableID[copiedItems.id.string]?.columnWidths[
        copiedItems.columns[0].id.string] == 172)
    #expect(loaded.metadata.tables.byTableID[items.id.string] == nil)
    #expect(try library.load(id: metadata.id).source == document.source)
    #expect(loaded.source.hasPrefix("# Budget\r\n"))
    let context = try SheetPreferences.standard.evaluationContext(
      now: Date(timeIntervalSince1970: 0))
    var calculator = SheetCalculator()
    let original = try calculator.evaluate(SheetSource(document.source), context: context)
    let copied = try calculator.evaluate(SheetSource(loaded.source), context: context)
    #expect(original.lines.map(\.result) == copied.lines.map(\.result))
    for (originalTable, copiedTable) in zip(originalTables, copies) {
      for (row, copiedRow) in zip(originalTable.rows, copiedTable.rows) {
        for (column, copiedColumn) in zip(originalTable.columns, copiedTable.columns) {
          #expect(
            original.tableResult(originalTable.id)?.value(row: row, column: column.id)
              == copied.tableResult(copiedTable.id)?.value(row: copiedRow, column: copiedColumn.id))
        }
      }
    }
  }

  @Test
  func structuralEditsUndoRedoSaveAndReload() throws {
    let library = try SheetLibrary(root: try url("Library"))
    var metadata = try library.create(preferences: .standard)
    var document = try budget()
    metadata = try saveAndReload(document.source, metadata, in: library)
    let items = try #require(document.blocks.first?.table)

    let edits: [(String, (TableSourceDocument) throws -> TableSourceEdit)] = [
      ("insert", { try $0.insertRows(table: items.id, at: 0) }),
      ("delete", { try $0.deleteRows(table: items.id, in: 2..<3) }),
      ("rename", { try $0.renameTable(items.id, to: "Travel costs") }),
      (
        "copy",
        {
          try $0.copyCell(
            table: items.id, from: .init(row: 1, column: 0), to: .init(row: 0, column: 0))
        }
      ),
      (
        "fill",
        {
          try $0.fill(
            table: items.id, from: .init(row: 1, column: 1),
            into: .init(rows: 0..<3, columns: 1..<2))
        }
      ),
      ("append", { try $0.appendRows(table: items.id) }),
    ]
    for (name, make) in edits {
      let before = document.source
      let edit = try make(document)
      let after = try edit.applying(to: before)
      metadata = try saveAndReload(after, metadata, in: library)
      // Undo saves the earlier bytes again; redo saves the later ones.
      metadata = try saveAndReload(before, metadata, in: library)
      metadata = try saveAndReload(try edit.applying(to: before), metadata, in: library)
      document = TableSourceDocument(after)
      #expect(document.diagnostics.isEmpty, "\(name)")
    }

    // The deleted row's marker and every rewritten operand persist as source.
    let marker = "#REF!{\(items.id.string)/\(items.rows[1].string)/\(items.columns[0].id.string)}"
    #expect(document.source.contains("check = \(marker)\n"))
    #expect(document.source.contains("total = sum(`Travel costs`[Amount]) // Items[Amount]\n"))
    #expect(document.source.hasPrefix("# Budget\r\n"))

    // Plain source and package exchange keep the exact bytes and bindings.
    for name in ["Out.txt", "Out.ganit"] {
      let file = try url(name)
      try library.exportSheet(metadata.id, to: file, quickLook: nil)
      let other = try SheetLibrary(root: try url("Other-\(name)"))
      let imported = try other.importSheet(from: file, preferences: .standard)
      let loaded = try other.load(id: imported.id)
      #expect(Array(loaded.source.utf8) == Array(document.source.utf8))
      #expect(
        TableSourceDocument(loaded.source).blocks.map(\.table) == document.blocks.map(\.table))
    }
  }
}
