import Foundation
import Testing

@testable import GanitDocuments

/// Follows each instruction in docs/storage/recovery-guide.md against a real
/// library on disk, so the guide stays true.
@Suite
struct RecoveryRehearsalTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitRecoveryRehearsal-\(UUID().uuidString)", directoryHint: .isDirectory)

  /// Moving to a new Mac or reinstalling: copy the library folder.
  @Test
  func copiedLibraryFolderOpensWithEverySheet() throws {
    let library = try SheetLibrary(root: root.appending(path: "Old"))
    let ids = try seed(library)

    let copy = root.appending(path: "New", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: root.appending(path: "Old"), to: copy)
    let reopened = try SheetLibrary(root: copy)

    #expect(Set(try reopened.index.summaries().map(\.id)) == Set(ids))
    for id in ids {
      let original = try library.store.load(id: id)
      let moved = try reopened.store.load(id: id)
      #expect(moved.source == original.source)
      #expect(moved.metadata.title == original.metadata.title)
      #expect(moved.isChecksumValid)
    }
  }

  /// Keeping an independent copy: export every sheet and import them into an
  /// empty library.
  @Test
  func exportedPackagesRebuildTheLibraryElsewhere() throws {
    let library = try SheetLibrary(root: root.appending(path: "Library"))
    let ids = try seed(library)
    let exports = root.appending(path: "Exports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    for id in ids {
      try library.exportSheet(id, to: exports.appending(path: "\(id).ganit"), quickLook: nil)
    }

    let fresh = try SheetLibrary(root: root.appending(path: "Fresh"))
    for id in ids {
      _ = try fresh.importSheet(
        from: exports.appending(path: "\(id).ganit"), preferences: .standard)
    }

    for id in ids {
      #expect(try fresh.store.load(id: id).source == library.store.load(id: id).source)
      #expect(
        try fresh.store.load(id: id).metadata.title == library.store.load(id: id).metadata.title)
    }
  }

  /// Returning to an older Ganit: sheets saved in a newer format are left
  /// untouched, and the rest of the library keeps working.
  @Test
  func olderVersionLeavesNewerSheetsUntouched() throws {
    let library = try SheetLibrary(root: root)
    let ids = try seed(library)
    let newer = ids[0]
    let metadataURL = library.store.metadataURL(newer)
    let future = try String(contentsOf: metadataURL, encoding: .utf8)
      .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
    try Data(future.utf8).write(to: metadataURL)
    let sourceBefore = try Data(contentsOf: library.store.sourceURL(newer))
    try FileManager.default.removeItem(at: root.appending(path: "Index"))

    let reopened = try SheetLibrary(root: root)
    let report = try reopened.recoverAndRebuildIndex()
    _ = try reopened.save(source: "changed", metadata: reopened.store.load(id: ids[1]).metadata)

    #expect(report.unreadable == [newer])
    #expect(try Data(contentsOf: metadataURL) == Data(future.utf8))
    #expect(try Data(contentsOf: reopened.store.sourceURL(newer)) == sourceBefore)
    #expect(try reopened.store.load(id: ids[1]).source == "changed")
  }

  /// Undoing a bad day's edits: restore the version from before them.
  @Test
  func previousVersionRestoresFromBackups() throws {
    var day = Date(timeIntervalSince1970: 1_789_459_200)
    let library = try SheetLibrary(
      root: root, timeZone: try #require(TimeZone(identifier: "UTC")), now: { day })
    var metadata = try library.save(
      source: "good", metadata: library.create(preferences: .standard))
    day += 86_400
    metadata = try library.save(source: "mistake", metadata: metadata)

    let backup = try #require(try library.backups(of: metadata.id).first)
    _ = try library.save(source: try library.load(backup).source, metadata: metadata)

    #expect(try library.store.load(id: metadata.id).source == "good")
  }

  private func seed(_ library: SheetLibrary) throws -> [UUID] {
    try ["# Rent\nrent = 2,100\nrent * 12", "# Trip\nhotel = 85 * 3", "1 USD = 83 INR"].map {
      try library.save(source: $0, metadata: library.create(preferences: .standard)).id
    }
  }
}
