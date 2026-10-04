import Foundation
import GanitFormatting

/// Converts old data before the current readers receive it.
public enum DocumentMigration {
  public struct Progress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
  }

  /// Updates library metadata and daily backup metadata. Source files stay unchanged.
  /// A failed write stops startup. The next startup retries the remaining files.
  @discardableResult
  public static func migrateLibrary(
    at root: URL, progress: ((Progress) -> Void)? = nil
  ) throws -> Int {
    let manager = FileManager.default
    var stores = [SheetStore(root: root)]
    let backups = root.appending(path: "Backups")
    if manager.fileExists(atPath: backups.path) {
      for day in try manager.contentsOfDirectory(
        at: backups, includingPropertiesForKeys: [.isDirectoryKey])
      where try day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        stores.append(SheetStore(root: day))
      }
    }
    var pending: [(URL, Data, Data)] = []
    for store in stores {
      for id in try store.sheetIDs() {
        let url = store.metadataURL(id)
        // Missing or malformed JSON remains the responsibility of normal recovery.
        guard manager.fileExists(atPath: url.path) else { continue }
        let original = try Data(contentsOf: url)
        guard let version = try? SheetStore.decoder.decode(Version.self, from: original),
          version.schemaVersion == 1
        else { continue }
        let converted = try currentJSON(original)
        guard let metadata = try? SheetStore.decoder.decode(SheetMetadata.self, from: converted),
          metadata.id == id
        else { continue }
        pending.append((url, original, converted))
      }
    }
    guard !pending.isEmpty else { return 0 }
    progress?(Progress(completed: 0, total: pending.count))
    let indexDirectory = root.appending(path: "Index")
    try manager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
    // This marker survives an interruption, including after the last replacement.
    try AtomicFile.write(Data(), to: indexDirectory.appending(path: "unsynchronized"))
    try AtomicFile.synchronizeDirectory(root)
    for (offset, entry) in pending.enumerated() {
      let (url, original, converted) = entry
      let relative = String(url.path.dropFirst(root.path.count + 1))
      let backup = root.appending(path: "MigrationBackups/schema-1").appending(path: relative)
      try manager.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !manager.fileExists(atPath: backup.path) {
        try AtomicFile.write(original, to: backup)
      } else {
        // A retry must not replace or ignore a different original.
        guard try Data(contentsOf: backup) == original else {
          throw DecodingError.dataCorrupted(
            .init(
              codingPath: [],
              debugDescription: "Migration backup differs from the original metadata"))
        }
      }
      // Synchronize new directory entries before replacing the live metadata.
      var directory = backup.deletingLastPathComponent()
      while directory.path != root.path {
        try AtomicFile.synchronizeDirectory(directory)
        directory = directory.deletingLastPathComponent()
      }
      try AtomicFile.synchronizeDirectory(root)
      try AtomicFile.write(converted, to: url)
      progress?(Progress(completed: offset + 1, total: pending.count))
    }
    return pending.count
  }

  /// Converts a package manifest in memory. The selected package stays unchanged.
  static func manifest(from data: Data) throws -> GanitManifest {
    let version = try SheetExchange.decoder.decode(Version.self, from: data).schemaVersion
    guard version == 1 || version == GanitManifest.currentSchemaVersion else {
      throw SheetExchangeError.unsupportedSchemaVersion(version)
    }
    return try SheetExchange.decoder.decode(
      GanitManifest.self, from: version == 1 ? currentJSON(data) : data)
  }

  private struct Version: Decodable {
    let schemaVersion: Int
  }

  /// Applies the defaults used by schema 1 readers, then adds empty table settings.
  private static func currentJSON(_ data: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "Expected metadata object"))
    }
    var preferences = object["preferences"] as? [String: Any] ?? [:]
    let standard =
      try JSONSerialization.jsonObject(with: SheetStore.encoder.encode(DisplayOptions.standard))
      as! [String: Any]
    if var display = preferences["display"] as? [String: Any] {
      // Schema 1 required these two fields when display settings were present.
      for key in standard.keys where key != "groupsDigits" && key != "numbers" {
        if display[key] == nil || display[key] is NSNull { display[key] = standard[key] }
      }
      preferences["display"] = display
    } else if preferences["display"] == nil || preferences["display"] is NSNull {
      preferences["display"] = standard
    }
    object["preferences"] = preferences
    object["schemaVersion"] = SheetMetadata.currentSchemaVersion
    object["tables"] = [String: Any]()
    return try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}
