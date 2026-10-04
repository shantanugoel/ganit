import Darwin
import Foundation

/// The portable metadata of a `.ganit` package.
///
/// Writers use schema 2. The migration module converts schema 1 on import.
/// Other versions cause `SheetExchangeError.unsupportedSchemaVersion`.
public struct GanitManifest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public private(set) var schemaVersion = currentSchemaVersion
  public var id: UUID
  public var title: String
  public var hasCustomTitle: Bool
  public var createdAt: Date
  public var modifiedAt: Date
  public var preferences: SheetPreferences
  /// `sha256:` and the lowercase hex SHA-256 of `source.txt`.
  public var sourceChecksum: String
  /// How the sheet's tables are drawn; never canonical.
  public var tables: TablePresentations
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
  /// A file larger than import accepts, or a package export would write
  /// that import would refuse.
  case tooLarge(URL)
  case unsupportedSchemaVersion(Int)
}

/// Reads and writes sheets as `.ganit` packages and UTF-8 plain text.
///
/// A package is a directory holding `source.txt`, the exact source bytes, and
/// `manifest.json`. It is written completely beside the destination and then
/// swapped in atomically, so readers see the previous or the new package.
public enum SheetExchange {
  public static let packageExtension = "ganit"
  /// The engine's longest source, so an imported sheet can always evaluate.
  public static let maximumSourceBytes = 1_048_576
  public static let maximumManifestBytes = 65_536

  /// Whether `url` names a package: its extension is `ganit` in any case, as
  /// macOS file names are usually case-insensitive.
  static func isPackage(_ url: URL) -> Bool {
    url.pathExtension.caseInsensitiveCompare(packageExtension) == .orderedSame
  }

  /// Reads a `.ganit` package, in any case, or any other file as plain text.
  /// The source is the file's or `source.txt`'s bytes exactly, after
  /// removing one leading byte-order mark; nothing is normalized. A
  /// package's checksum is compared with that source. Bytes that are not
  /// UTF-8, a source or manifest larger than the limits, and a manifest
  /// schema other than 1 or 2 are refused.
  public static func read(from url: URL) throws -> ExchangedSheet {
    guard isPackage(url) else {
      return ExchangedSheet(
        source: try utf8(at: url, reportedAs: url), manifest: nil, isChecksumValid: true)
    }
    // Errors name the package, the file that was chosen, rather than a file
    // inside it.
    let data = try contents(
      of: url.appending(path: "manifest.json"), limit: maximumManifestBytes, reportedAs: url)
    let manifest = try DocumentMigration.manifest(from: data)
    let source = try utf8(at: url.appending(path: "source.txt"), reportedAs: url)
    return ExchangedSheet(
      source: source,
      manifest: manifest,
      isChecksumValid: manifest.sourceChecksum == checksum(of: Data(source.utf8))
    )
  }

