import CryptoKit
import Foundation
import GanitEngine
import GanitFormatting

/// Where a sheet is in its lifecycle.
public enum SheetState: String, Codable, Sendable {
  case active
  case archived
  case trashed
}

/// Calculation preferences stored with a sheet so it keeps its meaning on
/// any Mac.
public struct SheetPreferences: Codable, Equatable, Sendable {
  /// Preferences for new, imported, and recovered sheets until preference
  /// settings exist: English grammar in `en-US`, radians, and 15 digits.
  public static let standard = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .radians,
    significantDecimalDigits: 15
  )

  public var localeIdentifier: String
  public var angleMode: AngleMode
  public var significantDecimalDigits: Int
  /// How the sheet writes its answers.
  public var display: DisplayOptions

  public init(
    localeIdentifier: String,
    angleMode: AngleMode,
    significantDecimalDigits: Int,
    display: DisplayOptions = .standard
  ) {
    self.localeIdentifier = localeIdentifier
    self.angleMode = angleMode
    self.significantDecimalDigits = significantDecimalDigits
    self.display = display
  }
}

extension SheetPreferences {
  /// The locale of a sheet that writes `1.234,56`: English words, with
  /// Germany's separators.
  public static let decimalCommaLocale = "en-DE"

  /// Whether the sheet reads and writes `1.234,56` rather than `1,234.56`.
  public var usesDecimalComma: Bool {
    get { localeIdentifier == Self.decimalCommaLocale }
    set { localeIdentifier = newValue ? Self.decimalCommaLocale : Self.standard.localeIdentifier }
  }

  public var lexingConfiguration: LexingConfiguration {
    usesDecimalComma ? .decimalComma : .englishUnitedStates
  }

  /// A new sheet's preferences, writing numbers as this Mac's region does.
  public static func newSheet(locale: Locale = .current) -> SheetPreferences {
    var preferences = standard
    preferences.usesDecimalComma = locale.decimalSeparator == ","
    return preferences
  }

  /// The evaluation context these preferences describe, with the current time
  /// zone, `now`, and exchange rates.
  public func evaluationContext(now: Date = Date(), currencyRates: CurrencyRates = .none) throws
    -> EvaluationContext
  {
    try EvaluationContext(
      localeIdentifier: localeIdentifier,
      lexingConfiguration: lexingConfiguration,
      angleMode: angleMode,
      precision: PrecisionContext(significantDecimalDigits: significantDecimalDigits),
      now: now,
      calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: TimeZone.current.identifier) ?? .gmt,
      currencyRates: currencyRates,
      dollarCurrency: display.dollarCurrency,
      ambiguousSuffixes: display.ambiguousSuffixes,
      isMarkdownMode: display.writesAnswersInline
    )
  }
}

/// Presentation-only state of one calculation table, such as how wide its
/// columns are drawn.
public struct TablePresentation: Codable, Equatable, Sendable {
  /// The narrowest a column can be drawn, in points.
  public static let minimumColumnWidth = 1.0
  /// The widest a column can be drawn, in points.
  public static let maximumColumnWidth = 10_000.0

  /// Column widths in points, keyed by each column's canonical lowercase
  /// ColumnID. Change them with `setWidth(_:column:)`.
  public private(set) var columnWidths: [String: Double]

  public init() {
    columnWidths = [:]
  }

  /// Unchecked, so tests and decoding can hold what was read; writers drop
  /// what is invalid.
  init(columnWidths: [String: Double]) {
    self.columnWidths = columnWidths
  }

  /// Sets a column's width, clamped to the allowed range, or removes it when
  /// `width` is `nil`. An identity that is not a canonical lowercase UUID, or
  /// a width that is not finite, is ignored.
  public mutating func setWidth(_ width: Double?, column: String) {
    guard isCanonicalIdentity(column) else {
      return
    }
    guard let width else {
      columnWidths[column] = nil
      return
    }
    guard width.isFinite else {
      return
    }
    columnWidths[column] = min(max(width, Self.minimumColumnWidth), Self.maximumColumnWidth)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Presentation is new in schema 2, so it accepts no keys it does not
    // define. A missing `columnWidths` fails below as a missing key.
    let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    guard keys.allSatisfy({ $0 == CodingKeys.columnWidths.stringValue }) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath, debugDescription: "Unknown table presentation key"))
    }
    columnWidths = try container.decode([String: Double].self, forKey: .columnWidths)
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  static func isValid(column: String, width: Double) -> Bool {
    isCanonicalIdentity(column) && width.isFinite && width >= minimumColumnWidth
      && width <= maximumColumnWidth
  }
}

