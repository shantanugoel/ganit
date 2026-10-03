import Foundation
import SQLite3
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// A table-first sheet is titled from its table's name, and search matches a
/// table's display text (name, headers, cells), never its identities or the
/// JSON that stores them.
@Suite
final class TableTitleSearchTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitTableTitles-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private static func groceries() throws -> (TableModel, String) {
    var table = TableModel.creating(
      name: "Weekly groceries", headers: [("Item", .text), ("Cost", .value)], rowCount: 1)
    table.cells = [
      TableCell(row: table.rows[0], column: table.columns[0].id, source: "Saffron"),
      TableCell(row: table.rows[0], column: table.columns[1].id, source: "12"),
    ]
    return (table, try TableSourceDocument.canonicalBlock(for: table))
  }

  @Test
  func aTableFirstSheetIsTitledByItsTableName() throws {
    let library = try SheetLibrary(root: root)
    let (_, block) = try Self.groceries()
    let cases: [(String, String)] = [
      (block + "total = sum(`Weekly groceries`[Cost])\n", "Weekly groceries"),
      ("\n  \n" + block, "Weekly groceries"),
      ("\u{FEFF}\n" + block, "Weekly groceries"),
      // A block with no readable table is skipped, never used as a title.
      ("@ganit-table 1\n{\"ids\":[}\n@end-ganit-table\n# Budget\n", "Budget"),
      ("@ganit-table 2\n{}\n@end-ganit-table\n" + block, "Weekly groceries"),
      ("@ganit-table 1\n{\"unterminated\": true}\n", ""),
      ("# Plan\n" + block, "Plan"),
    ]
    for (source, title) in cases {
      let saved = try library.save(
        source: source,
        metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard))
      #expect(saved.title == title, "\(source.prefix(20))")
      #expect(try library.index.summaries().first { $0.id == saved.id }?.title == title)
    }
  }

  @Test
  func searchMatchesTableTextButNotIdentitiesOrJSON() throws {
    let library = try SheetLibrary(root: root)
    let (table, block) = try Self.groceries()
    let sheet = try library.save(
      source: "Shopping\n" + block + "spent = `Weekly groceries`!B2\n",
      metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard))
    let malformed = try library.save(
      source: "Other\n@ganit-table 2\n{\"v\":1}\n@end-ganit-table\n",
      metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard))
    #expect(sheet.title == "Shopping")
    for text in ["weekly GROCERIES", "Saffron", "Cost", "spent", "Shopping"] {
      #expect(try library.index.search(text) == [sheet.id], "\(text)")
    }
    for text in [
      "\"ids\"", "\"t\":0", table.id.string, String(table.columns[0].id.string.prefix(8)),
      "ganit-table 1", "\"p\":\"text\"",
    ] {
      #expect(try library.index.search(text).isEmpty, "\(text)")
    }
    // A quarantined block is shown raw, so its raw text is searchable.
    #expect(try library.index.search("@ganit-table 2") == [malformed.id])
  }

  @Test
  func anIndexWithPayloadSearchTextIsRebuilt() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let (_, block) = try Self.groceries()
    let saved = try library!.save(
      source: block, metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard))
    library = nil
    let url = root.appending(path: "Index/index.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "PRAGMA user_version = 3;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let reopened = try SheetLibrary(root: root)
    #expect(try reopened.index.search("\"ids\"").isEmpty)
    #expect(try reopened.index.search("Saffron") == [saved.id])
  }
}