  /// Writes a sheet as a package when `url` has the `.ganit` extension, in any
  /// case, and as plain source text otherwise. A package also carries
  /// `quickLook`, which the system's package previewer shows from
  /// `QuickLook/Preview.pdf` and `QuickLook/Thumbnail.png`.
  public static func write(
    source: String, metadata: SheetMetadata, to url: URL, quickLook: QuickLookPreview?
  ) throws {
    let sourceData = Data(source.utf8)
    guard isPackage(url) else {
      try AtomicFile.write(sourceData, to: url)
      return
    }
    var manifest = GanitManifest(
      id: metadata.id,
      title: metadata.title,
      hasCustomTitle: metadata.hasCustomTitle,
      createdAt: metadata.createdAt,
      modifiedAt: metadata.modifiedAt,
      preferences: metadata.preferences,
      sourceChecksum: checksum(of: sourceData),
      tables: metadata.tables.pruned(toTablesIn: sourceData)
    )
    // A package import would refuse is never written. Presentation is not
    // canonical, so it is left out rather than keep a sheet from exporting.
    var manifestData = try encoder.encode(manifest)
    if manifestData.count > maximumManifestBytes, !manifest.tables.byTableID.isEmpty {
      manifest.tables = TablePresentations()
      manifestData = try encoder.encode(manifest)
    }
    guard manifestData.count <= maximumManifestBytes else {
      throw SheetExchangeError.tooLarge(url)
    }
    guard sourceData.count <= maximumSourceBytes else {
      throw SheetExchangeError.tooLarge(url)
    }
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    var swapped = false
    do {
      try StorageFaults.reach(.packageDirectoryCreated, url)
      try AtomicFile.write(sourceData, to: temporary.appending(path: "source.txt"))
      try AtomicFile.write(manifestData, to: temporary.appending(path: "manifest.json"))
      if let quickLook {
        let folder = temporary.appending(path: "QuickLook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try AtomicFile.write(quickLook.pdf, to: folder.appending(path: "Preview.pdf"))
        try AtomicFile.write(quickLook.thumbnailPNG, to: folder.appending(path: "Thumbnail.png"))
      }
      try StorageFaults.reach(.packageAssembled, url)
      if FileManager.default.fileExists(atPath: url.path) {
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
          throw DocumentStorageError.posix(operation: "renamex_np", code: errno)
        }
        swapped = true
      } else {
        guard rename(temporary.path, url.path) == 0 else {
          throw DocumentStorageError.posix(operation: "rename", code: errno)
        }
      }
      try StorageFaults.reach(.packageReplaced, url)
      try AtomicFile.synchronizeDirectory(directory)
    } catch {
      // Before the swap the temporary name holds the unfinished new package,
      // which is removed. After it, the new package is in place but may not
      // be durable, so the replaced package is kept there as a hidden sibling.
      if !swapped {
        try? FileManager.default.removeItem(at: temporary)
      }
      throw error
    }
    guard swapped else {
      return
    }
    // The export is complete, so failing to remove the replaced package
    // leaves it as a hidden sibling rather than failing the export.
    do {
      try StorageFaults.reach(.removingReplacedPackage, url)
      try FileManager.default.removeItem(at: temporary)
    } catch {}
  }

  /// A file's bytes, reading no more than `limit` of them, since an imported
  /// file comes from outside the library. Errors name `reported`.
  private static func contents(of url: URL, limit: Int, reportedAs reported: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else {
      throw SheetExchangeError.tooLarge(reported)
    }
    return data
  }

  /// A UTF-8 byte-order mark: an encoding signature that some editors put
  /// before a file's text, which Ganit never writes.
  public static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

  /// Text read from outside Ganit, such as standard input, read as import
  /// reads a file: one leading byte-order mark is removed and every other
  /// byte kept. `nil` when the rest is not UTF-8 or is larger than
  /// `maximumSourceBytes`.
  public static func importedSource(_ data: Data) -> String? {
    let source = withoutByteOrderMark(data)
    return source.count <= maximumSourceBytes ? exactUTF8(source) : nil
  }

  private static func withoutByteOrderMark(_ data: Data) -> Data {
    data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data
  }

  /// An imported file's source: its bytes exactly, after removing one
  /// leading byte-order mark, if present, which is not part of the text. The
  /// size limit applies to the source, not the mark. Errors name `reported`.
  private static func utf8(at url: URL, reportedAs reported: URL) throws -> String {
    let data = try contents(
      of: url, limit: maximumSourceBytes + byteOrderMark.count, reportedAs: reported)
    let source = withoutByteOrderMark(data)
    guard source.count <= maximumSourceBytes else {
      throw SheetExchangeError.tooLarge(reported)
    }
    guard let text = exactUTF8(source) else {
      throw SheetExchangeError.invalidUTF8(reported)
    }
    return text
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

extension SheetLibrary {
  /// Imports a `.ganit` package or UTF-8 text file as a new sheet whose
  /// source is the file's text byte for byte, without a leading byte-order
  /// mark. A package keeps its ID, title, preferences, and table presentation
  /// unless the library already has a sheet with that ID, when it gets a new
  /// ID; plain text uses `preferences`.
  ///
  /// Table identities are never reminted: they need only be unique within a
  /// sheet, and changing them would change the source. A package whose
  /// checksum is stale, as after editing `source.txt` elsewhere, imports its
  /// source as canonical, with the manifest's other fields and a new
  /// checksum; a title that follows the first line, and table presentation,
  /// follow the source as with any save.
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
    metadata.tables = manifest?.tables ?? TablePresentations()
    return try save(source: exchanged.source, metadata: metadata)
  }

  /// Exports a sheet as a `.ganit` package or, for other extensions, plain text.
  public func exportSheet(_ id: UUID, to url: URL, quickLook: QuickLookPreview?) throws {
    let sheet = try load(id: id)
    try SheetExchange.write(
      source: sheet.source, metadata: sheet.metadata, to: url, quickLook: quickLook)
  }
}