/// Presentation-only state of a sheet's calculation tables, keyed by each
/// table's canonical lowercase TableID.
///
/// It is never canonical: the table blocks in the source win. Decoding is
/// strict: an identity that is not a canonical lowercase UUID, a width that
/// is not finite or outside `TablePresentation`'s range, or an unknown key
/// in an entry makes the whole metadata invalid, so recovery quarantines it
/// and rebuilds metadata from the source, resetting the title, folder,
/// favorite flag, state, and preferences too. Writers never fail because of
/// it; they drop invalid entries and entries for tables or columns whose
/// identity no longer occurs in the saved source.
public struct TablePresentations: Codable, Equatable, Sendable {
  /// Change entries with `setWidth(_:column:table:)`.
  public private(set) var byTableID: [String: TablePresentation]

  public init() {
    byTableID = [:]
  }

  /// Unchecked, so tests and decoding can hold what was read.
  init(_ byTableID: [String: TablePresentation]) {
    self.byTableID = byTableID
  }

  /// Sets a column's width in a table, as `TablePresentation.setWidth`
  /// does, or removes it when `width` is `nil`. A table left with no widths
  /// is removed, and an invalid table identity is ignored.
  public mutating func setWidth(_ width: Double?, column: String, table: String) {
    guard isCanonicalIdentity(table) else {
      return
    }
    var presentation = byTableID[table] ?? TablePresentation()
    presentation.setWidth(width, column: column)
    byTableID[table] = presentation.columnWidths.isEmpty ? nil : presentation
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    byTableID = try container.decode([String: TablePresentation].self)
    guard byTableID == pruned(keeping: { _ in true }).byTableID else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid table identity or column width")
    }
  }

  /// Writes only valid entries, so presentation never keeps a save from
  /// happening.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(pruned(keeping: { _ in true }).byTableID)
  }

  /// The valid entries whose table and column identities occur in `source`,
  /// so the state cannot outgrow the sheet. A plain byte search keeps
  /// entries for malformed blocks whose identities are still written.
  func pruned(toTablesIn source: Data) -> TablePresentations {
    pruned { source.range(of: Data($0.utf8)) != nil }
  }

  private func pruned(keeping occurs: (String) -> Bool) -> TablePresentations {
    var kept: [String: TablePresentation] = [:]
    for (table, presentation) in byTableID where isCanonicalIdentity(table) && occurs(table) {
      let widths = presentation.columnWidths.filter { column, width in
        TablePresentation.isValid(column: column, width: width) && occurs(column)
      }
      if !widths.isEmpty || presentation.columnWidths.isEmpty {
        kept[table] = TablePresentation(columnWidths: widths)
      }
    }
    return TablePresentations(kept)
  }
}

/// Whether `text` is a UUID in canonical lowercase 36-character form, the
/// only spelling table identities have.
private func isCanonicalIdentity(_ text: String) -> Bool {
  UUID(uuidString: text)?.uuidString.lowercased() == text
}

