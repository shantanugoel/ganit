import Foundation
import Testing

@testable import GanitDocuments

@Suite
struct SheetOrganizationTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitOrganizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let preferences = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .radians,
    significantDecimalDigits: 15
  )

  @Test
  func renamedTitlesPersistUntilCleared() throws {
    let library = try SheetLibrary(root: root)
    var sheet = try library.save(
      source: "# Trip", metadata: library.create(preferences: preferences))

    sheet = try library.rename(sheet.id, to: "Holiday")
    sheet = try library.save(source: "# Trip\n1 + 1", metadata: sheet)
    #expect(sheet.title == "Holiday")
    #expect(try library.index.summaries().first?.title == "Holiday")

    sheet = try library.rename(sheet.id, to: "")
    #expect(sheet.title == "Trip")
    #expect(!sheet.hasCustomTitle)
  }

  @Test
  func favoritesArchivesAndMovesWithoutTouchingSource() throws {
    let library = try SheetLibrary(root: root)
    let folder = try library.createFolder(named: "Travel")
    let sheet = try library.save(
      source: "12 km", metadata: library.create(preferences: preferences))

    let updated = try library.update(sheet.id) {
      $0.isFavorite = true
      $0.state = .archived
      $0.folderID = folder.id
    }

    let stored = try library.store.load(id: sheet.id)
    #expect(stored.source == "12 km")
    #expect(stored.isChecksumValid)
    #expect(stored.metadata == updated)
    #expect(updated.modifiedAt == sheet.modifiedAt)
    let summary = try #require(try library.index.summaries().first)
    #expect(summary.isFavorite && summary.state == .archived && summary.folderID == folder.id)
  }

  @Test
  func duplicatesIntoANewSheetInTheSameFolder() throws {
    let library = try SheetLibrary(root: root)
    let folder = try library.createFolder(named: "Travel")
    var original = try library.save(
      source: "hotel = 85", metadata: library.create(preferences: preferences))
    original = try library.update(original.id) { $0.folderID = folder.id }

    let copy = try library.duplicate(original.id)

    #expect(copy.id != original.id)
    #expect(copy.folderID == folder.id)
    #expect(try library.store.load(id: copy.id).source == "hotel = 85")
    #expect(Set(try library.index.search("hotel")) == [original.id, copy.id])
  }

  @Test
  func deletesTrashedSheetsWithTheirBackupsPermanently() throws {
    var now = Date(timeIntervalSince1970: 1_789_459_200)
    let library = try SheetLibrary(root: root, now: { now })
    var kept = try library.create(preferences: preferences)
    var trashed = try library.create(preferences: preferences)
    now += 86_400
    kept = try library.save(source: "kept", metadata: kept)
    trashed = try library.save(source: "gone", metadata: trashed)
    #expect(!(try library.backups(of: trashed.id)).isEmpty)

    try library.update(trashed.id) { $0.state = .trashed }
    try library.emptyTrash()

    #expect(try library.store.sheetIDs() == [kept.id])
    #expect(try library.index.summaries().map(\.id) == [kept.id])
    #expect(try library.backups(of: trashed.id).isEmpty)
    #expect(!(try library.backups(of: kept.id)).isEmpty)
  }

  @Test
  func deletingAFolderMovesItsSheetsOut() throws {
    let library = try SheetLibrary(root: root)
    let travel = try library.createFolder(named: "Travel")
    let work = try library.createFolder(named: "Work")
    let sheet = try library.create(preferences: preferences)
    try library.update(sheet.id) { $0.folderID = travel.id }

    try library.renameFolder(work.id, to: "Office")
    try library.deleteFolder(travel.id)

    #expect(try library.folders() == [SheetFolder(id: work.id, name: "Office")])
    #expect(try library.store.load(id: sheet.id).metadata.folderID == nil)
    #expect(try SheetLibrary(root: root).folders().map(\.name) == ["Office"])
  }
}
