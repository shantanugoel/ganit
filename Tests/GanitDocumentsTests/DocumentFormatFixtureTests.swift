import CryptoKit
import Foundation
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// Frozen sheet metadata and `.ganit` manifest schema 2 fixtures, written by
/// hand from docs/storage/sheet-files.md and docs/storage/ganit-format.md.
/// Schema 2 is the only schema read or written; every other version is
/// refused without conversion. Changing any byte is a format change: update
/// the specifications, docs/reference/schema-freeze.md and these checksums
/// deliberately.
@Suite struct DocumentFormatFixtureTests {
  static let checksums = [
    "Library/Metadata/6A4E2C10-0000-4000-8000-000000000001.json":
      "75d6e5deccc7e84ac3008a8a5b57662546b1dcc76d515ca2c8050c2d7927bf46",
    "Library/Metadata/6A4E2C10-0000-4000-8000-000000000002.json":
      "9a818a13eb348177c947e903c105ff681a39d53a2ac9dec730364970a31dc472",
    "Library/Sheets/6A4E2C10-0000-4000-8000-000000000001.txt":
      "178cf3b0ea72b05985270a71e43a952ccce29b1b48bd17f4bd7c721d859df128",
    "Library/Sheets/6A4E2C10-0000-4000-8000-000000000002.txt":
      "5c4cb546ad12928b7363e50069befee3260b060b8789a5d70ef1473281464428",
    "Packages/Schema1.ganit/manifest.json":
      "4ddbdf9fc0250eda1bd7fc8747ef1c978adcf8140841d0ee6ee5424823106ad6",
    "Packages/Schema1.ganit/source.txt":
      "178cf3b0ea72b05985270a71e43a952ccce29b1b48bd17f4bd7c721d859df128",
    "Packages/Table.ganit/manifest.json":
      "2ad355ce216625c44343b49fc88b9febf4859024ae80e331efcde88d3441882a",
    "Packages/Table.ganit/source.txt":
      "5c4cb546ad12928b7363e50069befee3260b060b8789a5d70ef1473281464428",
    "Rejected/metadata-invalid-column-id.json":
      "6832326064ae3dc43a50056338f64cb0190e533477576d95d79eff3912934d6c",
    "Rejected/metadata-negative-width.json":
      "7f222e67b01adb8a9834d99d997434b59d3ceed538dc31baf596e508fc9ce273",
    "Rejected/metadata-oversized-width.json":
      "989fe24bda6f368f4240af5da5d2d9771cb48ab200362e421e561b1abeff15a2",
    "Rejected/metadata-schema-1.json":
      "d2b264bde7ca09b57a7155e917ef85b035eb854ad06f7cec70849aeb66f7f1b5",
    "Rejected/metadata-schema-3.json":
      "7bbda0aa3d87bd4c5e1d3ee33efe5d4cd7dc79272d8ca56a34176b1f16a69542",
    "Rejected/metadata-uppercase-table-id.json":
      "f6d9ba18901950e2f2f163222b87ed189cd4e1cf810051e8188c768864a52513",
  ]

  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)

  static let ordinaryID = UUID(uuidString: "6A4E2C10-0000-4000-8000-000000000001")!
  static let tableSheetID = UUID(uuidString: "6A4E2C10-0000-4000-8000-000000000002")!
  static let tableID = "10000000-0000-4000-8000-000000000001"
  static let columnWidths = [
    "10000000-0000-4000-8000-000000000011": 120.0,
    "10000000-0000-4000-8000-000000000012": 96.5,
  ]

  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitFormatFixtures-\(UUID().uuidString)", directoryHint: .isDirectory)

  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: path))
  }

  static func metadataPath(_ id: UUID) -> String {
    "Library/Metadata/\(id.uuidString).json"
  }

  /// A writable copy of a fixture directory.
  private func copy(_ path: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appending(path: URL(fileURLWithPath: path).lastPathComponent)
    try FileManager.default.copyItem(at: Self.directory.appending(path: path), to: destination)
    return destination
  }

  @Test func fixturesAreFrozen() throws {
    let enumerator = try #require(
      FileManager.default.enumerator(atPath: Self.directory.path))
    var paths: Set<String> = []
    for case let path as String in enumerator {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(
        atPath: Self.directory.appending(path: path).path, isDirectory: &isDirectory)
      if !isDirectory.boolValue && !URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") {
        paths.insert(path)
      }
    }
    // The corruption drills' inputs are frozen here too.
    let checksums = Self.checksums.merging(CorruptionDrillTests.checksums) { $1 }
    #expect(paths == Set(checksums.keys))
    for (path, checksum) in checksums {
      let digest = SHA256.hash(data: try Self.data(path))
      #expect(digest.map { String(format: "%02x", $0) }.joined() == checksum, "\(path) changed")
    }
  }

  @Test(arguments: [
    metadataPath(ordinaryID), metadataPath(tableSheetID),
  ])
  func metadataReencodesByteForByte(path: String) throws {
    let data = try Self.data(path)
    let metadata = try SheetStore.decoder.decode(SheetMetadata.self, from: data)
    #expect(metadata.schemaVersion == 2)
    #expect(try SheetStore.encoder.encode(metadata) == data)
  }

  @Test func manifestReencodesByteForByte() throws {
    let data = try Self.data("Packages/Table.ganit/manifest.json")
    let manifest = try SheetExchange.decoder.decode(GanitManifest.self, from: data)
    #expect(manifest.schemaVersion == 2)
    #expect(try SheetExchange.encoder.encode(manifest) == data)
  }

  @Test func libraryFixturesLoad() throws {
    let store = SheetStore(root: try copy("Library"))
    #expect(try store.sheetIDs() == [Self.ordinaryID, Self.tableSheetID])

    let ordinary = try store.load(id: Self.ordinaryID)
    #expect(ordinary.isChecksumValid)
    #expect(ordinary.source == "# Rent\nrent = 2,100\nrent * 12\n")
    #expect(ordinary.metadata.title == "Rent" && !ordinary.metadata.hasCustomTitle)
    #expect(ordinary.metadata.folderID == UUID(uuidString: "6A4E2C10-0000-4000-8000-0000000000F1"))
    #expect(ordinary.metadata.isFavorite && ordinary.metadata.state == .active)
    #expect(ordinary.metadata.preferences == .standard)
    #expect(ordinary.metadata.tables == TablePresentations())
    #expect(ordinary.metadata.createdAt == Date(timeIntervalSince1970: 1_789_459_200))

    let sheet = try store.load(id: Self.tableSheetID)
    #expect(sheet.isChecksumValid)
    let bytes = try Self.data("Library/Sheets/\(Self.tableSheetID.uuidString).txt")
    #expect(sheet.source.utf8.elementsEqual(bytes))
    #expect(sheet.metadata.title == "Shopping rates" && sheet.metadata.hasCustomTitle)
    #expect(sheet.metadata.folderID == nil && sheet.metadata.state == .archived)
    let preferences = sheet.metadata.preferences
    #expect(preferences.usesDecimalComma && preferences.angleMode == .degrees)
    #expect(preferences.significantDecimalDigits == 12)
    var display = SheetPreferences.standard.display
    display.groupsInLakhs = true
    display.numbers = .scientific
    display.writesAnswersInline = true
    display.showsAnswerSeparator = false
    display.answerFormats = ["rate * 3": .fixedDecimals(2)]
    display.dollarCurrency = "INR"
    display.ambiguousSuffixes = ["m": .unit]
    #expect(preferences.display == display)
    #expect(
      sheet.metadata.tables
        == TablePresentations([Self.tableID: TablePresentation(columnWidths: Self.columnWidths)]))

    // The presentation names the valid table block the source holds.
    let document = TableSourceDocument(sheet.source)
    #expect(document.diagnostics.isEmpty)
    let table = try #require(document.blocks.first?.table)
    #expect(document.blocks.count == 1)
    #expect(table.id.string == Self.tableID)
    #expect(Set(table.columns.map(\.id.string)) == Set(Self.columnWidths.keys))
  }

  /// Saving an unchanged current-format sheet writes the fixture's bytes.
  @Test(arguments: [ordinaryID, tableSheetID])
  func savingAFixtureRewritesItExactly(id: UUID) throws {
    let library = try copy("Library")
    let store = SheetStore(root: library)
    let sheet = try store.load(id: id)

    try store.save(source: sheet.source, metadata: sheet.metadata)

    #expect(
      try Data(contentsOf: store.metadataURL(id)) == Self.data(Self.metadataPath(id)))
    #expect(try store.saveMetadata(sheet.metadata) == sheet.metadata)
    #expect(
      try Data(contentsOf: store.metadataURL(id)) == Self.data(Self.metadataPath(id)))
  }

  @Test func packageFixtureReads() throws {
    let package = try copy("Packages/Table.ganit")
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.isChecksumValid)
    #expect(exchanged.source.utf8.elementsEqual(try Self.data("Packages/Table.ganit/source.txt")))
    #expect(exchanged.source.contains("\r\n"))
    let manifest = try #require(exchanged.manifest)
    #expect(manifest.id == Self.tableSheetID && manifest.title == "Shopping rates")
    #expect(manifest.hasCustomTitle && manifest.preferences.usesDecimalComma)
    #expect(
      manifest.tables
        == TablePresentations([Self.tableID: TablePresentation(columnWidths: Self.columnWidths)]))
    #expect(TableSourceDocument(exchanged.source).diagnostics.isEmpty)
  }

  /// Exporting the library fixture writes the package fixture exactly, and
  /// importing that package keeps the table presentation.
  @Test func exportWritesThePackageFixtureAndImportKeepsIt() throws {
    let store = SheetStore(root: try copy("Library"))
    let sheet = try store.load(id: Self.tableSheetID)
    let package = root.appending(path: "Export.ganit")

    try SheetExchange.write(
      source: sheet.source, metadata: sheet.metadata, to: package, quickLook: nil)

    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: package.path))
        == ["manifest.json", "source.txt"])
    for name in ["manifest.json", "source.txt"] {
      #expect(
        try Data(contentsOf: package.appending(path: name))
          == Self.data("Packages/Table.ganit/\(name)"))
    }

    let library = try SheetLibrary(root: root.appending(path: "Imported"))
    let imported = try library.importSheet(
      from: try copy("Packages/Table.ganit"), preferences: .standard)
    #expect(imported.id == Self.tableSheetID)
    #expect(imported.tables == sheet.metadata.tables)
    #expect(try library.store.load(id: imported.id).metadata.tables == sheet.metadata.tables)
  }

  @Test(arguments: [
    ("Rejected/metadata-schema-1.json", ordinaryID, 1),
    ("Rejected/metadata-schema-3.json", tableSheetID, 3),
  ])
  func unsupportedMetadataSchemasAreRefused(path: String, id: UUID, version: Int) throws {
    let store = SheetStore(root: try copy("Library"))
    try Self.data(path).write(to: store.metadataURL(id))
    #expect(throws: DocumentStorageError.unsupportedSchemaVersion(version)) {
      try store.load(id: id)
    }
  }

  @Test(arguments: [
    "Rejected/metadata-uppercase-table-id.json",
    "Rejected/metadata-invalid-column-id.json",
    "Rejected/metadata-negative-width.json",
    "Rejected/metadata-oversized-width.json",
  ])
  func invalidTablePresentationIsCorruptMetadata(path: String) throws {
    let store = SheetStore(root: try copy("Library"))
    try Self.data(path).write(to: store.metadataURL(Self.tableSheetID))
    let error = #expect(throws: DecodingError.self) {
      try store.load(id: Self.tableSheetID)
    }
    guard case .dataCorrupted = error else {
      Issue.record("Expected corrupt data, got \(String(describing: error))")
      return
    }
  }

  @Test func unsupportedManifestSchemaIsRefused() throws {
    let package = try copy("Packages/Schema1.ganit")
    #expect(throws: SheetExchangeError.unsupportedSchemaVersion(1)) {
      try SheetExchange.read(from: package)
    }
  }

  /// Refusals say which format the file is in and that it was left alone.
  @Test func refusalsExplainThemselves() {
    let sheet = DocumentStorageError.unsupportedSchemaVersion(1)
    #expect(
      sheet.localizedDescription
        == "This sheet was saved in format 1, which this version of Ganit can't open.")
    #expect(sheet.recoverySuggestion == "The file was left unchanged.")
    let package = SheetExchangeError.unsupportedSchemaVersion(3)
    #expect(
      package.localizedDescription
        == "This Ganit sheet was saved in format 3, which this version of Ganit can't open.")
    #expect(package.recoverySuggestion == "The file was left unchanged.")
    #expect(
      SheetExchangeError.tooLarge(URL(fileURLWithPath: "/tmp/Trip.ganit")).localizedDescription
        == "“Trip.ganit” is larger than a Ganit sheet can be.")
  }

  /// Versions other than the integer 2 are refused; none is converted.
  @Test(arguments: [
    ("0", true), ("-2", true), ("99", true), ("\"2\"", false), ("2.5", false), ("null", false),
  ])
  func onlyTheIntegerTwoIsAVersion(replacement: String, isInteger: Bool) throws {
    let store = SheetStore(root: try copy("Library"))
    let metadata = try String(
      decoding: Self.data(Self.metadataPath(Self.ordinaryID)), as: UTF8.self
    ).replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : \(replacement)")
    try Data(metadata.utf8).write(to: store.metadataURL(Self.ordinaryID))
    let package = try copy("Packages/Table.ganit")
    let manifest = try String(
      decoding: Self.data("Packages/Table.ganit/manifest.json"), as: UTF8.self
    ).replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : \(replacement)")
    try Data(manifest.utf8).write(to: package.appending(path: "manifest.json"))

    if isInteger, let version = Int(replacement) {
      #expect(throws: DocumentStorageError.unsupportedSchemaVersion(version)) {
        try store.load(id: Self.ordinaryID)
      }
      #expect(throws: SheetExchangeError.unsupportedSchemaVersion(version)) {
        try SheetExchange.read(from: package)
      }
    } else {
      #expect(throws: DecodingError.self) { try store.load(id: Self.ordinaryID) }
      #expect(throws: DecodingError.self) { try SheetExchange.read(from: package) }
    }
  }

  /// Every schema 2 key is written, so none is filled in when missing.
  @Test(arguments: ["schemaVersion", "tables", "display", "hasCustomTitle", "sourceChecksum"])
  func missingSchemaKeysAreRefused(key: String) throws {
    let store = SheetStore(root: try copy("Library"))
    let url = store.metadataURL(Self.ordinaryID)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    if key == "display" {
      var preferences = try #require(object["preferences"] as? [String: Any])
      #expect(preferences.removeValue(forKey: key) != nil)
      object["preferences"] = preferences
    } else {
      #expect(object.removeValue(forKey: key) != nil)
    }
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    #expect(throws: DecodingError.self) { try store.load(id: Self.ordinaryID) }
  }

  /// Presentation of a table or column the source no longer names is dropped
  /// on save; a malformed block that still names its table keeps it.
  @Test func writersDropPresentationTheSourceLacks() throws {
    let library = try copy("Library")
    let store = SheetStore(root: library)
    let sheet = try store.load(id: Self.tableSheetID)
    let stale = "20000000-0000-4000-8000-000000000001"
    let staleColumn = "20000000-0000-4000-8000-000000000011"
    var metadata = sheet.metadata
    metadata.tables.setWidth(80, column: staleColumn, table: stale)
    metadata.tables.setWidth(80, column: staleColumn, table: Self.tableID)
    #expect(metadata.tables.byTableID.count == 2)
    #expect(metadata.tables.byTableID[Self.tableID]?.columnWidths.count == 3)

    #expect(
      try store.save(source: sheet.source, metadata: metadata).tables == sheet.metadata.tables)
    #expect(try store.load(id: Self.tableSheetID).metadata.tables == sheet.metadata.tables)
    #expect(try store.saveMetadata(metadata).tables == sheet.metadata.tables)
    #expect(try store.load(id: Self.tableSheetID).metadata.tables == sheet.metadata.tables)

    let package = root.appending(path: "Pruned.ganit")
    try SheetExchange.write(source: sheet.source, metadata: metadata, to: package, quickLook: nil)
    #expect(try SheetExchange.read(from: package).manifest?.tables == sheet.metadata.tables)

    let malformed = sheet.source.replacingOccurrences(of: "\"t\":0", with: "\"t\":")
    #expect(!TableSourceDocument(malformed).diagnostics.isEmpty)
    #expect(try store.save(source: malformed, metadata: metadata).tables == sheet.metadata.tables)
    #expect(try store.save(source: "1 + 1", metadata: metadata).tables == TablePresentations())
  }

  /// Widths can only be set to valid values: identities must be canonical,
  /// widths finite, and they are clamped to the allowed range.
  @Test func settingWidthsKeepsPresentationValid() {
    let column = "10000000-0000-4000-8000-000000000011"
    var tables = TablePresentations()
    tables.setWidth(120, column: column, table: "10000000-0000-4000-8000-00000000000A")
    tables.setWidth(120, column: "Currency", table: Self.tableID)
    tables.setWidth(.nan, column: column, table: Self.tableID)
    tables.setWidth(.infinity, column: column, table: Self.tableID)
    #expect(tables == TablePresentations())

    tables.setWidth(0.000_1, column: column, table: Self.tableID)
    #expect(tables.byTableID[Self.tableID]?.columnWidths[column] == 1)
    tables.setWidth(1e9, column: column, table: Self.tableID)
    #expect(tables.byTableID[Self.tableID]?.columnWidths[column] == 10_000)
    tables.setWidth(nil, column: column, table: Self.tableID)
    #expect(tables == TablePresentations())
  }

  /// Presentation never keeps a sheet from saving: invalid in-memory entries
  /// are dropped, and the new source and the valid entries are written.
  @Test(arguments: [
    ["10000000-0000-4000-8000-00000000000A": TablePresentation()],
    [tableID: TablePresentation(columnWidths: ["Rate": 10])],
    [tableID: TablePresentation(columnWidths: [tableID: 0.5])],
    [tableID: TablePresentation(columnWidths: [tableID: .nan])],
    [tableID: TablePresentation(columnWidths: [tableID: .infinity])],
    [tableID: TablePresentation(columnWidths: [tableID: 10_001])],
  ])
  func writersDropInvalidPresentation(invalid: [String: TablePresentation]) throws {
    let store = SheetStore(root: try copy("Library"))
    let sheet = try store.load(id: Self.tableSheetID)
    var metadata = sheet.metadata
    var tables = sheet.metadata.tables.byTableID
    let invalidTable = try #require(invalid.keys.first)
    if let valid = tables[invalidTable] {
      tables[invalidTable] = TablePresentation(
        columnWidths: valid.columnWidths.merging(invalid[invalidTable]!.columnWidths) { $1 })
    } else {
      tables.merge(invalid) { $1 }
    }
    metadata.tables = TablePresentations(tables)
    // The source names every identity, so only validity drops entries.
    let source = sheet.source + "\n" + invalidTable + "\nchanged"

    let saved = try store.save(source: source, metadata: metadata)

    #expect(saved.tables == sheet.metadata.tables)
    let loaded = try store.load(id: Self.tableSheetID)
    #expect(loaded.source == source && loaded.isChecksumValid)
    #expect(loaded.metadata.tables == sheet.metadata.tables)

    let package = root.appending(path: "Valid.ganit")
    try SheetExchange.write(source: source, metadata: metadata, to: package, quickLook: nil)
    #expect(try SheetExchange.read(from: package).manifest?.tables == sheet.metadata.tables)
  }

  /// Reading stays strict: widths below a point and keys a presentation does
  /// not define make the metadata invalid.
  @Test(arguments: [
    ("\" : 96.5", "\" : 0.5"),
    ("\" : 96.5", "\" : 5e-324"),
    ("      \"columnWidths\" : {", "      \"collapsed\" : true,\n      \"columnWidths\" : {"),
  ])
  func strictReadingRejectsOtherPresentation(original: String, replacement: String) throws {
    let store = SheetStore(root: try copy("Library"))
    let fixture = try String(
      decoding: Self.data(Self.metadataPath(Self.tableSheetID)), as: UTF8.self)
    let edited = fixture.replacingOccurrences(of: original, with: replacement)
    #expect(edited != fixture)
    try Data(edited.utf8).write(to: store.metadataURL(Self.tableSheetID))
    #expect(throws: DecodingError.self) { try store.load(id: Self.tableSheetID) }
  }

  /// An entry without `columnWidths` is reported as missing that key.
  @Test func anEntryWithoutWidthsIsMissingAKey() throws {
    let store = SheetStore(root: try copy("Library"))
    let url = store.metadataURL(Self.tableSheetID)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["tables"] = [Self.tableID: [String: Any]()]
    try JSONSerialization.data(withJSONObject: object).write(to: url)

    let error = #expect(throws: DecodingError.self) { try store.load(id: Self.tableSheetID) }
    guard case .keyNotFound(let key, _) = error else {
      Issue.record("Expected a missing key, got \(String(describing: error))")
      return
    }
    #expect(key.stringValue == "columnWidths")
  }

  /// Widths alone never keep a sheet from exporting: when they would make
  /// the manifest larger than import accepts, they are left out.
  @Test func exportLeavesOutPresentationTooLargeForTheManifest() throws {
    let library = try SheetLibrary(root: root.appending(path: "Widths"))
    let columns = (1...1_300).map { String(format: "30000000-0000-4000-8000-%012x", $0) }
    let table = "30000000-0000-4000-8000-000000000000"
    let source = "# Wide\n" + ([table] + columns).joined(separator: "\n")
    var metadata = try library.create(preferences: .standard)
    for column in columns {
      metadata.tables.setWidth(120, column: column, table: table)
    }
    let sheet = try library.save(source: source, metadata: metadata)
    #expect(sheet.tables.byTableID[table]?.columnWidths.count == columns.count)
    #expect(try SheetStore.encoder.encode(sheet).count > SheetExchange.maximumManifestBytes)
    let package = root.appending(path: "Wide.ganit")

    try library.exportSheet(sheet.id, to: package, quickLook: nil)

    let manifest = try Data(contentsOf: package.appending(path: "manifest.json"))
    #expect(manifest.count <= SheetExchange.maximumManifestBytes)
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.source == source && exchanged.manifest?.tables == TablePresentations())
    let imported = try SheetLibrary(root: root.appending(path: "Imported"))
      .importSheet(from: package, preferences: .standard)
    #expect(imported.tables == TablePresentations())
  }

  /// Export refuses to write a package import would reject, and writes
  /// nothing.
  @Test func exportRefusesAPackageImportWouldReject() throws {
    let store = SheetStore(root: try copy("Library"))
    var metadata = try store.load(id: Self.ordinaryID).metadata
    metadata.title = String(repeating: "x", count: SheetExchange.maximumManifestBytes)
    let package = root.appending(path: "Huge.ganit")

    #expect(throws: SheetExchangeError.tooLarge(package)) {
      try SheetExchange.write(source: "1", metadata: metadata, to: package, quickLook: nil)
    }
    let source = String(repeating: "1", count: SheetExchange.maximumSourceBytes + 1)
    #expect(throws: SheetExchangeError.tooLarge(package)) {
      try SheetExchange.write(
        source: source, metadata: store.load(id: Self.ordinaryID).metadata, to: package,
        quickLook: nil)
    }
    #expect(!FileManager.default.fileExists(atPath: package.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Library"])
  }

  /// Invalid presentation on disk makes the metadata corrupt: recovery moves
  /// it to `Quarantine/` and rebuilds metadata from the source, so the title,
  /// folder, favorite flag, state, preferences, and widths reset while the
  /// source and its tables survive.
  @Test func invalidPresentationOnDiskIsRecoveredFromSource() throws {
    let copied = try copy("Library")
    let bad = try Self.data("Rejected/metadata-negative-width.json")
    try bad.write(to: SheetStore(root: copied).metadataURL(Self.tableSheetID))
    let source = try Self.data("Library/Sheets/\(Self.tableSheetID.uuidString).txt")

    let library = try SheetLibrary(root: copied)

    #expect(library.unreadableSheetIDs.isEmpty)
    let recovered = try library.store.load(id: Self.tableSheetID)
    #expect(recovered.source.utf8.elementsEqual(source) && recovered.isChecksumValid)
    #expect(recovered.metadata.title == "Shopping" && !recovered.metadata.hasCustomTitle)
    #expect(recovered.metadata.state == .active && recovered.metadata.preferences == .standard)
    #expect(recovered.metadata.tables == TablePresentations())
    let quarantine = copied.appending(path: "Quarantine")
    let names = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
    #expect(names.count == 1 && names[0].hasPrefix(Self.tableSheetID.uuidString))
    #expect(try Data(contentsOf: quarantine.appending(path: names[0])) == bad)
    #expect(TableSourceDocument(recovered.source).diagnostics.isEmpty)
  }
}
