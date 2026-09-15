import Foundation
import GanitDocuments
import Testing

@testable import GanitWorkspaceUI

@Suite
struct SheetCollectionTests {
  @Test
  func filtersSheetsByCollectionAndSearch() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "GanitCollectionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var now = Date(timeIntervalSince1970: 1_789_459_200)
    let library = try SheetLibrary(root: root, now: { now })
    let travel = try library.createFolder(named: "Travel")
    func sheet(_ source: String, _ change: (inout SheetMetadata) -> Void = { _ in }) throws -> UUID
    {
      let created = try library.save(
        source: source,
        metadata: library.create(preferences: SheetPreferences.standard))
      return try library.update(created.id, change).id
    }
    let old = try sheet("# Old budget")
    now += 10 * 86_400
    let trip = try sheet("# Trip\nhotel = 85") {
      $0.folderID = travel.id
      $0.isFavorite = true
    }
    let archived = try sheet("# Taxes 2025") { $0.state = .archived }
    let trashed = try sheet("# Scratch hotel") { $0.state = .trashed }

    func ids(_ collection: SheetCollection, _ search: String = "") throws -> [UUID] {
      try library.sheets(in: collection, matching: search, now: now).map(\.id)
    }
    #expect(try ids(.all) == [trip, old])
    #expect(try ids(.recent) == [trip])
    #expect(try ids(.favorites) == [trip])
    #expect(try ids(.folder(travel.id)) == [trip])
    #expect(try ids(.archive) == [archived])
    #expect(try ids(.trash) == [trashed])
    #expect(try ids(.all, "HOTEL") == [trip])
    #expect(try ids(.trash, "hotel") == [trashed])
    #expect(try ids(.all, "taxes").isEmpty)
  }
}
