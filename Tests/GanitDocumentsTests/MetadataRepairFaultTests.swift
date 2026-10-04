import Foundation
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// Metadata repairs that cannot be written never keep a library from opening:
/// the sheet is reported, its source is untouched, other sheets keep working,
/// and the next open after the fault clears repairs it.
@Suite(.timeLimit(.minutes(5)))
final class MetadataRepairFaultTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitRepairFaults-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Metadata").path)
    try? FileManager.default.removeItem(at: root)
  }

  private var marker: URL { root.appending(path: "Index/unsynchronized") }

  private func url(_ path: String) -> URL { root.appending(path: path) }

  private func sourceURL(_ id: UUID) -> URL { url("Sheets/\(id.uuidString).txt") }
  private func metadataURL(_ id: UUID) -> URL { url("Metadata/\(id.uuidString).json") }

  /// A healthy sheet and a table-bearing one whose metadata will fail to
  /// repair.
  private func makeLibrary() throws -> (healthy: UUID, bad: UUID) {
    let library = try SheetLibrary(root: root)
    let healthy = try library.save(
      source: "# Healthy\n1 + 1", metadata: library.create(preferences: .standard))
    let bad = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    return (healthy.id, bad.id)
  }

  /// Opens the library after a failed repair: on demand, with a healthy
  /// index, or during the recovery a corrupt index starts.
  private func openAfterFailedRepair(of bad: UUID, corruptIndex: Bool) throws -> SheetLibrary {
    if corruptIndex {
      try Data("not a database".utf8).write(to: url("Index/index.sqlite"))
    } else {
      let library = try SheetLibrary(root: root)
      _ = try? library.load(id: bad)
      #expect(FileManager.default.fileExists(atPath: marker.path))
    }
    return try SheetLibrary(root: root)
  }

  private func expectHealthyWorks(_ library: SheetLibrary, _ healthy: UUID) throws {
    #expect(try library.load(id: healthy).source == "# Healthy\n1 + 1")
    #expect(try library.index.search("Healthy") == [healthy])
  }

  @Test(arguments: [false, true])
  func aQuarantineThatIsAFileKeepsCorruptMetadataReported(corruptIndex: Bool) throws {
    let (healthy, bad) = try makeLibrary()
    let garbage = Data("{ not json".utf8)
    try garbage.write(to: metadataURL(bad))
    try Data("a file, not a directory".utf8).write(to: url("Quarantine"))
    let source = try Data(contentsOf: sourceURL(bad))
    if !corruptIndex {
      #expect(throws: (any Error).self) { try SheetLibrary(root: self.root).load(id: bad) }
    }

    let library = try openAfterFailedRepair(of: bad, corruptIndex: corruptIndex)

    #expect(library.unrepairedSheetIDs == [bad])
    #expect(library.unreadableSheetIDs == [bad])
    #expect(try library.index.summaries().map(\.id).contains(bad) == false)
    try expectHealthyWorks(library, healthy)
    #expect(throws: (any Error).self) { try library.load(id: bad) }
    #expect(try Data(contentsOf: sourceURL(bad)) == source)
    #expect(try Data(contentsOf: metadataURL(bad)) == garbage)
    #expect(FileManager.default.fileExists(atPath: marker.path))

    // Once the fault is cleared, the next open repairs the sheet.
    try FileManager.default.removeItem(at: url("Quarantine"))
    let repaired = try SheetLibrary(root: root)
    #expect(repaired.unrepairedSheetIDs.isEmpty && repaired.unreadableSheetIDs.isEmpty)
    #expect(try repaired.store.load(id: bad).isChecksumValid)
    #expect(try Data(contentsOf: sourceURL(bad)) == source)
    #expect(try repaired.index.summaries().map(\.id).contains(bad))
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: url("Quarantine").path)
    #expect(quarantined.count == 1)
    #expect(try Data(contentsOf: url("Quarantine/\(quarantined[0])")) == garbage)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test(arguments: [false, true])
  func aReadOnlyMetadataFolderKeepsAStaleSheetOpen(corruptIndex: Bool) throws {
    let (healthy, bad) = try makeLibrary()
    let edited = "# Edited\n" + TableSources.new
    try Data(edited.utf8).write(to: sourceURL(bad))
    let metadata = try Data(contentsOf: metadataURL(bad))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: url("Metadata").path)
    if !corruptIndex {
      // A stale sheet whose checksum cannot be rewritten still opens.
      let library = try SheetLibrary(root: root)
      let sheet = try library.load(id: bad)
      #expect(sheet.source == edited && !sheet.isChecksumValid && sheet.metadataRepair == nil)
      #expect(library.unrepairedSheetIDs == [bad])
    }

    let library = try openAfterFailedRepair(of: bad, corruptIndex: corruptIndex)

    #expect(library.unrepairedSheetIDs == [bad])
    #expect(library.unreadableSheetIDs.isEmpty)
    #expect(try library.index.summaries().map(\.id).contains(bad))
    try expectHealthyWorks(library, healthy)
    let sheet = try library.load(id: bad)
    #expect(sheet.source == edited && !sheet.isChecksumValid)
    TableSources.expectIntact(
      String(decoding: try Data(contentsOf: sourceURL(bad)), as: UTF8.self),
      equals: edited)
    #expect(try Data(contentsOf: metadataURL(bad)) == metadata)
    #expect(FileManager.default.fileExists(atPath: marker.path))

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url("Metadata").path)
    let repaired = try SheetLibrary(root: root)
    #expect(repaired.unrepairedSheetIDs.isEmpty && repaired.unreadableSheetIDs.isEmpty)
    let loaded = try repaired.load(id: bad)
    #expect(loaded.isChecksumValid && loaded.source == edited && loaded.metadataRepair == nil)
    #expect(loaded.metadata.title == "Edited")
    #expect(try repaired.index.summaries().first { $0.id == bad }?.title == "Edited")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  /// Repairing a stale checksum also updates a title that follows the first
  /// line, in the metadata and the index; a custom title is kept.
  @Test(arguments: [false, true])
  func aStaleChecksumRepairUpdatesADerivedTitle(onDemand: Bool) throws {
    let library = try SheetLibrary(root: root)
    let derived = try library.save(
      source: "# Rent\n1", metadata: library.create(preferences: .standard))
    let named = try library.rename(
      library.save(source: "# Trip\n2", metadata: library.create(preferences: .standard)).id,
      to: "Named")
    try Data("# Groceries\n1".utf8).write(to: sourceURL(derived.id))
    try Data("# Holiday\n2".utf8).write(to: sourceURL(named.id))

    let reopened: SheetLibrary
    if onDemand {
      reopened = try SheetLibrary(root: root)
      #expect(try reopened.load(id: derived.id).metadataRepair == .checksum)
      #expect(try reopened.load(id: named.id).metadataRepair == .checksum)
    } else {
      try FileManager.default.removeItem(at: url("Index"))
      reopened = try SheetLibrary(root: root)
    }

    let titles = Dictionary(
      uniqueKeysWithValues: try reopened.index.summaries().map { ($0.id, $0.title) })
    #expect(titles[derived.id] == "Groceries" && titles[named.id] == "Named")
    let repaired = try reopened.store.load(id: derived.id)
    #expect(repaired.isChecksumValid && repaired.metadata.title == "Groceries")
    #expect(!repaired.metadata.hasCustomTitle)
    #expect(try reopened.store.load(id: named.id).metadata.title == "Named")
  }

  /// The scratch sheet keeps its name when its metadata is recreated.
  @Test(arguments: [false, true])
  func recoveredScratchMetadataKeepsItsName(onDemand: Bool) throws {
    let library = try SheetLibrary(root: root)
    try library.openScratch()
    try library.save(
      source: "first line",
      metadata: try library.store.load(id: SheetLibrary.scratchID).metadata)
    try Data("garbage".utf8).write(to: metadataURL(SheetLibrary.scratchID))

    let reopened: SheetLibrary
    if onDemand {
      reopened = try SheetLibrary(root: root)
      #expect(
        try reopened.load(id: SheetLibrary.scratchID).metadataRepair == .rebuiltFromSource)
    } else {
      try FileManager.default.removeItem(at: url("Index"))
      reopened = try SheetLibrary(root: root)
    }

    let scratch = try reopened.store.load(id: SheetLibrary.scratchID)
    #expect(scratch.metadata.title == "Scratch" && scratch.metadata.hasCustomTitle)
    #expect(scratch.source == "first line")
    #expect(try reopened.openScratch().title == "Scratch")
    #expect(try reopened.index.sheet(titled: "Scratch") == SheetLibrary.scratchID)
  }

  /// An empty index file, as an interrupted creation can leave, is rebuilt
  /// rather than trusted as an empty library.
  @Test func anEmptyIndexFileIsRebuilt() throws {
    let (healthy, bad) = try makeLibrary()
    try Data().write(to: url("Index/index.sqlite"))

    let library = try SheetLibrary(root: root)

    #expect(Set(try library.index.summaries().map(\.id)) == [healthy, bad])
  }
}