/// Small, versioned metadata stored beside a sheet's canonical source.
///
/// Schema 2 is the only schema read or written. Any other version is refused
/// with `DocumentStorageError.unsupportedSchemaVersion`. Library startup
/// converts schema 1 through `DocumentMigration` before this reader runs.
public struct SheetMetadata: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public private(set) var schemaVersion = currentSchemaVersion
  public let id: UUID
  public var title: String
  /// Whether the user named the sheet; otherwise its title follows its first
  /// line.
  public var hasCustomTitle = false
  public var folderID: UUID?
  public var createdAt: Date
  public var modifiedAt: Date
  public var isFavorite: Bool
  public var state: SheetState
  public var preferences: SheetPreferences
  /// `sha256:` followed by the lowercase hex digest of the source's UTF-8
  /// bytes, as of the last save.
  public internal(set) var sourceChecksum: String
  /// How the sheet's tables are drawn. Writers keep only valid entries whose
  /// identities occur in the saved source.
  public var tables = TablePresentations()

  public init(
    id: UUID = UUID(),
    title: String,
    folderID: UUID? = nil,
    createdAt: Date,
    isFavorite: Bool = false,
    state: SheetState = .active,
    preferences: SheetPreferences
  ) {
    self.id = id
    self.title = title
    self.folderID = folderID
    self.createdAt = createdAt
    modifiedAt = createdAt
    self.isFavorite = isFavorite
    self.state = state
    self.preferences = preferences
    sourceChecksum = checksum(of: Data())
  }
}

extension SheetMetadata {
  /// Drops fractional seconds, which the ISO 8601 encoding does not keep.
  fileprivate mutating func wholeSecondTimestamps() {
    createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    modifiedAt = Date(timeIntervalSince1970: modifiedAt.timeIntervalSince1970.rounded(.down))
  }
}

/// How `SheetLibrary.load(id:)` repaired a sheet's metadata from its
/// canonical source before returning it. The source is never written.
public enum MetadataRepair: Equatable, Sendable {
  /// The checksum no longer matched the source, so it was rewritten for the
  /// current source; every other field was kept.
  case checksum
  /// Metadata was missing, or could not be decoded and was moved to
  /// `Quarantine/`, so it was recreated from the source with reset fields.
  case rebuiltFromSource
}

/// A sheet read from storage.
public struct StoredSheet: Equatable, Sendable {
  public let source: String
  public let metadata: SheetMetadata

  /// Whether the metadata's checksum matches the source. A mismatch means
  /// the source changed after the metadata was written, such as after an
  /// interrupted save; the source is canonical.
  public let isChecksumValid: Bool

  /// How the metadata was repaired before this sheet was returned, if it
  /// was. `SheetStore.load(id:)` never repairs.
  public internal(set) var metadataRepair: MetadataRepair? = nil
}

