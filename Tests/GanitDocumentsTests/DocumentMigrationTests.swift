import Foundation
import Testing

@_spi(StorageFaults) @testable import GanitDocuments

@Suite struct DocumentMigrationTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitMigration-\(UUID().uuidString)")

  private func seed(at root: URL? = nil) throws -> (SheetStore, UUID, Data) {
    let store = SheetStore(root: root ?? self.root)
    let id = DocumentFormatFixtureTests.ordinaryID
    let metadata = try DocumentFormatFixtureTests.data("Rejected/metadata-schema-1.json")
    for url in [store.sourceURL(id), store.metadataURL(id)] {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    try DocumentFormatFixtureTests.data(
      DocumentFormatFixtureTests.metadataPath(id)
        .replacingOccurrences(of: "Metadata", with: "Sheets").replacingOccurrences(
          of: ".json", with: ".txt")
    )
    .write(to: store.sourceURL(id))
    try metadata.write(to: store.metadataURL(id))
    return (store, id, metadata)
  }

  @Test func startupConvertsSheetsAndBackupsOnce() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, id, original) = try seed()
    let (backup, _, _) = try seed(at: root.appending(path: "Backups/2026-10-01"))
    let source = try Data(contentsOf: store.sourceURL(id))
    var progress: [DocumentMigration.Progress] = []
    let library = try SheetLibrary(root: root, migrationProgress: { progress.append($0) })
    let sheet = try library.load(id: id)
    #expect(sheet.metadata.schemaVersion == 2 && sheet.isChecksumValid)
    #expect(sheet.metadata.title == "Rent" && sheet.metadata.isFavorite)
    #expect(sheet.metadata.folderID != nil && sheet.metadata.state == .active)
    #expect(sheet.metadata.tables == TablePresentations())
    #expect(try Data(contentsOf: store.sourceURL(id)) == source)
    #expect(try Data(contentsOf: backup.sourceURL(id)) == source)
    #expect(try backup.load(id: id).metadata.schemaVersion == 2)
    #expect(
      try Data(
        contentsOf: root.appending(path: "MigrationBackups/schema-1/Metadata/\(id.uuidString).json")
      ) == original)
    #expect(progress.map(\.completed) == [0, 1, 2])
    let converted = try Data(contentsOf: store.metadataURL(id))
    #expect(try DocumentMigration.migrateLibrary(at: root) == 0)
    #expect(try Data(contentsOf: store.metadataURL(id)) == converted)
    #expect(try library.index.summaries().contains { $0.id == id })
  }

  @Test func earliestDisplaySettingsGetTheirOriginalDefaults() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, id, data) = try seed()
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var preferences = json["preferences"] as! [String: Any]
    preferences.removeValue(forKey: "display")
    json["preferences"] = preferences
    try JSONSerialization.data(withJSONObject: json).write(to: store.metadataURL(id))
    let library = try SheetLibrary(root: root)
    #expect(try library.load(id: id).metadata.preferences == .standard)
  }

  @Test func partialDisplaySettingsKeepOldChoices() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, id, data) = try seed()
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var preferences = json["preferences"] as! [String: Any]
    preferences["display"] = ["groupsDigits": false, "numbers": ["scientific": [:]]]
    json["preferences"] = preferences
    try JSONSerialization.data(withJSONObject: json).write(to: store.metadataURL(id))
    let library = try SheetLibrary(root: root)
    let display = try library.load(id: id).metadata.preferences.display
    #expect(!display.groupsDigits && display.numbers == .scientific)
    #expect(display.showsLineNumbers && display.showsAnswerSeparator)
    #expect(!display.writesAnswersInline && display.dollarCurrency == "USD")
  }

  @Test func aDifferentOriginalBackupKeepsBothVersions() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, id, original) = try seed()
    let backup = root.appending(path: "MigrationBackups/schema-1/Metadata/\(id.uuidString).json")
    try FileManager.default.createDirectory(
      at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = Data("different original".utf8)
    try existing.write(to: backup)
    #expect(try DocumentMigration.migrateLibrary(at: root) == 1)
    #expect(try store.load(id: id).metadata.schemaVersion == 2)
    #expect(try Data(contentsOf: backup) == existing)
    let backups = try FileManager.default.contentsOfDirectory(
      at: backup.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    let additional = try #require(backups.first { $0 != backup })
    #expect(try Data(contentsOf: additional) == original)
    #expect(try DocumentMigration.migrateLibrary(at: root) == 0)
  }

  @Test(arguments: [StorageWritePoint.temporaryFlushed, .renamed], [false, true])
  func interruptedReplacementCanResume(point: StorageWritePoint, hasOlderBackup: Bool) throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, id, original) = try seed()
    let target = store.metadataURL(id)
    let backup = root.appending(path: "MigrationBackups/schema-1/Metadata/\(id.uuidString).json")
    let older = Data("earlier original".utf8)
    if hasOlderBackup {
      try FileManager.default.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      try older.write(to: backup)
    }
    struct Interruption: Error {}
    #expect(throws: Interruption.self) {
      try StorageFaults.$handler.withValue(
        { reached, url in
          if reached == point && url == target { throw Interruption() }
        }, operation: { try DocumentMigration.migrateLibrary(at: root) })
    }
    #expect(try Data(contentsOf: backup) == (hasOlderBackup ? older : original))
    let backups = try FileManager.default.contentsOfDirectory(
      at: backup.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    #expect(try backups.contains { try Data(contentsOf: $0) == original })
    let library = try SheetLibrary(root: root)
    #expect(try library.load(id: id).metadata.schemaVersion == 2)
    #expect(try library.index.summaries().contains { $0.id == id })
    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: "Index/unsynchronized").path))
  }
}
