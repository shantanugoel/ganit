import Foundation
import Testing

@testable import GanitDocuments

@Suite
struct SheetLibraryTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let preferences = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .radians,
    significantDecimalDigits: 15
  )

  @Test
  func savesSheetsWithDerivedTitlesAndIndexesThem() throws {
    let clock = Clock()
    let library = try makeLibrary(clock)
    let created = try library.create(preferences: preferences)

    let saved = try library.save(source: "\n  # Trip budget \nhotel = 85", metadata: created)

    #expect(saved.title == "Trip budget")
    #expect(saved.modifiedAt == clock.now)
    #expect(try library.index.summaries().map(\.title) == ["Trip budget"])
    #expect(try library.index.search("hotel") == [created.id])
    #expect(try library.store.load(id: created.id).source == "\n  # Trip budget \nhotel = 85")
  }

  @Test
  func restoresTheVersionFromBeforeEachDaysFirstChange() throws {
    let clock = Clock()
    let library = try makeLibrary(clock)
    var metadata = try library.create(preferences: preferences)
    metadata = try library.save(source: "v1", metadata: metadata)
    metadata = try library.save(source: "v2", metadata: metadata)
    clock.advance(days: 1)
    metadata = try library.save(source: "v3", metadata: metadata)
    metadata = try library.save(source: "v4", metadata: metadata)

    let backups = try library.backups(of: metadata.id)
    #expect(backups.map(\.day) == ["2026-09-16", "2026-09-15"])
    #expect(try library.load(backups[0]).source == "v2")
    #expect(try library.load(backups[1]).source == "")

    // Restoring saves the backup as the current version.
    let restored = try library.load(backups[0])
    try library.save(source: restored.source, metadata: metadata)
    let current = try library.store.load(id: metadata.id)
    #expect(current.source == "v2")
    #expect(current.isChecksumValid)
    #expect(try library.index.search("v2") == [metadata.id])
  }

  @Test
  func prunesBackupsByAgeAndSizeKeepingTheNewestDay() throws {
    let clock = Clock()
    let library = try makeLibrary(
      clock, policy: BackupPolicy(maximumDays: 2, maximumBytes: 100 << 20))
    var metadata = try library.create(preferences: preferences)
    for version in 1...4 {
      clock.advance(days: 1)
      metadata = try library.save(source: "v\(version)", metadata: metadata)
    }
    #expect(try library.backups(of: metadata.id).map(\.day) == ["2026-09-19", "2026-09-18"])

    let tight = try makeLibrary(clock, policy: BackupPolicy(maximumDays: 30, maximumBytes: 1))
    clock.advance(days: 1)
    metadata = try tight.save(source: "v5", metadata: metadata)
    #expect(try tight.backups(of: metadata.id).map(\.day) == ["2026-09-20"])
  }

  @Test
  func opensWithARebuiltIndexWhenTheIndexIsMissing() throws {
    let clock = Clock()
    var library: SheetLibrary? = try makeLibrary(clock)
    let metadata = try library!.save(
      source: "kept", metadata: library!.create(preferences: preferences))
    library = nil
    try FileManager.default.removeItem(at: root.appending(path: "Index"))

    let reopened = try makeLibrary(clock)
    #expect(try reopened.index.summaries().map(\.id) == [metadata.id])
  }

  @Test
  func aNewLibraryGetsAScratchSheet() throws {
    let library = try makeLibrary(Clock())
    let scratch = try library.openScratch()
    #expect(scratch.id == SheetLibrary.scratchID && scratch.title == "Scratch")
    #expect(try library.store.load(id: SheetLibrary.scratchID).source == "")
    #expect(try library.openScratch() == scratch)
  }

  /// A scratch sheet in an unsupported schema is refused, never replaced by
  /// a new empty one, and leaves no backup behind.
  @Test(arguments: [0, 3])
  func anUnreadableScratchSheetIsLeftUntouched(version: Int) throws {
    let clock = Clock()
    var library = try makeLibrary(clock)
    try library.save(source: "scratch work", metadata: library.openScratch())
    let metadataURL = library.store.metadataURL(SheetLibrary.scratchID)
    let sourceURL = library.store.sourceURL(SheetLibrary.scratchID)
    let metadata = Data(
      try String(contentsOf: metadataURL, encoding: .utf8)
        .replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : \(version)")
        .utf8)
    try metadata.write(to: metadataURL)
    let source = try Data(contentsOf: sourceURL)
    let backups = try library.backups(of: SheetLibrary.scratchID)
    clock.advance(days: 1)

    library = try makeLibrary(clock)
    #expect(throws: DocumentStorageError.unsupportedSchemaVersion(version)) {
      try library.openScratch()
    }

    #expect(try Data(contentsOf: metadataURL) == metadata)
    #expect(try Data(contentsOf: sourceURL) == source)
    #expect(try library.backups(of: SheetLibrary.scratchID) == backups)
  }

  /// Missing or corrupt current-schema scratch metadata is recovered from
  /// the source, as the library's recovery does, keeping the scratch title.
  @Test(arguments: [false, true])
  func scratchMetadataThatIsMissingOrCorruptIsRecovered(isMissing: Bool) throws {
    let library = try makeLibrary(Clock())
    try library.save(source: "scratch work", metadata: library.openScratch())
    let metadataURL = library.store.metadataURL(SheetLibrary.scratchID)
    if isMissing {
      try FileManager.default.removeItem(at: metadataURL)
    } else {
      try Data("{\"schemaVersion\" : 2".utf8).write(to: metadataURL)
    }

    let recovered = try library.openScratch()

    #expect(recovered.title == "Scratch" && recovered.hasCustomTitle)
    #expect(try library.store.load(id: SheetLibrary.scratchID).source == "scratch work")
    #expect(try library.index.summaries().map(\.title) == ["Scratch"])
  }

  /// Restoring a backup reads only the current schema; a backup in another
  /// schema is refused without conversion.
  @Test
  func aBackupInAnUnsupportedSchemaIsRefused() throws {
    let clock = Clock()
    let library = try makeLibrary(clock)
    var metadata = try library.save(
      source: "good", metadata: library.create(preferences: preferences))
    clock.advance(days: 1)
    metadata = try library.save(source: "later", metadata: metadata)
    let backup = try #require(try library.backups(of: metadata.id).first)
    #expect(try library.load(backup).source == "good")
    let backupMetadata = root.appending(
      path: "Backups/\(backup.day)/Metadata/\(metadata.id.uuidString).json")
    let schema1 = Data(
      try String(contentsOf: backupMetadata, encoding: .utf8)
        .replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : 1").utf8)
    try schema1.write(to: backupMetadata)

    #expect(throws: DocumentStorageError.unsupportedSchemaVersion(1)) {
      try library.load(backup)
    }
    #expect(try Data(contentsOf: backupMetadata) == schema1)
  }

  /// The library keeps the sheets its last rebuild could not read, so the app
  /// can say so.
  @Test
  func keepsTheSheetsTheLastRebuildCouldNotRead() throws {
    var library = try makeLibrary(Clock())
    #expect(library.unreadableSheetIDs.isEmpty)
    let sheet = try library.save(source: "1", metadata: library.create(preferences: preferences))
    try Data("{\"schemaVersion\" : 1}".utf8).write(to: library.store.metadataURL(sheet.id))
    try FileManager.default.removeItem(at: root.appending(path: "Index"))

    library = try makeLibrary(Clock())

    #expect(library.unreadableSheetIDs == [sheet.id])
    #expect(try library.recoverAndRebuildIndex().unreadable == [sheet.id])
    #expect(library.unreadableSheetIDs == [sheet.id])
  }

  private func makeLibrary(_ clock: Clock, policy: BackupPolicy = .default) throws -> SheetLibrary {
    try SheetLibrary(
      root: root,
      backupPolicy: policy,
      timeZone: try #require(TimeZone(identifier: "UTC")),
      now: { clock.now }
    )
  }
}

private final class Clock {
  private(set) var now = Date(timeIntervalSince1970: 1_789_459_200)

  func advance(days: Int) {
    now += TimeInterval(days * 86_400)
  }
}
