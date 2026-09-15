import Foundation
import Testing

@testable import GanitDocuments

@Suite
struct SheetIndexTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitIndexTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var indexURL: URL {
    root.appending(path: "Index/index.sqlite")
  }

  @Test
  func listsAndSearchesIndexedSheets() throws {
    let index = try SheetIndex(url: indexURL)
    #expect(index.needsRebuild)
    let trip = metadata("Trip to Zürich", modified: 30)
    let rent = metadata("Rent", modified: 20, favorite: true)
    try index.upsert(trip, source: "hotel = 3 * 85")
    try index.upsert(rent, source: "monthly RENT = 2,100\u{0}// note")

    #expect(try index.summaries().map(\.title) == ["Trip to Zürich", "Rent"])
    #expect(try index.summaries().last?.isFavorite == true)
    #expect(try index.search("zurich") == [trip.id])
    #expect(try index.search("rent") == [rent.id])
    #expect(try index.search("note") == [rent.id])
    #expect(try index.search("85") == [trip.id])

    var renamed = trip
    renamed.title = "Trip"
    try index.upsert(renamed, source: "hotel = 3 * 85")
    try index.remove(id: rent.id)
    #expect(try index.summaries().map(\.title) == ["Trip"])
  }

  @Test
  func findsTheSheetATitleNames() throws {
    let index = try SheetIndex(url: indexURL)
    let zurich = metadata("Trip to Zürich", modified: 30)
    let trip = metadata("Trip", modified: 20)
    var archived = metadata("Groceries", modified: 40)
    archived.state = .archived
    for sheet in [zurich, trip, archived] {
      try index.upsert(sheet, source: "1 + 1")
    }

    // A whole-title match wins over the more recent sheet that contains it.
    #expect(try index.sheet(titled: "trip") == trip.id)
    #expect(try index.sheet(titled: "zurich") == zurich.id)
    #expect(try index.sheet(titled: "Trip to") == zurich.id)
    #expect(try index.sheet(titled: "Groceries") == nil)
    #expect(try index.sheet(titled: "  ") == nil)
    #expect(try index.sheet(titled: "budget") == nil)
  }

  @Test
  func deletedIndexRebuildsFromSheetFilesWithoutLosingContent() throws {
    let store = SheetStore(root: root)
    let saved = try [("Alpha", 1), ("Beta", 2)].map { title, modified in
      try store.save(
        source: "\(title) = \(modified)", metadata: metadata(title, modified: Double(modified)))
    }
    var index: SheetIndex? = try SheetIndex(url: indexURL)
    try index?.rebuild(from: store)
    index = nil
    try FileManager.default.removeItem(at: indexURL)

    let rebuilt = try SheetIndex(url: indexURL)
    #expect(rebuilt.needsRebuild)
    let report = try rebuilt.rebuild(from: store)

    #expect(report == IndexRebuildReport(indexedCount: 2, unreadable: []))
    #expect(!rebuilt.needsRebuild)
    #expect(try rebuilt.summaries().map(\.id) == saved.reversed().map(\.id))
    #expect(try rebuilt.search("beta = 2") == [saved[1].id])
  }

  @Test
  func replacesACorruptOrIncompatibleIndex() throws {
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x5A, count: 4_096).write(to: indexURL)
    let recovered = try SheetIndex(url: indexURL)
    #expect(recovered.needsRebuild)
    try recovered.upsert(metadata("Kept", modified: 1), source: "1")
    #expect(try recovered.summaries().count == 1)

    let healthy = try SheetIndex(url: indexURL)
    #expect(!healthy.needsRebuild)
    #expect(try healthy.summaries().count == 1)
  }

  @Test
  func rebuildReportsUnreadableSheetsAndLeavesTheirFiles() throws {
    let store = SheetStore(root: root)
    let good = try store.save(source: "1", metadata: metadata("Good", modified: 1))
    let bad = try store.save(source: "2", metadata: metadata("Bad", modified: 2))
    let badMetadata = root.appending(path: "Metadata/\(bad.id.uuidString).json")
    try Data("{".utf8).write(to: badMetadata)

    let index = try SheetIndex(url: indexURL)
    let report = try index.rebuild(from: store)

    #expect(report == IndexRebuildReport(indexedCount: 1, unreadable: [bad.id]))
    #expect(try index.summaries().map(\.id) == [good.id])
    #expect(try Data(contentsOf: badMetadata) == Data("{".utf8))
  }

  private func metadata(_ title: String, modified: Double, favorite: Bool = false) -> SheetMetadata
  {
    var metadata = SheetMetadata(
      title: title,
      createdAt: Date(timeIntervalSince1970: 0),
      isFavorite: favorite,
      preferences: SheetPreferences(
        localeIdentifier: "en-US",
        angleMode: .radians,
        significantDecimalDigits: 15
      )
    )
    metadata.modifiedAt = Date(timeIntervalSince1970: modified)
    return metadata
  }
}
