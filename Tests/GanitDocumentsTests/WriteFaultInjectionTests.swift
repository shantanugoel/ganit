import Foundation
import Testing

@_spi(StorageFaults) @testable import GanitDocuments
@testable import GanitEngine

/// Fails every durable write at each of its write points in turn, and checks
/// that table-bearing source stays complete and recoverable byte for byte.
///
/// Each operation runs once to record the points it reaches, then once per
/// point in a fresh copy of the same files, failing there.
@Suite(.timeLimit(.minutes(5)))
final class WriteFaultInjectionTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitWriteFaults-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
  private static let firstDay = "2026-09-15"
  private static let secondDay = "2026-09-16"
  private static let exportMetadata = SheetMetadata(
    id: UUID(uuidString: "6A4E2C10-0000-4000-8000-0000000000F1")!, title: "Shopping",
    createdAt: Date(timeIntervalSince1970: 1_789_459_200), preferences: .standard)
  private static let quickLook = QuickLookPreview(
    pdf: Data("pdf".utf8), thumbnailPNG: Data("png".utf8))

  @Test func theFaultSourcesHoldValidTablesBrokenReferencesAndAMalformedBlock() {
    for source in [TableSources.old, TableSources.new] {
      let document = TableSourceDocument(source)
      #expect(document.blocks.count == 3)
      #expect(document.blocks.compactMap(\.table).count == 2)
      let bindings = document.blocks.compactMap(\.table).flatMap(\.ledger).flatMap(\.bindings)
      #expect(bindings.filter(\.isDeleted).count == 2)
      #expect(document.diagnostics.map(\.code) == [.malformed])
      #expect(source.contains("#REF!") && source.contains("Items[Amount]"))
    }
    #expect(TableSources.old != TableSources.new)
  }

  @Test func storeSavesLeaveCompleteSourceAndRecoverableMetadata() throws {
    let (template, id) = try libraryTemplate()
    let source = "Sheets/\(id.uuidString).txt"
    let metadata = "Metadata/\(id.uuidString).json"

    let points = try injectFaultAtEveryPoint(of: template) { directory in
      let store = SheetStore(root: directory)
      try store.save(source: TableSources.new, metadata: store.load(id: id).metadata)
    } check: { directory, reached, error in
      let point = "\(reached.last!)"
      #expect(error is WriteFaults.Injected, "\(point)")
      let sourceReplaced = reached.contains(ReachedPoint(point: .renamed, path: source))
      let metadataReplaced = reached.contains(ReachedPoint(point: .renamed, path: metadata))
      let expected = sourceReplaced ? TableSources.new : TableSources.old
      TableSources.expectIntact(try Self.source(id, in: directory), equals: expected, "\(point)")
      #expect(WriteFaults.temporaryNames(under: directory).isEmpty, "\(point)")

      // Source written without its metadata leaves a stale checksum, which
      // recovery repairs without touching the source.
      let store = SheetStore(root: directory)
      #expect(try store.load(id: id).isChecksumValid == (sourceReplaced == metadataReplaced))
      try SheetLibrary(root: directory).recoverAndRebuildIndex()
      let recovered = try store.load(id: id)
      #expect(recovered.isChecksumValid, "\(point)")
      TableSources.expectIntact(recovered.source, equals: expected, "\(point)")
    }

    #expect(points == WriteFaults.atomicWrite(source) + WriteFaults.atomicWrite(metadata))
  }

  @Test func librarySavesBackUpFirstAndLeaveOneCompleteRecoverableVersion() throws {
    let (template, id) = try libraryTemplate()
    let source = "Sheets/\(id.uuidString).txt"
    let backupSource = "Backups/\(Self.secondDay)/Sheets/\(id.uuidString).txt"

    let points = try injectFaultAtEveryPoint(of: template) { directory in
      let library = try Self.library(at: directory, day: 1)
      try library.save(source: TableSources.new, metadata: library.store.load(id: id).metadata)
    } check: { directory, reached, error in
      let point = "\(reached.last!)"
      #expect(error is WriteFaults.Injected, "\(point)")
      let replaced = reached.contains(ReachedPoint(point: .renamed, path: source))
      let expected = replaced ? TableSources.new : TableSources.old
      TableSources.expectIntact(try Self.source(id, in: directory), equals: expected, "\(point)")
      #expect(WriteFaults.temporaryNames(under: directory).isEmpty, "\(point)")

      let marked = reached.contains(ReachedPoint(point: .synchronizingDirectory, path: "Index"))
      #expect(
        FileManager.default.fileExists(atPath: Self.marker(in: directory).path) == marked,
        "\(point)")
      let library = try Self.library(at: directory, day: 1)
      #expect(!FileManager.default.fileExists(atPath: Self.marker(in: directory).path))
      let sheet = try library.store.load(id: id)
      #expect(sheet.isChecksumValid, "\(point)")
      TableSources.expectIntact(sheet.source, equals: expected, "\(point)")
      #expect(try library.store.sheetIDs() == [id])
      #expect(try library.index.search(replaced ? "subtotal = 6" : "subtotal = 5") == [id])
      // A backup is visible only once its source, copied last, is complete.
      let backedUp = reached.contains(ReachedPoint(point: .renamed, path: backupSource))
      let days = backedUp ? [Self.secondDay, Self.firstDay] : [Self.firstDay]
      #expect(try library.backups(of: id).map(\.day) == days, "\(point)")

      // Saving again completes the change, and today's backup holds the
      // version it replaced.
      try library.save(source: TableSources.new, metadata: sheet.metadata)
      TableSources.expectIntact(try library.store.load(id: id).source, equals: TableSources.new)
      let backup = try library.load(try #require(library.backups(of: id).first))
      #expect(backup.isChecksumValid)
      TableSources.expectIntact(backup.source, equals: TableSources.old, "\(point)")
    }

    // Backup metadata, then backup source, then the durable index marker,
    // then source, then metadata.
    #expect(
      points
        == WriteFaults.atomicWrite("Backups/\(Self.secondDay)/Metadata/\(id.uuidString).json")
        + WriteFaults.atomicWrite(backupSource)
        + [ReachedPoint(point: .synchronizingDirectory, path: "Index")]
        + WriteFaults.atomicWrite(source)
        + WriteFaults.atomicWrite("Metadata/\(id.uuidString).json"))
  }

  @Test func metadataUpdatesNeverTouchSource() throws {
    let (template, id) = try libraryTemplate()
    let metadata = "Metadata/\(id.uuidString).json"

    let points = try injectFaultAtEveryPoint(of: template) { directory in
      try Self.library(at: directory, day: 1).update(id) {
        $0.title = "Renamed"
        $0.hasCustomTitle = true
      }
    } check: { directory, reached, error in
      let point = "\(reached.last!)"
      #expect(error is WriteFaults.Injected, "\(point)")
      TableSources.expectIntact(
        try Self.source(id, in: directory), equals: TableSources.old, "\(point)")
      #expect(WriteFaults.temporaryNames(under: directory).isEmpty, "\(point)")
      #expect(FileManager.default.fileExists(atPath: Self.marker(in: directory).path))

      let library = try Self.library(at: directory, day: 1)
      let sheet = try library.store.load(id: id)
      #expect(sheet.isChecksumValid)
      let renamed = reached.contains(ReachedPoint(point: .renamed, path: metadata))
      #expect(sheet.metadata.title == (renamed ? "Renamed" : "Shopping"), "\(point)")
      #expect(try library.index.summaries().map(\.title) == [sheet.metadata.title])
    }

    #expect(
      points
        == [ReachedPoint(point: .synchronizingDirectory, path: "Index")]
        + WriteFaults.atomicWrite(metadata))
  }

  /// A change that fails partway keeps the index marked unsynchronized even
  /// after a later change to another sheet succeeds, so the next open
  /// repairs the failed one.
  @Test func aFailedChangeKeepsTheIndexMarkedUntilRecovery() throws {
    let directory = root.appending(path: "Library", directoryHint: .isDirectory)
    let library = try Self.library(at: directory, day: 0)
    let failed = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    let other = try library.save(source: "b = 1", metadata: library.create(preferences: .standard))
    let failedMetadata = library.store.metadataURL(failed.id)

    let error = WriteFaults.failing(
      when: { $0 == .temporaryCreated && $1 == failedMetadata },
      { try library.save(source: TableSources.new, metadata: failed) })
    #expect(error is WriteFaults.Injected)
    #expect(try !library.store.load(id: failed.id).isChecksumValid)
    try library.save(source: "b = 2", metadata: other)
    #expect(FileManager.default.fileExists(atPath: Self.marker(in: directory).path))

    let reopened = try Self.library(at: directory, day: 0)
    let repaired = try reopened.store.load(id: failed.id)
    #expect(repaired.isChecksumValid)
    TableSources.expectIntact(repaired.source, equals: TableSources.new)
    #expect(try reopened.index.search("subtotal = 6") == [failed.id])
    #expect(!FileManager.default.fileExists(atPath: Self.marker(in: directory).path))
  }

  /// Recovery repairs a failed change, so the next successful change
  /// removes the marker again.
  @Test func recoveryLetsLaterChangesClearTheMarker() throws {
    let directory = root.appending(path: "Library", directoryHint: .isDirectory)
    let library = try Self.library(at: directory, day: 0)
    let sheet = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    // The second point is the source's temporary file, after the marker.
    let error = WriteFaults.failing(atHit: 2) {
      try library.save(source: TableSources.new, metadata: sheet)
    }
    #expect(error is WriteFaults.Injected)
    try library.save(source: TableSources.new, metadata: sheet)
    #expect(FileManager.default.fileExists(atPath: Self.marker(in: directory).path))

    try library.recoverAndRebuildIndex()
    #expect(!FileManager.default.fileExists(atPath: Self.marker(in: directory).path))
    try library.save(source: TableSources.old, metadata: sheet)
    #expect(!FileManager.default.fileExists(atPath: Self.marker(in: directory).path))
  }

  @Test(arguments: [false, true])
  func packageExportsLeaveTheOldOrTheNewPackage(replacing: Bool) throws {
    let references = try referencePackages()
    let template = root.appending(path: "Template", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    if replacing {
      try writePackage(TableSources.old, to: template.appending(path: "Export.ganit"))
    }

    let points = try injectFaultAtEveryPoint(of: template) { directory in
      try writePackage(TableSources.new, to: directory.appending(path: "Export.ganit"))
    } check: { directory, reached, error in
      let point = "\(reached.last!)"
      let package = directory.appending(path: "Export.ganit")
      let removing = reached.last?.point == .removingReplacedPackage
      // The export is complete once the package is in place and synchronized.
      if removing {
        #expect(error == nil)
      } else {
        #expect(error is WriteFaults.Injected, "\(point)")
      }
      let replaced = reached.contains(ReachedPoint(point: .packageReplaced, path: "Export.ganit"))
      let expected = replaced ? references.new : replacing ? references.old : nil
      #expect(try WriteFaults.packageContents(package) == expected, "\(point)")
      if expected != nil {
        let exchanged = try SheetExchange.read(from: package)
        #expect(exchanged.isChecksumValid)
        TableSources.expectIntact(
          exchanged.source, equals: replaced ? TableSources.new : TableSources.old, "\(point)")
      }
      // Once swapped out, the old package stays behind as a hidden sibling
      // unless the export completes and removes it.
      let leftovers = WriteFaults.temporaryNames(under: directory)
      if replaced && replacing {
        #expect(leftovers.count == 1)
        let hidden = directory.appending(path: try #require(leftovers.first))
        #expect(try WriteFaults.packageContents(hidden) == references.old)
      } else {
        #expect(leftovers.isEmpty, "\(point)")
      }
    }

    #expect(points == WriteFaults.packageWrite("Export.ganit", replacing: replacing))
  }

  @Test(arguments: [false, true])
  func plainTextExportsLeaveTheOldOrTheNewFile(replacing: Bool) throws {
    let template = root.appending(path: "Template", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    if replacing {
      try Data(TableSources.old.utf8).write(to: template.appending(path: "Export.txt"))
    }

    let points = try injectFaultAtEveryPoint(of: template) { directory in
      try SheetExchange.write(
        source: TableSources.new, metadata: Self.exportMetadata,
        to: directory.appending(path: "Export.txt"), quickLook: nil)
    } check: { directory, reached, error in
      let point = "\(reached.last!)"
      #expect(error is WriteFaults.Injected, "\(point)")
      let file = directory.appending(path: "Export.txt")
      let replaced = reached.contains(ReachedPoint(point: .renamed, path: "Export.txt"))
      if replaced || replacing {
        TableSources.expectIntact(
          try SheetExchange.read(from: file).source,
          equals: replaced ? TableSources.new : TableSources.old, "\(point)")
      } else {
        #expect(!FileManager.default.fileExists(atPath: file.path), "\(point)")
      }
      #expect(WriteFaults.temporaryNames(under: directory).isEmpty, "\(point)")
    }

    #expect(points == WriteFaults.atomicWrite("Export.txt"))
  }

  /// Backups of a table-bearing sheet are taken before each day's first
  /// change, restore byte for byte, and pruning keeps the newest day.
  @Test func tableSheetBackupsRestoreExactlyAndKeepTheNewestDay() throws {
    let clock = DayClock()
    let directory = root.appending(path: "Library", directoryHint: .isDirectory)
    var library = try SheetLibrary(
      root: directory, timeZone: try #require(TimeZone(identifier: "UTC")),
      now: { clock.now })
    var metadata = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    metadata = try library.save(source: TableSources.new, metadata: metadata)
    clock.day = 1
    // The day's first change backs up the version it replaces.
    metadata = try library.save(source: TableSources.old, metadata: metadata)
    #expect(try library.backups(of: metadata.id).map(\.day) == [Self.secondDay, Self.firstDay])
    let backup = try library.load(try #require(library.backups(of: metadata.id).first))
    #expect(backup.isChecksumValid)
    TableSources.expectIntact(backup.source, equals: TableSources.new)
    // Later changes that day keep that backup.
    metadata = try library.save(source: "1 + 1", metadata: metadata)
    TableSources.expectIntact(
      try library.load(try #require(library.backups(of: metadata.id).first)).source,
      equals: TableSources.new)

    // Restoring saves the backup's exact source as the current version.
    metadata = try library.save(source: backup.source, metadata: metadata)
    let restored = try SheetLibrary(root: directory).store.load(id: metadata.id)
    #expect(restored.isChecksumValid)
    TableSources.expectIntact(restored.source, equals: TableSources.new)

    // A size limit smaller than one day removes older days, never the newest.
    library = try SheetLibrary(
      root: directory, backupPolicy: BackupPolicy(maximumDays: 30, maximumBytes: 1),
      timeZone: try #require(TimeZone(identifier: "UTC")), now: { clock.now })
    clock.day = 2
    metadata = try library.save(source: TableSources.old, metadata: metadata)
    #expect(try library.backups(of: metadata.id).map(\.day) == ["2026-09-17"])
    TableSources.expectIntact(
      try library.load(try #require(library.backups(of: metadata.id).first)).source,
      equals: TableSources.new)
  }

  // MARK: Support

  /// Runs `operation` in a copy of `template` to record the points it
  /// reaches, then once per point in a fresh copy, failing there. `check`
  /// gets the copy, the points reached including the failing one, and what
  /// `operation` threw.
  private func injectFaultAtEveryPoint(
    of template: URL,
    _ operation: (URL) throws -> Void,
    check: (URL, ArraySlice<ReachedPoint>, (any Error)?) throws -> Void
  ) throws -> [ReachedPoint] {
    let recording = try copy(template, as: "Recording")
    let points = try WriteFaults.record(in: recording) { try operation(recording) }
    #expect(!points.isEmpty)
    for hit in points.indices {
      let directory = try copy(template, as: "Fault-\(hit)")
      let error = WriteFaults.failing(atHit: hit + 1) { try operation(directory) }
      try check(directory, points[...hit], error)
    }
    return points
  }

  private func copy(_ template: URL, as name: String) throws -> URL {
    let directory = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: template, to: directory)
    return directory
  }

  /// A library holding one sheet with `TableSources.old`, saved on the first
  /// day, so a save on the second day backs it up first.
  private func libraryTemplate() throws -> (URL, UUID) {
    let template = root.appending(path: "Template", directoryHint: .isDirectory)
    let library = try Self.library(at: template, day: 0)
    let saved = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    return (template, saved.id)
  }

  private func referencePackages() throws -> (old: [String: Data], new: [String: Data]) {
    let directory = root.appending(path: "References", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var contents: [[String: Data]] = []
    for (name, source) in [("Old", TableSources.old), ("New", TableSources.new)] {
      let package = directory.appending(path: "\(name).ganit")
      try writePackage(source, to: package)
      contents.append(try #require(try WriteFaults.packageContents(package)))
    }
    return (contents[0], contents[1])
  }

  private func writePackage(_ source: String, to url: URL) throws {
    try SheetExchange.write(
      source: source, metadata: Self.exportMetadata, to: url, quickLook: Self.quickLook)
  }

  private static func library(at directory: URL, day: Int) throws -> SheetLibrary {
    let now = Date(timeIntervalSince1970: 1_789_459_200 + TimeInterval(day * 86_400))
    return try SheetLibrary(
      root: directory, timeZone: try #require(TimeZone(identifier: "UTC")), now: { now })
  }

  private static func source(_ id: UUID, in directory: URL) throws -> String {
    String(decoding: try Data(contentsOf: SheetStore(root: directory).sourceURL(id)), as: UTF8.self)
  }

  private static func marker(in directory: URL) -> URL {
    directory.appending(path: "Index/unsynchronized")
  }
}

private final class DayClock {
  var day = 0
  var now: Date { Date(timeIntervalSince1970: 1_789_459_200 + TimeInterval(day * 86_400)) }
}
