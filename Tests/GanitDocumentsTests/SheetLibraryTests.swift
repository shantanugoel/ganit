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