/// Reads and writes sheets as `Sheets/<UUID>.txt` source files with
/// `Metadata/<UUID>.json` metadata under a library root.
///
/// Both files are replaced atomically. Source is written before metadata, so
/// an interruption leaves either the previous pair, or new source with
/// metadata whose checksum no longer matches, never partial source.
public struct SheetStore: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  private var sheetsDirectory: URL { root.appending(path: "Sheets", directoryHint: .isDirectory) }
  private var metadataDirectory: URL {
    root.appending(path: "Metadata", directoryHint: .isDirectory)
  }

  func sourceURL(_ id: UUID) -> URL {
    sheetsDirectory.appending(path: "\(id.uuidString).txt")
  }

  func metadataURL(_ id: UUID) -> URL {
    metadataDirectory.appending(path: "\(id.uuidString).json")
  }

  /// Saves source and metadata, stamping the metadata with the source's
  /// checksum and whole-second timestamps and dropping presentation state of
  /// tables the source no longer has, and returns the metadata as written.
  @discardableResult
  public func save(source: String, metadata: SheetMetadata) throws -> SheetMetadata {
    try FileManager.default.createDirectory(at: sheetsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: metadataDirectory, withIntermediateDirectories: true)
    let sourceData = Data(source.utf8)
    var metadata = metadata
    metadata.sourceChecksum = checksum(of: sourceData)
    metadata.tables = metadata.tables.pruned(toTablesIn: sourceData)
    metadata.wholeSecondTimestamps()
    // Encoding first means metadata that cannot be encoded leaves both files
    // untouched.
    let metadataData = try Self.encoder.encode(metadata)
    try AtomicFile.write(sourceData, to: sourceURL(metadata.id))
    try AtomicFile.write(metadataData, to: metadataURL(metadata.id))
    return metadata
  }

  /// Replaces only a sheet's metadata, stamping it with the checksum of the
  /// source file's current bytes and dropping presentation state of tables
  /// that source does not have, and returns the metadata as written. The
  /// source file is read, never written.
  @discardableResult
  public func saveMetadata(_ metadata: SheetMetadata) throws -> SheetMetadata {
    let sourceData = try Data(contentsOf: sourceURL(metadata.id))
    var metadata = metadata
    metadata.sourceChecksum = checksum(of: sourceData)
    metadata.tables = metadata.tables.pruned(toTablesIn: sourceData)
    metadata.wholeSecondTimestamps()
    let metadataData = try Self.encoder.encode(metadata)
    try FileManager.default.createDirectory(
      at: metadataDirectory, withIntermediateDirectories: true)
    try AtomicFile.write(metadataData, to: metadataURL(metadata.id))
    return metadata
  }

  /// Removes a sheet's source and metadata files.
  public func delete(id: UUID) throws {
    for url in [metadataURL(id), sourceURL(id)]
    where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Reads a sheet's source and metadata without changing either file.
  /// Source that is not UTF-8 throws `invalidUTF8`, metadata in another
  /// schema throws `unsupportedSchemaVersion`, and metadata that cannot be
  /// decoded, or whose `id` names a different sheet, throws `DecodingError`.
  /// `SheetLibrary.load(id:)` repairs what can be repaired.
  public func load(id: UUID) throws -> StoredSheet {
    let sourceData = try Data(contentsOf: sourceURL(id))
    guard let source = exactUTF8(sourceData) else {
      throw DocumentStorageError.invalidUTF8(sourceURL(id))
    }
    let metadataData = try Data(contentsOf: metadataURL(id))
    let version = try Self.decoder.decode(SchemaVersion.self, from: metadataData).schemaVersion
    guard version == SheetMetadata.currentSchemaVersion else {
      throw DocumentStorageError.unsupportedSchemaVersion(version)
    }
    let metadata = try Self.decoder.decode(SheetMetadata.self, from: metadataData)
    // Metadata naming another sheet, such as a copied file, is corrupt:
    // trusting it would save this sheet's source over the other sheet.
    guard metadata.id == id else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: [], debugDescription: "Metadata names a different sheet"))
    }
    return StoredSheet(
      source: source,
      metadata: metadata,
      isChecksumValid: metadata.sourceChecksum == checksum(of: sourceData)
    )
  }

  /// The IDs of all sheets with source files, found by scanning the source
  /// directory, so no index is needed to discover them.
  public func sheetIDs() throws -> [UUID] {
    guard FileManager.default.fileExists(atPath: sheetsDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(atPath: sheetsDirectory.path)
      .filter { !AtomicFile.isTemporary($0) && $0.hasSuffix(".txt") }
      .compactMap { UUID(uuidString: String($0.dropLast(4))) }
      .sorted { $0.uuidString < $1.uuidString }
  }

  /// Removes regular files that interrupted atomic writes left in the source
  /// and metadata directories, named exactly as `AtomicFile` names its
  /// temporary files. Cleanup is best effort: a directory that cannot be
  /// listed or a file that cannot be removed is skipped. Only call it when
  /// no write is in progress.
  func removeTemporaryFiles() {
    for directory in [sheetsDirectory, metadataDirectory] {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else {
        continue
      }
      for name in names where AtomicFile.isWriterTemporary(name) {
        let file = directory.appending(path: name)
        let type = try? FileManager.default.attributesOfItem(atPath: file.path)[.type]
        if type as? FileAttributeType == .typeRegular {
          try? FileManager.default.removeItem(at: file)
        }
      }
    }
  }

  private struct SchemaVersion: Decodable {
    let schemaVersion: Int
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// `sha256:` and the lowercase hex SHA-256 digest of `data`.
func checksum(of data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `bytes` as UTF-8 text, every byte kept, or `nil` when they are not valid
/// UTF-8. Unlike `String(data:encoding:)`, which drops a leading U+FEFF,
/// nothing is removed or replaced, so the text's UTF-8 is `bytes` exactly.
/// Decoding repairs invalid input, so a repaired text differs from `bytes`;
/// the buffers are compared in bulk.
func exactUTF8(_ bytes: Data) -> String? {
  let text = String(decoding: bytes, as: UTF8.self)
  return Data(text.utf8) == bytes ? text : nil
}
