import Foundation
import GanitEngine
import Testing

@testable import GanitDocuments

@Suite
struct SheetStoreTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitDocumentsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func roundTripsSourceBytesAndMetadata() throws {
    let store = SheetStore(root: root)
    let source = "# Trip\r\nrent = 2,100\rtax = 8% // 👍🏽\n\n"
    let metadata = makeMetadata()

    let saved = try store.save(source: source, metadata: metadata)
    let loaded = try store.load(id: metadata.id)

    #expect(
      try Data(contentsOf: root.appending(path: "Sheets/\(metadata.id.uuidString).txt"))
        == Data(source.utf8))
    #expect(loaded.source == source)
    #expect(loaded.metadata == saved)
    #expect(loaded.isChecksumValid)
    #expect(saved.sourceChecksum.hasPrefix("sha256:") && saved.sourceChecksum.count == 71)
    #expect(try store.sheetIDs() == [metadata.id])
  }

  /// A new sheet writes numbers as this Mac's region does; the choice is a
  /// locale stored with the sheet, and decides how its numbers are read.
  @Test
  func newSheetsFollowTheRegionsDecimalSeparator() throws {
    #expect(!SheetPreferences.newSheet(locale: Locale(identifier: "en_US")).usesDecimalComma)
    let german = SheetPreferences.newSheet(locale: Locale(identifier: "de_DE"))
    #expect(german.usesDecimalComma)
    #expect(german.localeIdentifier == "en-DE")
    #expect(try german.evaluationContext().lexingConfiguration == .decimalComma)
    #expect(
      try SheetPreferences.standard.evaluationContext().lexingConfiguration == .englishUnitedStates)
  }

  @Test
  func writesReadableVersionedMetadata() throws {
    let store = SheetStore(root: root)
    let metadata = makeMetadata()
    try store.save(source: "1 + 1", metadata: metadata)

    let json = try String(
      contentsOf: root.appending(path: "Metadata/\(metadata.id.uuidString).json"),
      encoding: .utf8
    )
    #expect(json.contains("\"schemaVersion\" : 1"))
    #expect(json.contains("\"createdAt\" : \"2026-09-15T08:00:00Z\""))
    #expect(json.contains("\"localeIdentifier\" : \"en-US\""))
    let keys = json.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map {
      $0.split(separator: "\"")[1]
    }
    #expect(keys == keys.sorted())
  }

  /// A sheet saved before sheets could say how to write their answers names no
  /// display, and opens with the standard one.
  @Test
  func opensASheetSavedBeforeItCouldSayHowToWriteAnswers() throws {
    let store = SheetStore(root: root)
    let metadata = makeMetadata()
    try store.save(source: "1234.5", metadata: metadata)
    let metadataURL = root.appending(path: "Metadata/\(metadata.id.uuidString).json")
    let json = try String(contentsOf: metadataURL, encoding: .utf8)
    let withoutDisplay = try #require(
      try? JSONSerialization.data(
        withJSONObject: strippingDisplay(from: json),
        options: [.sortedKeys]
      )
    )
    try withoutDisplay.write(to: metadataURL)

    let loaded = try store.load(id: metadata.id)
    #expect(loaded.metadata.preferences.display == .standard)
    #expect(loaded.metadata.preferences == metadata.preferences)
  }

  private func strippingDisplay(from json: String) throws -> [String: Any] {
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    var preferences = try #require(object["preferences"] as? [String: Any])
    #expect(preferences.removeValue(forKey: "display") != nil)
    object["preferences"] = preferences
    return object
  }

  @Test
  func detectsSourceThatNoLongerMatchesMetadata() throws {
    let store = SheetStore(root: root)
    let metadata = makeMetadata()
    try store.save(source: "1 + 1", metadata: metadata)

    try Data("1 + 2".utf8).write(to: root.appending(path: "Sheets/\(metadata.id.uuidString).txt"))
    let loaded = try store.load(id: metadata.id)

    #expect(loaded.source == "1 + 2")
    #expect(!loaded.isChecksumValid)
  }

  @Test
  func rejectsInvalidUTF8AndUnsupportedSchemas() throws {
    let store = SheetStore(root: root)
    let metadata = makeMetadata()
    try store.save(source: "1", metadata: metadata)
    let sourceURL = root.appending(path: "Sheets/\(metadata.id.uuidString).txt")
    let metadataURL = root.appending(path: "Metadata/\(metadata.id.uuidString).json")

    try Data([0x31, 0xFF]).write(to: sourceURL)
    #expect(throws: DocumentStorageError.invalidUTF8(sourceURL)) {
      try store.load(id: metadata.id)
    }

    try Data("1".utf8).write(to: sourceURL)
    let future = try String(contentsOf: metadataURL, encoding: .utf8)
      .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
    try Data(future.utf8).write(to: metadataURL)
    #expect(throws: DocumentStorageError.unsupportedSchemaVersion(2)) {
      try store.load(id: metadata.id)
    }
  }

  @Test
  func discoversSheetsByScanningAndIgnoresTemporaryFiles() throws {
    let store = SheetStore(root: root)
    #expect(try store.sheetIDs().isEmpty)
    let ids = try (0..<3).map { index -> UUID in
      let metadata = makeMetadata()
      try store.save(source: "\(index)", metadata: metadata)
      return metadata.id
    }
    let sheets = root.appending(path: "Sheets")
    try Data("partial".utf8).write(to: sheets.appending(path: ".\(ids[0].uuidString).txt.ABC.tmp"))
    try Data().write(to: sheets.appending(path: "notes.txt"))

    #expect(try store.sheetIDs() == ids.sorted { $0.uuidString < $1.uuidString })
  }

  @Test
  func atomicReplaceLeavesNoTemporaryFilesAndKeepsOldContentOnFailure() throws {
    let store = SheetStore(root: root)
    let metadata = makeMetadata()
    try store.save(source: "old", metadata: metadata)
    try store.save(source: "new", metadata: metadata)
    let sheets = root.appending(path: "Sheets")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: sheets.path) == [
        "\(metadata.id.uuidString).txt"
      ])

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sheets.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sheets.path)
    }
    #expect(throws: DocumentStorageError.self) {
      try store.save(source: "newer", metadata: metadata)
    }
    #expect(try store.load(id: metadata.id).source == "new")
    #expect(try store.load(id: metadata.id).isChecksumValid)
  }

  private func makeMetadata() -> SheetMetadata {
    SheetMetadata(
      title: "Trip",
      createdAt: Date(timeIntervalSince1970: 1_789_459_200),
      preferences: SheetPreferences(
        localeIdentifier: "en-US",
        angleMode: .radians,
        significantDecimalDigits: 15
      )
    )
  }
}
