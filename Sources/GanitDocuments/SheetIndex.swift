import Foundation
import SQLite3

/// A sheet's listing fields, read from the index.
public struct SheetSummary: Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let folderID: UUID?
  public let state: SheetState
  public let isFavorite: Bool
  public let modifiedAt: Date
  /// The sheet is written as a markdown article, with answers in the lines.
  public let isMarkdown: Bool
}

/// The outcome of rebuilding the index from sheet files.
public struct IndexRebuildReport: Equatable, Sendable {
  public let indexedCount: Int
  /// Sheets whose source or metadata could not be read; their files are
  /// untouched.
  public let unreadable: [UUID]
}

/// A derived, rebuildable SQLite index of sheet summaries and source.
///
/// Sheet files are the only authority. Opening a corrupt index, or one with
/// an unexpected schema version, replaces it with an empty index and sets
/// `needsRebuild`; `rebuild(from:)` then repopulates it from the store.
public final class SheetIndex {
  static let schemaVersion: Int32 = 2

  public private(set) var needsRebuild = false
  private let url: URL
  private var database: OpaquePointer?

  public init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existed = FileManager.default.fileExists(atPath: url.path)
    if (try? open()) == nil || (existed && !isHealthy()) {
      close()
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
      try open()
      needsRebuild = true
    } else if !existed {
      needsRebuild = true
    }
    try execute(
      """
      CREATE TABLE IF NOT EXISTS sheets (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        folder_id TEXT,
        state TEXT NOT NULL,
        is_favorite INTEGER NOT NULL,
        modified_at REAL NOT NULL,
        source TEXT NOT NULL,
        is_markdown INTEGER NOT NULL
      );
      PRAGMA user_version = \(Self.schemaVersion);
      """
    )
  }

  deinit {
    close()
  }

  public func upsert(_ metadata: SheetMetadata, source: String) throws {
    try run(
      """
      INSERT OR REPLACE INTO sheets (id, title, folder_id, state, is_favorite, modified_at, source, is_markdown)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        metadata.id.uuidString, metadata.title, metadata.folderID?.uuidString,
        metadata.state.rawValue, metadata.isFavorite ? 1 : 0,
        metadata.modifiedAt.timeIntervalSince1970, source,
        metadata.preferences.display.writesAnswersInline ? 1 : 0,
      ]
    )
  }

  public func remove(id: UUID) throws {
    try run("DELETE FROM sheets WHERE id = ?", [id.uuidString])
  }

  /// All indexed sheets, most recently modified first.
  public func summaries() throws -> [SheetSummary] {
    try query(
      "SELECT id, title, folder_id, state, is_favorite, modified_at, is_markdown FROM sheets ORDER BY modified_at DESC, id"
    ) { row in
      SheetSummary(
        id: UUID(uuidString: row.text(0)) ?? UUID(),
        title: row.text(1),
        folderID: row.optionalText(2).flatMap(UUID.init(uuidString:)),
        state: SheetState(rawValue: row.text(3)) ?? .active,
        isFavorite: row.integer(4) != 0,
        modifiedAt: Date(timeIntervalSince1970: row.double(5)),
        isMarkdown: row.integer(6) != 0
      )
    }
  }

  /// The active sheet a title names: one whose whole title matches, ignoring
  /// case and diacritics, and otherwise the most recently modified sheet whose
  /// title contains the text. A blank title names nothing.
  public func sheet(titled title: String) throws -> UUID? {
    let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else {
      return nil
    }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let active = try summaries().filter { $0.state == .active }
    let exact = active.first { $0.title.compare(wanted, options: options) == .orderedSame }
    return (exact ?? active.first { $0.title.range(of: wanted, options: options) != nil })?.id
  }

  /// Sheets whose title or source contains `text`, ignoring case and
  /// diacritics, most recently modified first.
  public func search(_ text: String) throws -> [UUID] {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return try query("SELECT id, title, source FROM sheets ORDER BY modified_at DESC, id") { row in
      (row.text(0), row.text(1), row.text(2))
    }
    .filter {
      $0.1.range(of: text, options: options) != nil || $0.2.range(of: text, options: options) != nil
    }
    .compactMap { UUID(uuidString: $0.0) }
  }

  /// Replaces the index contents with every readable sheet in `store`, in one
  /// transaction.
  @discardableResult
  public func rebuild(from store: SheetStore) throws -> IndexRebuildReport {
    var indexed = 0
    var unreadable: [UUID] = []
    try execute("BEGIN IMMEDIATE")
    do {
      try execute("DELETE FROM sheets")
      for id in try store.sheetIDs() {
        guard let sheet = try? store.load(id: id) else {
          unreadable.append(id)
          continue
        }
        try upsert(sheet.metadata, source: sheet.source)
        indexed += 1
      }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
    needsRebuild = false
    return IndexRebuildReport(indexedCount: indexed, unreadable: unreadable)
  }

  // MARK: SQLite

  public enum Error: Swift.Error, Equatable {
    case sqlite(code: Int32, message: String)
  }

  private func open() throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let code = sqlite3_open_v2(url.path, &database, flags, nil)
    guard code == SQLITE_OK else {
      throw failure(code)
    }
  }

  private func close() {
    sqlite3_close_v2(database)
    database = nil
  }

  private func isHealthy() -> Bool {
    let check = try? query("PRAGMA quick_check") { $0.text(0) }
    let version = try? query("PRAGMA user_version") { $0.integer(0) }
    return check == ["ok"] && (version == [0] || version == [Int(Self.schemaVersion)])
  }

  private func execute(_ sql: String) throws {
    let code = sqlite3_exec(database, sql, nil, nil, nil)
    guard code == SQLITE_OK else {
      throw failure(code)
    }
  }

  private func run(_ sql: String, _ values: [Any?]) throws {
    _ = try query(sql, values) { _ in () }
  }

  private func query<Row>(
    _ sql: String,
    _ values: [Any?] = [],
    _ read: (RowReader) -> Row
  ) throws -> [Row] {
    var statement: OpaquePointer?
    var code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard code == SQLITE_OK else {
      throw failure(code)
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case let text as String:
        code = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transient)
      case let integer as Int:
        code = sqlite3_bind_int64(statement, index, Int64(integer))
      case let double as Double:
        code = sqlite3_bind_double(statement, index, double)
      default:
        code = sqlite3_bind_null(statement, index)
      }
      guard code == SQLITE_OK else {
        throw failure(code)
      }
    }
    var rows: [Row] = []
    while true {
      code = sqlite3_step(statement)
      guard code == SQLITE_ROW else {
        break
      }
      rows.append(read(RowReader(statement: statement)))
    }
    guard code == SQLITE_DONE else {
      throw failure(code)
    }
    return rows
  }

  private func failure(_ code: Int32) -> Error {
    .sqlite(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "")
  }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct RowReader {
  let statement: OpaquePointer?

  func text(_ column: Int32) -> String {
    optionalText(column) ?? ""
  }

  /// Reads by byte length, so text containing NUL characters is intact.
  func optionalText(_ column: Int32) -> String? {
    guard let bytes = sqlite3_column_text(statement, column) else {
      return nil
    }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }

  func integer(_ column: Int32) -> Int {
    Int(sqlite3_column_int64(statement, column))
  }

  func double(_ column: Int32) -> Double {
    sqlite3_column_double(statement, column)
  }
}
