import Darwin
import Foundation

/// The portable metadata of a `.ganit` package.
public struct GanitManifest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public private(set) var schemaVersion = currentSchemaVersion
  public var id: UUID
  public var title: String
  public var hasCustomTitle: Bool
  public var createdAt: Date
  public var modifiedAt: Date
  public var preferences: SheetPreferences
  /// `sha256:` and the lowercase hex SHA-256 of `source.txt`.
  public var sourceChecksum: String
}

/// A sheet read from a `.ganit` package or plain-text file.
public struct ExchangedSheet: Equatable, Sendable {
  public let source: String
  /// `nil` for plain text.
  public let manifest: GanitManifest?
  /// Whether `source.txt` matches the manifest's checksum; always true for
  /// plain text. Source is canonical either way.
  public let isChecksumValid: Bool
}

/// Files Quick Look shows for a `.ganit` package in Finder: a rendered
/// preview and a thumbnail of its first page.
public struct QuickLookPreview: Sendable {
  public let pdf: Data
  public let thumbnailPNG: Data

  public init(pdf: Data, thumbnailPNG: Data) {
    self.pdf = pdf
    self.thumbnailPNG = thumbnailPNG
  }
}

public enum SheetExchangeError: Error, Equatable {
  case invalidUTF8(URL)
  case unsupportedSchemaVersion(Int)
}

/// Reads and writes sheets as `.ganit` packages and UTF-8 plain text.
///
/// A package is a directory holding `source.txt`, the exact source bytes, and
/// `manifest.json`. It is written completely beside the destination and then
/// swapped in atomically, so readers see the previous or the new package.
public enum SheetExchange {
  public static let packageExtension = "ganit"

  public static func read(from url: URL) throws -> ExchangedSheet {
    guard url.pathExtension == packageExtension else {
      return ExchangedSheet(source: try utf8(at: url), manifest: nil, isChecksumValid: true)
    }
    let data = try Data(contentsOf: url.appending(path: "manifest.json"))
    let version = try decoder.decode(SchemaVersion.self, from: data).schemaVersion
    guard version == GanitManifest.currentSchemaVersion else {
      throw SheetExchangeError.unsupportedSchemaVersion(version)
    }
    let manifest = try decoder.decode(GanitManifest.self, from: data)
    let sourceURL = url.appending(path: "source.txt")
    let source = try utf8(at: sourceURL)
    return ExchangedSheet(
      source: source,
      manifest: manifest,
      isChecksumValid: manifest.sourceChecksum == checksum(of: Data(source.utf8))
    )
  }

  /// Writes a sheet as a package when `url` has the `.ganit` extension, and as
  /// plain source text otherwise. A package also carries `quickLook`, which
  /// the system's package previewer shows from `QuickLook/Preview.pdf` and
  /// `QuickLook/Thumbnail.png`.
  public static func write(
    source: String, metadata: SheetMetadata, to url: URL, quickLook: QuickLookPreview?
  ) throws {
    let sourceData = Data(source.utf8)
    guard url.pathExtension == packageExtension else {
      try AtomicFile.write(sourceData, to: url)
      return
    }
    let manifest = GanitManifest(
      id: metadata.id,
      title: metadata.title,
      hasCustomTitle: metadata.hasCustomTitle,
      createdAt: metadata.createdAt,
      modifiedAt: metadata.modifiedAt,
      preferences: metadata.preferences,
      sourceChecksum: checksum(of: sourceData)
    )
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    do {
      try AtomicFile.write(sourceData, to: temporary.appending(path: "source.txt"))
      try AtomicFile.write(encoder.encode(manifest), to: temporary.appending(path: "manifest.json"))
      if let quickLook {
        let folder = temporary.appending(path: "QuickLook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try AtomicFile.write(quickLook.pdf, to: folder.appending(path: "Preview.pdf"))
        try AtomicFile.write(quickLook.thumbnailPNG, to: folder.appending(path: "Thumbnail.png"))
      }
      if FileManager.default.fileExists(atPath: url.path) {
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
          throw DocumentStorageError.posix(operation: "renamex_np", code: errno)
        }
      } else {
        guard rename(temporary.path, url.path) == 0 else {
          throw DocumentStorageError.posix(operation: "rename", code: errno)
        }
      }
      try AtomicFile.synchronizeDirectory(directory)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    // After a swap, the temporary name holds the replaced package.
    try? FileManager.default.removeItem(at: temporary)
  }

  private struct SchemaVersion: Decodable {
    let schemaVersion: Int
  }

  private static func utf8(at url: URL) throws -> String {
    guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
      throw SheetExchangeError.invalidUTF8(url)
    }
    return text
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

extension SheetLibrary {
  /// Imports a `.ganit` package or UTF-8 text file as a new sheet. A package
  /// keeps its ID, title, and preferences unless the library already has a
  /// sheet with that ID; plain text uses `preferences`.
  public func importSheet(from url: URL, preferences: SheetPreferences) throws -> SheetMetadata {
    let exchanged = try SheetExchange.read(from: url)
    let manifest = exchanged.manifest
    let keepsID = manifest.map {
      !FileManager.default.fileExists(atPath: store.sourceURL($0.id).path)
    }
    var metadata = SheetMetadata(
      id: keepsID == true ? manifest!.id : UUID(),
      title: manifest?.title ?? "",
      createdAt: manifest?.createdAt ?? now(),
      preferences: manifest?.preferences ?? preferences
    )
    metadata.hasCustomTitle = manifest?.hasCustomTitle ?? false
    return try save(source: exchanged.source, metadata: metadata)
  }

  /// Exports a sheet as a `.ganit` package or, for other extensions, plain text.
  public func exportSheet(_ id: UUID, to url: URL, quickLook: QuickLookPreview?) throws {
    let sheet = try store.load(id: id)
    try SheetExchange.write(
      source: sheet.source, metadata: sheet.metadata, to: url, quickLook: quickLook)
  }
}
