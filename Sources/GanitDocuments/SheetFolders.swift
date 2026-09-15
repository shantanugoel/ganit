import Foundation

public struct SheetFolder: Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
}

/// User folders, stored atomically in `<root>/Folders.json`.
struct SheetFolderStore {
  private struct File: Codable {
    var schemaVersion = 1
    var folders: [SheetFolder]
  }

  let url: URL

  func load() throws -> [SheetFolder] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    guard file.schemaVersion == 1 else {
      throw DocumentStorageError.unsupportedSchemaVersion(file.schemaVersion)
    }
    return file.folders
  }

  func save(_ folders: [SheetFolder]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFile.write(encoder.encode(File(folders: folders)), to: url)
  }
}
