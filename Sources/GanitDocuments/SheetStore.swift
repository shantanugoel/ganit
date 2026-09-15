import CryptoKit
import Foundation
import GanitEngine

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

  public init(localeIdentifier: String, angleMode: AngleMode, significantDecimalDigits: Int) {
    self.localeIdentifier = localeIdentifier
    self.angleMode = angleMode
    self.significantDecimalDigits = significantDecimalDigits
  }
}

/// Small, versioned metadata stored beside a sheet's canonical source.
public struct SheetMetadata: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

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

/// A sheet read from storage.
public struct StoredSheet: Equatable, Sendable {
  public let source: String
  public let metadata: SheetMetadata

  /// Whether the metadata's checksum matches the source. A mismatch means
  /// the source changed after the metadata was written, such as after an
  /// interrupted save; the source is canonical.
  public let isChecksumValid: Bool
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
  /// checksum and whole-second timestamps, and returns the metadata as
  /// written.
  @discardableResult
  public func save(source: String, metadata: SheetMetadata) throws -> SheetMetadata {
    try FileManager.default.createDirectory(at: sheetsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: metadataDirectory, withIntermediateDirectories: true)
    let sourceData = Data(source.utf8)
    var metadata = metadata
    metadata.sourceChecksum = checksum(of: sourceData)
    metadata.createdAt = Date(
      timeIntervalSince1970: metadata.createdAt.timeIntervalSince1970.rounded(.down))
    metadata.modifiedAt = Date(
      timeIntervalSince1970: metadata.modifiedAt.timeIntervalSince1970.rounded(.down))
    try AtomicFile.write(sourceData, to: sourceURL(metadata.id))
    try AtomicFile.write(try Self.encoder.encode(metadata), to: metadataURL(metadata.id))
    return metadata
  }

  /// Replaces only a sheet's metadata, keeping the checksum of its current
  /// source.
  public func saveMetadata(_ metadata: SheetMetadata) throws {
    try AtomicFile.write(try Self.encoder.encode(metadata), to: metadataURL(metadata.id))
  }

  /// Removes a sheet's source and metadata files.
  public func delete(id: UUID) throws {
    for url in [metadataURL(id), sourceURL(id)]
    where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  public func load(id: UUID) throws -> StoredSheet {
    let sourceData = try Data(contentsOf: sourceURL(id))
    guard let source = String(data: sourceData, encoding: .utf8) else {
      throw DocumentStorageError.invalidUTF8(sourceURL(id))
    }
    let metadataData = try Data(contentsOf: metadataURL(id))
    let version = try Self.decoder.decode(SchemaVersion.self, from: metadataData).schemaVersion
    guard version == SheetMetadata.currentSchemaVersion else {
      throw DocumentStorageError.unsupportedSchemaVersion(version)
    }
    let metadata = try Self.decoder.decode(SheetMetadata.self, from: metadataData)
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

  private struct SchemaVersion: Decodable {
    let schemaVersion: Int
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// `sha256:` and the lowercase hex SHA-256 digest of `data`.
func checksum(of data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
