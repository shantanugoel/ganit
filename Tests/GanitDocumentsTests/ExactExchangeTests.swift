import Foundation
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// Plain UTF-8 source and current-format `.ganit` packages import and export
/// a sheet's exact bytes: line endings, Unicode, table identities, bindings,
/// `#REF!` markers, and malformed, unknown and unterminated blocks, as
/// docs/storage/ganit-format.md describes. Import removes only a leading
/// byte-order mark, and refuses what it cannot keep exactly without writing.
@Suite
final class ExactExchangeTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitExactExchange-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
  private static let ratesTable = "10000000-0000-4000-8000-000000000001"
  private static let ratesColumn = "10000000-0000-4000-8000-000000000011"
  private static let itemsTable = "20000000-0000-4000-8000-000000000001"
  private static let itemsColumn = "20000000-0000-4000-8000-000000000011"

  /// Every frozen table block fixture, and two sources built from them.
  static let sourceNames: [String] = {
    // The fixtures are checked in; failing to list them is a broken checkout.
    let names = try! FileManager.default.contentsOfDirectory(atPath: TableSources.fixtures.path)
      .filter { $0.hasSuffix(".txt") }.sorted()
    precondition(names.count >= 13, "Table block fixtures are missing")
    return names + ["no-final-line-ending", "separators-and-marks"]
  }()

  /// A named source's bytes, read without decoding.
  static func source(_ name: String) throws -> Data {
    let fixture = { (name: String) in
      try Data(contentsOf: TableSources.fixtures.appending(path: name))
    }
    switch name {
    case "no-final-line-ending":
      let bytes = try fixture("valid-two-tables.txt")
      #expect(bytes.last == 0x0A)
      return bytes.dropLast()
    case "separators-and-marks":
      // U+2028, U+2029 and NEL do not end lines; decomposed text and an
      // inner U+FEFF are text. The unterminated block runs to the end.
      return try Data("# Café\u{2028}still the title\u{2029}\u{0085}x = 1\r".utf8)
        + fixture("unicode.txt")
        + Data("decomposed = Cafe\u{301}\r\ninner\u{FEFF}mark\n".utf8)
        + Data(TableSources.old.utf8)
        + fixture("unsupported-version.txt")
        + fixture("unterminated.txt").dropLast()
    default:
      return try fixture(name)
    }
  }

  /// The Rates table block from the fixture, as the first lines of a sheet.
  private static var tableFirst: String {
    let lines = TableSources.fixture("valid-two-tables.txt")
      .split(separator: "\n", omittingEmptySubsequences: false)
    return lines[2..<5].joined(separator: "\n") + "\nrate = 2\n"
  }

  private func url(_ path: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appending(path: path)
  }

  private func storedBytes(of id: UUID, in library: SheetLibrary) throws -> Data {
    try Data(contentsOf: library.store.sourceURL(id))
  }

  /// Every file under a library, so a refused import can show it wrote
  /// nothing.
  private func files(_ library: SheetLibrary) throws -> [String: Data] {
    try #require(try WriteFaults.packageContents(library.store.root))
  }

  @Test(arguments: sourceNames)
  func plainSourceAndPackagesKeepExactBytes(name: String) throws {
    let bytes = try Self.source(name)
    let original = try #require(exactUTF8(bytes))
    #expect(!TableSourceDocument(original).blocks.isEmpty)
    let file = try url("In.txt")
    try bytes.write(to: file)
    let library = try SheetLibrary(root: try url("Library"))

    let imported = try library.importSheet(from: file, preferences: .standard)

    #expect(try storedBytes(of: imported.id, in: library) == bytes)
    let stored = try library.load(id: imported.id)
    #expect(stored.isChecksumValid && stored.metadataRepair == nil)
    TableSources.expectIntact(stored.source, equals: original)

    let text = try url("Out.txt")
    try library.exportSheet(imported.id, to: text, quickLook: nil)
    #expect(try Data(contentsOf: text) == bytes)

    let package = try url("Out.ganit")
    try library.exportSheet(imported.id, to: package, quickLook: nil)
    #expect(try Data(contentsOf: package.appending(path: "source.txt")) == bytes)
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.isChecksumValid && exchanged.manifest?.id == imported.id)
    TableSources.expectIntact(exchanged.source, equals: original)

    let other = try SheetLibrary(root: try url("Other"))
    let fromPackage = try other.importSheet(from: package, preferences: .standard)
    let fromText = try other.importSheet(from: text, preferences: .standard)
    #expect(fromPackage.id == imported.id && fromText.id != imported.id)
    for id in [fromPackage.id, fromText.id] {
      #expect(try storedBytes(of: id, in: other) == bytes)
      TableSources.expectIntact(try other.load(id: id).source, equals: original)
    }
  }

  /// A leading byte-order mark is an encoding signature, not text: import
  /// removes one, so a table on the first line is still a table, and keeps
  /// every other byte. Export never writes one.
  @Test
  func importRemovesOnlyOneLeadingByteOrderMark() throws {
    let source = Self.tableFirst
    let file = try url("Marked.txt")
    try (Self.byteOrderMark + Data(source.utf8)).write(to: file)
    let library = try SheetLibrary(root: try url("Library"))

    let imported = try library.importSheet(from: file, preferences: .standard)

    #expect(try storedBytes(of: imported.id, in: library) == Data(source.utf8))
    let document = TableSourceDocument(try library.load(id: imported.id).source)
    #expect(document.blocks.first?.table?.id.string == Self.ratesTable)
    #expect(document.blocks.first?.physicalLines == 0..<3)
    let text = try url("Unmarked.txt")
    try library.exportSheet(imported.id, to: text, quickLook: nil)
    #expect(try Data(contentsOf: text) == Data(source.utf8))

    // A package's source.txt is read the same way, and its checksum is
    // compared with the source as imported.
    let package = try url("Marked.ganit")
    try library.exportSheet(imported.id, to: package, quickLook: nil)
    let packaged = package.appending(path: "source.txt")
    try (Self.byteOrderMark + Data(contentsOf: packaged)).write(to: packaged)
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.isChecksumValid)
    TableSources.expectIntact(exchanged.source, equals: source)

    // Only the first mark is a signature; one after it, or later, is text.
    for (input, expected) in [
      (Self.byteOrderMark + Self.byteOrderMark + Data("1 + 1".utf8), "\u{FEFF}1 + 1"),
      (Data("1\u{FEFF} + 1\r\n".utf8), "1\u{FEFF} + 1\r\n"),
      (Self.byteOrderMark, ""),
    ] {
      try input.write(to: file)
      let sheet = try library.importSheet(from: file, preferences: .standard)
      #expect(try storedBytes(of: sheet.id, in: library) == Data(expected.utf8))
    }
  }

  /// U+FEFF at the start of a sheet's own text is text: the library, its
  /// metadata recovery, backups and text documents keep it, and plain-text
  /// export writes it. Importing that file reads it as a signature.
  @Test
  func libraryKeepsALeadingFEFFThatIsText() throws {
    let source = "\u{FEFF}" + TableSources.old
    let library = try SheetLibrary(root: try url("Library"))
    // A new sheet's first save has nothing to back up.
    let sheet = try library.save(
      source: source, metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard))
    TableSources.expectIntact(try library.store.load(id: sheet.id).source, equals: source)

    try FileManager.default.removeItem(at: library.store.metadataURL(sheet.id))
    let recovered = try library.load(id: sheet.id)
    #expect(recovered.metadataRepair == .rebuiltFromSource)
    TableSources.expectIntact(recovered.source, equals: source)

    let text = try url("Leading.txt")
    try library.exportSheet(sheet.id, to: text, quickLook: nil)
    #expect(try Data(contentsOf: text) == Data(source.utf8))
    let imported = try library.importSheet(from: text, preferences: .standard)
    TableSources.expectIntact(
      try library.load(id: imported.id).source, equals: TableSources.old)

    try library.save(source: "changed", metadata: recovered.metadata)
    let backup = try #require(try library.backups(of: sheet.id).first)
    TableSources.expectIntact(try library.load(backup).source, equals: source)

    let document = TextDocumentStore(url: try url("Quick.txt"))
    try document.save(source)
    TableSources.expectIntact(document.load(), equals: source)
  }

  /// Bytes that are not UTF-8, including UTF-16 with its byte-order mark,
  /// are refused by name, plain or packaged, and nothing is written.
  @Test(
    arguments: [
      [0xC3, 0x28], [0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
      [0xE2, 0x82], [0xFF, 0xFE, 0x31, 0x00], [0xFE, 0xFF, 0x00, 0x31],
    ] as [[UInt8]])
  func nonUTF8IsRefusedWithoutWriting(invalid: [UInt8]) throws {
    let library = try SheetLibrary(root: try url("Library"))
    let sheet = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    let package = try url("Bad.ganit")
    try library.exportSheet(sheet.id, to: package, quickLook: nil)
    let before = try files(library)
    let text = try url("Bad.txt")
    for (file, reported) in [(text, text), (package.appending(path: "source.txt"), package)] {
      try (Data(TableSources.old.utf8) + Data(invalid)).write(to: file)
      #expect(throws: SheetExchangeError.invalidUTF8(reported)) {
        try library.importSheet(from: reported, preferences: .standard)
      }
      try Data(invalid).write(to: file)
      #expect(throws: SheetExchangeError.invalidUTF8(reported)) {
        try library.importSheet(from: reported, preferences: .standard)
      }
    }
    #expect(try files(library) == before)
    #expect(
      SheetExchangeError.invalidUTF8(package).localizedDescription
        == "“Bad.ganit” isn't UTF-8 text, so Ganit can't open it.")
  }

  /// A package imported into a library that already has its sheet becomes a
  /// second sheet with a new ID and the same bytes. Table identities are
  /// unique only within a sheet, so they are kept, and both sheets keep the
  /// manifest's presentation.
  @Test
  func importingAPackageTwiceMintsOnlyASheetID() throws {
    let fixture = try url("Table.ganit")
    try FileManager.default.copyItem(
      at: DocumentFormatFixtureTests.directory.appending(path: "Packages/Table.ganit"),
      to: fixture)
    let source = Data(TableSources.old.utf8)
    let origin = try SheetLibrary(root: try url("Origin"))
    let sheet = try origin.save(
      source: TableSources.old, metadata: origin.create(preferences: .standard))
    let exported = try url("Old.ganit")
    try origin.exportSheet(sheet.id, to: exported, quickLook: nil)
    let library = try SheetLibrary(root: try url("Library"))

    for package in [fixture, exported] {
      let bytes = try Data(contentsOf: package.appending(path: "source.txt"))
      let manifest = try #require(try SheetExchange.read(from: package).manifest)
      let first = try library.importSheet(from: package, preferences: .standard)
      let second = try library.importSheet(from: package, preferences: .standard)

      #expect(first.id == manifest.id && second.id != manifest.id)
      let blocks = TableSourceDocument(try #require(exactUTF8(bytes))).blocks
      #expect(!blocks.isEmpty)
      for imported in [first, second] {
        #expect(try storedBytes(of: imported.id, in: library) == bytes)
        let stored = try library.load(id: imported.id)
        #expect(TableSourceDocument(stored.source).blocks == blocks)
        #expect(stored.metadata.title == manifest.title)
        #expect(stored.metadata.hasCustomTitle == manifest.hasCustomTitle)
        #expect(stored.metadata.preferences == manifest.preferences)
        #expect(stored.metadata.createdAt == manifest.createdAt)
        #expect(stored.metadata.tables == manifest.tables)
      }
    }
    #expect(try storedBytes(of: sheet.id, in: library) == source)
  }

  /// A package whose source.txt was edited elsewhere imports that source as
  /// canonical, with a valid checksum. Its title, preferences and creation
  /// date come from the manifest, except that a title following the first
  /// line follows the new source, and presentation of tables the source no
  /// longer has is dropped.
  @Test(arguments: [false, true])
  func staleManifestKeepsTheSourceCanonical(customTitle: Bool) throws {
    let library = try SheetLibrary(root: try url("Library"))
    let preferences = SheetPreferences(
      localeIdentifier: "en-US", angleMode: .degrees, significantDecimalDigits: 12)
    var metadata = try library.create(preferences: preferences)
    metadata.tables.setWidth(120, column: Self.ratesColumn, table: Self.ratesTable)
    metadata.tables.setWidth(80, column: Self.itemsColumn, table: Self.itemsTable)
    var sheet = try library.save(source: TableSources.old, metadata: metadata)
    if customTitle {
      sheet = try library.rename(sheet.id, to: "Named")
    }
    #expect(sheet.tables.byTableID.count == 2)
    let package = try url("Stale.ganit")
    try library.exportSheet(sheet.id, to: package, quickLook: nil)
    let edited = "# Edited elsewhere\r\n" + Self.tableFirst + "rate * 3"
    try Data(edited.utf8).write(to: package.appending(path: "source.txt"))

    let exchanged = try SheetExchange.read(from: package)
    #expect(!exchanged.isChecksumValid)
    TableSources.expectIntact(exchanged.source, equals: edited)

    let other = try SheetLibrary(root: try url("Other"))
    let imported = try other.importSheet(from: package, preferences: .standard)

    let stored = try other.store.load(id: imported.id)
    #expect(stored.isChecksumValid)
    TableSources.expectIntact(stored.source, equals: edited)
    #expect(imported.id == sheet.id)
    #expect(imported.title == (customTitle ? "Named" : "Edited elsewhere"))
    #expect(imported.hasCustomTitle == customTitle)
    #expect(imported.preferences == preferences && imported.createdAt == sheet.createdAt)
    #expect(
      imported.tables
        == TablePresentations([
          Self.ratesTable: TablePresentation(columnWidths: [Self.ratesColumn: 120])
        ]))
    #expect(stored.metadata == imported)
  }

  /// A table-bearing source of exactly the limit imports, plain, marked and
  /// packaged, byte for byte. One byte more is refused, never truncated, and
  /// nothing is written; so is a manifest over its limit.
  @Test
  func sizeLimitsRefuseWithoutTruncating() throws {
    let limit = SheetExchange.maximumSourceBytes
    let base = TableSources.large(prose: "a")
    let padding = limit - base.utf8.count - 1
    #expect(padding > 0)
    let largest = base + String(repeating: "x", count: padding) + "\n"
    #expect(largest.utf8.count == limit)
    #expect(!TableSourceDocument(largest).diagnostics.contains { $0.code == .sourceLimit })
    #expect(TableSourceDocument(largest + "x").diagnostics.contains { $0.code == .sourceLimit })
    let library = try SheetLibrary(root: try url("Library"))

    let file = try url("Largest.txt")
    for input in [Data(largest.utf8), Self.byteOrderMark + Data(largest.utf8)] {
      try input.write(to: file)
      let imported = try library.importSheet(from: file, preferences: .standard)
      #expect(try storedBytes(of: imported.id, in: library) == Data(largest.utf8))
    }
    let sheet = try library.save(source: largest, metadata: library.create(preferences: .standard))
    let package = try url("Largest.ganit")
    try library.exportSheet(sheet.id, to: package, quickLook: nil)
    let other = try SheetLibrary(root: try url("Other"))
    let packaged = try other.importSheet(from: package, preferences: .standard)
    TableSources.expectIntact(try other.load(id: packaged.id).source, equals: largest)

    let before = try files(library)
    for input in [Data((largest + "x").utf8), Self.byteOrderMark + Data((largest + "x").utf8)] {
      try input.write(to: file)
      #expect(throws: SheetExchangeError.tooLarge(file)) {
        try library.importSheet(from: file, preferences: .standard)
      }
    }
    let source = package.appending(path: "source.txt")
    try Data((largest + "x").utf8).write(to: source)
    #expect(throws: SheetExchangeError.tooLarge(package)) {
      try library.importSheet(from: package, preferences: .standard)
    }
    try Data(largest.utf8).write(to: source)

    // JSON whitespace pads the manifest to its limit, then past it.
    let manifestURL = package.appending(path: "manifest.json")
    let manifest = try Data(contentsOf: manifestURL)
    let spaces = SheetExchange.maximumManifestBytes - manifest.count
    try (Data(repeating: 0x20, count: spaces + 1) + manifest).write(to: manifestURL)
    #expect(throws: SheetExchangeError.tooLarge(package)) {
      try library.importSheet(from: package, preferences: .standard)
    }
    #expect(try files(library) == before)
    try (Data(repeating: 0x20, count: spaces) + manifest).write(to: manifestURL)
    #expect(try SheetExchange.read(from: package).manifest?.id == sheet.id)
  }

  /// Standard input is read as import reads a file: one leading byte-order
  /// mark is removed, and the limit applies to the rest.
  @Test
  func importedSourceStripsOneMarkAndKeepsTheLimit() {
    let limit = SheetExchange.maximumSourceBytes
    let largest = Data(repeating: 0x31, count: limit)
    #expect(SheetExchange.importedSource(largest)?.utf8.count == limit)
    #expect(SheetExchange.importedSource(Self.byteOrderMark + largest)?.utf8.count == limit)
    #expect(SheetExchange.importedSource(largest + Data([0x31])) == nil)
    #expect(SheetExchange.importedSource(Self.byteOrderMark + largest + Data([0x31])) == nil)
    let twice = SheetExchange.importedSource(
      Self.byteOrderMark + Self.byteOrderMark + Data("1".utf8))
    #expect(twice.map { Array($0.utf8) } == Array("\u{FEFF}1".utf8))
    #expect(SheetExchange.importedSource(Data([0xC3, 0x28])) == nil)
    #expect(SheetExchange.importedSource(Data()) == "")
  }

  /// A file name ending in `.ganit` in any case is a package, written and
  /// read as one.
  @Test(arguments: ["Upper.GANIT", "Mixed.Ganit"])
  func packageExtensionsIgnoreCase(name: String) throws {
    let library = try SheetLibrary(root: try url("Library"))
    let sheet = try library.save(
      source: TableSources.old, metadata: library.create(preferences: .standard))
    let package = try url(name)

    try library.exportSheet(sheet.id, to: package, quickLook: nil)

    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: package.path))
        == ["manifest.json", "source.txt"])
    let exchanged = try SheetExchange.read(from: package)
    #expect(exchanged.manifest?.id == sheet.id && exchanged.isChecksumValid)
    TableSources.expectIntact(exchanged.source, equals: TableSources.old)
    let other = try SheetLibrary(root: try url("Other"))
    #expect(try other.importSheet(from: package, preferences: .standard).id == sheet.id)
  }

  /// A title following the first line ignores a leading U+FEFF, still
  /// recognizes a heading, and is cut between characters to 200 characters
  /// and 1,024 UTF-8 bytes, so a long first line never blocks package
  /// export. Saving, metadata recovery and stale-checksum repair agree.
  @Test(arguments: [
    ("\u{FEFF}# Budget\n1 + 1", "Budget"),
    ("\u{FEFF}\n\u{FEFF}  plain words  \n", "plain words"),
    (String(repeating: "word ", count: 14_000) + "\n2 + 2", String(repeating: "word ", count: 40)),
    ("# " + String(repeating: "👍🏽", count: 300), String(repeating: "👍🏽", count: 128)),
  ])
  func derivedTitlesSkipAMarkAndStayShort(source: String, title: String) throws {
    let expected = title.trimmingCharacters(in: .whitespaces)
    let file = try url("Long.txt")
    // Import removes the file's byte-order mark and keeps the source's own.
    try (Self.byteOrderMark + Data(source.utf8)).write(to: file)
    let library = try SheetLibrary(root: try url("Library"))

    let imported = try library.importSheet(from: file, preferences: .standard)

    #expect(imported.title == expected)
    #expect(imported.title.count <= 200 && imported.title.utf8.count <= 1_024)
    TableSources.expectIntact(try library.load(id: imported.id).source, equals: source)
    let package = try url("Long.ganit")
    try library.exportSheet(imported.id, to: package, quickLook: nil)
    #expect(try SheetExchange.read(from: package).manifest?.title == expected)

    // Stale-checksum repair and metadata recovery derive the same title.
    var stale = try library.store.load(id: imported.id).metadata
    stale.title = "Stale"
    try library.store.save(source: "other", metadata: stale)
    try Data(source.utf8).write(to: library.store.sourceURL(imported.id))
    let repaired = try library.load(id: imported.id)
    #expect(repaired.metadataRepair == .checksum && repaired.metadata.title == expected)
    try FileManager.default.removeItem(at: library.store.metadataURL(imported.id))
    let recovered = try library.load(id: imported.id)
    #expect(recovered.metadataRepair == .rebuiltFromSource && recovered.metadata.title == expected)
  }
}
