import Foundation
import Testing

@testable import GanitDocuments

@Suite
struct SheetExchangeTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitExchangeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let preferences = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .degrees,
    significantDecimalDigits: 12
  )
  private let source = "# Trip\r\nhotel = 85 * 3 // 👍🏽\rtotal\n"

  @Test
  func packagesRoundTripSourceAndPortableMetadata() throws {
    let library = try SheetLibrary(root: root.appending(path: "A"))
    var sheet = try library.save(source: source, metadata: library.create(preferences: preferences))
    sheet = try library.rename(sheet.id, to: "Holiday")
    let package = root.appending(path: "Trip.ganit")

    try library.exportSheet(sheet.id, to: package)

    #expect(try Data(contentsOf: package.appending(path: "source.txt")) == Data(source.utf8))
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: package.path)) == [
        "manifest.json", "source.txt",
      ])
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.source == source)
    #expect(exchanged.isChecksumValid)
    #expect(exchanged.manifest?.id == sheet.id)
    #expect(exchanged.manifest?.title == "Holiday")
    #expect(exchanged.manifest?.preferences == preferences)

    let other = try SheetLibrary(root: root.appending(path: "B"))
    let imported = try other.importSheet(from: package, preferences: preferences)
    #expect(imported.id == sheet.id)
    #expect(imported.title == "Holiday" && imported.hasCustomTitle)
    #expect(try other.store.load(id: sheet.id).source == source)

    // Importing into a library that already has the ID makes a new sheet.
    let copy = try other.importSheet(from: package, preferences: preferences)
    #expect(copy.id != sheet.id)
    #expect(try other.store.sheetIDs().count == 2)
  }

  @Test
  func replacesAnExistingPackageAtomically() throws {
    let library = try SheetLibrary(root: root.appending(path: "A"))
    let sheet = try library.save(source: "old", metadata: library.create(preferences: preferences))
    let package = root.appending(path: "Sheet.ganit")
    try library.exportSheet(sheet.id, to: package)
    try library.save(source: "new", metadata: library.store.load(id: sheet.id).metadata)

    try library.exportSheet(sheet.id, to: package)

    #expect(try SheetExchange.read(from: package).source == "new")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        .isEmpty)
  }

  @Test
  func exportsAndImportsPlainTextBytesExactly() throws {
    let library = try SheetLibrary(root: root.appending(path: "A"))
    let sheet = try library.save(source: source, metadata: library.create(preferences: preferences))
    let text = root.appending(path: "Trip.txt")

    try library.exportSheet(sheet.id, to: text)
    #expect(try Data(contentsOf: text) == Data(source.utf8))

    let imported = try library.importSheet(from: text, preferences: preferences)
    #expect(imported.id != sheet.id)
    #expect(imported.title == "Trip")
    #expect(try library.store.load(id: imported.id).source == source)
  }

  @Test
  func rejectsInvalidTextAndUnknownSchemasButFlagsEditedSource() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invalid = root.appending(path: "bad.txt")
    try Data([0xC3, 0x28]).write(to: invalid)
    #expect(throws: SheetExchangeError.invalidUTF8(invalid)) {
      try SheetExchange.read(from: invalid)
    }

    let library = try SheetLibrary(root: root.appending(path: "A"))
    let sheet = try library.save(
      source: "1 + 1", metadata: library.create(preferences: preferences))
    let package = root.appending(path: "Sheet.ganit")
    try library.exportSheet(sheet.id, to: package)
    try Data("1 + 2".utf8).write(to: package.appending(path: "source.txt"))
    let edited = try SheetExchange.read(from: package)
    #expect(edited.source == "1 + 2")
    #expect(!edited.isChecksumValid)

    let manifest = package.appending(path: "manifest.json")
    let future = try String(contentsOf: manifest, encoding: .utf8)
      .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 7")
    try Data(future.utf8).write(to: manifest)
    #expect(throws: SheetExchangeError.unsupportedSchemaVersion(7)) {
      try SheetExchange.read(from: package)
    }
  }
}
