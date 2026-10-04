import CryptoKit
import Foundation
import Testing

@testable import GanitDocuments
@testable import GanitEngine

/// Frozen corruption drills: a library whose table-bearing sheets have
/// missing, truncated, garbage, invalid, stale, and misdirected metadata, an
/// orphaned metadata file, unsupported schemas, source that is not UTF-8,
/// and a corrupt index. Each drill opens a copy, by full recovery and by
/// loading one sheet at a time, and checks that only metadata is rewritten,
/// from the canonical source alone.
///
/// The fixtures are inputs rather than a format, but
/// `DocumentFormatFixtureTests.fixturesAreFrozen` checks them with the
/// format fixtures so a drill cannot silently weaken.
@Suite(.timeLimit(.minutes(5)))
final class CorruptionDrillTests {
  static let checksums = [
    "CorruptionDrill/Backups/2026-09-15/Metadata/C0DE0000-0000-4000-8000-000000000006.json":
      "a067ea724566c95cdb13c1a6b56acbf7997e8236f7a2beb362f7c017c92d18b8",
    "CorruptionDrill/Backups/2026-09-15/Sheets/C0DE0000-0000-4000-8000-000000000006.txt":
      "f4d2bc869bd06df9f5ca80db901d450203874a688b8e86a283c28267bde7309a",
    "CorruptionDrill/Index/index.sqlite":
      "899671ecf0aa8f3d158e933242b84fc97cb75c653bdafae1f6bbc27a52596732",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000001.json":
      "59e4334021dec3b580c0c94c9ccfe7f1da93bc1e2203a1a1b9f4d153026bbb00",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000003.json":
      "b5e37658250e4f64f951f33a0a6261335ed6b64a3603d47fe424698cd6ad8ef9",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000004.json":
      "c4333455c780461b1ebef5cb7b3f74d20c0bc2ea3ebe551b9e96cc9160215101",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000005.json":
      "06b3cefbf3514ea686b3bc77827f076d92507e8eab23f97d9f41d74d2134db92",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000006.json":
      "a067ea724566c95cdb13c1a6b56acbf7997e8236f7a2beb362f7c017c92d18b8",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000007.json":
      "59e4334021dec3b580c0c94c9ccfe7f1da93bc1e2203a1a1b9f4d153026bbb00",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000008.json":
      "7e95227c5fbfb6e2414bc244db42d8cbf75c8ada3088e654bc04cc2efca21130",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-000000000009.json":
      "bfd902be1b7e8629f28282f2ef1b87863c96c5c80eb0d4992b64f235caae5fd7",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-00000000000A.json":
      "fb946236f3a591ee97b6121a7bfeb44687f31224d7d23e5776cfff86bf2789c4",
    "CorruptionDrill/Metadata/C0DE0000-0000-4000-8000-00000000000B.json":
      "ba8fb6e40a08c551dafbe45e8caa716756b65e2e0f5a9c1038d99b4135f6443a",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000001.txt":
      "ffec909ebf7800f3613c9fc881fa90241218e5a1a86204aba59274ef1b2e6588",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000002.txt":
      "426a26acda4fa116e8afc0740419cc5c2007a7ebf129b54acec8dbf3d0dcdb4d",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000003.txt":
      "1cf1975e2a6ae26bacf24b80f24b30507568447515bef31e54268fa2556dfd7c",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000004.txt":
      "78fb8ecc9a0f00d4cc312804c9598c0948797ffea84d97742186036348f9d284",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000005.txt":
      "04109ffd1074b7cd37b1156fd2a985de7960ee542d059e366dfaac3bb2b50cde",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000006.txt":
      "bc4d523a6dbdcadfdd42bd5f8d9eb687c2065f6a794174b98de70d53b9cd693e",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000007.txt":
      "97f206f7cebf908a2db8edd2157bc8c27edb25d83745f8416f4a6a6a3199011d",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-000000000009.txt":
      "425364c4e84d832956226c915dd6c9b20f6583fe45acc1dbb82304fe4683acd0",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-00000000000A.txt":
      "c371c38470c9e33cc8c472be9acf59fe45d939378419db321cdfbce165b27f3d",
    "CorruptionDrill/Sheets/C0DE0000-0000-4000-8000-00000000000B.txt":
      "a9b21f7a1986bf99e7f308f085b8166d4d532e48126d46a08a523d0bd53d1f24",
  ]

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "C0DE0000-0000-4000-8000-%012X", number))!
  }

  /// Valid metadata and a table, untouched by every drill.
  static let healthy = id(1)
  /// Source with no metadata file. The source has no final line break.
  static let missing = id(2)
  /// Metadata cut off partway; a table block is the sheet's first line.
  static let truncated = id(3)
  /// Metadata that is not JSON; CRLF source.
  static let garbage = id(4)
  /// Metadata whose `tables` holds a width below the minimum.
  static let invalidTables = id(5)
  /// Valid metadata for the source before a table cell and a prose line were
  /// edited; the day's backup holds that older source.
  static let stale = id(6)
  /// A byte-for-byte copy of `healthy`'s metadata, naming that sheet.
  static let copied = id(7)
  /// Metadata with no source file.
  static let orphan = id(8)
  static let schema1 = id(9)
  static let schema3 = id(10)
  /// Source that is not UTF-8, beside metadata that cannot be decoded.
  static let notUTF8 = id(11)

  /// Sheets whose metadata is quarantined and rebuilt, with their titles.
  static let rebuilt: [UUID: String] = [
    missing: "Missing metadata drill",
    // Titles follow the first non-blank line; a table block counts as its
    // table's name, never its opener or payload.
    truncated: "Rates",
    garbage: "Garbage metadata drill",
    invalidTables: "Invalid tables drill",
    copied: "Copied metadata drill",
  ]
  static let quarantined = [truncated, garbage, invalidTables, copied]
  static let tableSheets = Array(rebuilt.keys) + [stale]
  static let listed = Set(tableSheets + [healthy, schema1])
  static let unreadable = [schema3, notUTF8]
  static let now = Date(timeIntervalSince1970: 1_790_000_000)
  static let backupDay = "2026-09-15"

  static let directory = DocumentFormatFixtureTests.directory
    .appending(path: "CorruptionDrill", directoryHint: .isDirectory)

  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitCorruptionDrill-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: path))
  }

  static func sourcePath(_ id: UUID) -> String { "Sheets/\(id.uuidString).txt" }
  static func metadataPath(_ id: UUID) -> String { "Metadata/\(id.uuidString).json" }

  static func source(_ id: UUID) throws -> String {
    String(decoding: try data(sourcePath(id)), as: UTF8.self)
  }

  /// The drill library copied to a fresh directory.
  private func copyLibrary(_ name: String = "Library") throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let copy = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: Self.directory, to: copy)
    return copy
  }

  private func open(_ library: URL) throws -> SheetLibrary {
    try SheetLibrary(
      root: library, timeZone: TimeZone(identifier: "UTC")!, now: { Self.now })
  }

  /// A file's inode and modification time, which change if it is replaced.
  private struct FileIdentity: Equatable {
    let inode: Int
    let modified: Date
  }

  private func identities(of library: URL) throws -> [String: FileIdentity] {
    var identities: [String: FileIdentity] = [:]
    let sheets = library.appending(path: "Sheets")
    for name in try FileManager.default.contentsOfDirectory(atPath: sheets.path) {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: sheets.appending(path: name).path)
      identities[name] = FileIdentity(
        inode: try #require(attributes[.systemFileNumber] as? Int),
        modified: try #require(attributes[.modificationDate] as? Date))
    }
    return identities
  }

  // MARK: Drills

  /// Each table-bearing drill sheet holds two valid tables, one with deleted
  /// bindings spelled `#REF!`, a malformed block, a block of an unknown
  /// version, and an unterminated block running to the end of the sheet.
  @Test func drillSheetsHoldEveryTableState() throws {
    for id in Self.tableSheets {
      let source = try Self.source(id)
      let document = TableSourceDocument(source)
      #expect(document.blocks.count == 5, "\(id)")
      let tables = document.blocks.compactMap(\.table)
      #expect(tables.map(\.name) == ["Rates", "Items"], "\(id)")
      let bindings = tables.flatMap(\.ledger).flatMap(\.bindings)
      #expect(bindings.filter(\.isDeleted).count == 2, "\(id)")
      #expect(source.contains("#REF!{range:20000000-0000-4000-8000-000000000037}"))
      #expect(
        document.diagnostics.map(\.code) == [.malformed, .unsupportedVersion, .unterminated])
      #expect(document.blocks.map(\.version) == [1, 1, 1, 2, 1])
      #expect(document.blocks.last?.physicalLines.upperBound == document.lines.count)
    }
    #expect(try Self.source(Self.garbage).contains("\r\n"))
    #expect(try !Self.source(Self.missing).hasSuffix("\n"))
    #expect(try Self.source(Self.truncated).hasPrefix("@ganit-table 1\n"))
    let backup = try Self.data("Backups/\(Self.backupDay)/\(Self.sourcePath(Self.stale))")
    #expect(try backup != Self.data(Self.sourcePath(Self.stale)))
    #expect(
      try Self.data(Self.metadataPath(Self.copied)) == Self.data(Self.metadataPath(Self.healthy)))
  }

  /// Opening the library, whose index is corrupt, recovers every sheet whose
  /// metadata can be rebuilt from its source and leaves the rest untouched.
  @Test func fullRecoveryRebuildsMetadataFromSourceAlone() throws {
    let copy = try copyLibrary()
    let before = try identities(of: copy)

    let library = try open(copy)

    #expect(library.unreadableSheetIDs == Self.unreadable)
    #expect(Set(try library.index.summaries().map(\.id)) == Self.listed)
    #expect(try library.index.sheet(titled: "Healthy control") == Self.healthy)
    try expectRecovered(library, at: copy, sourcesBefore: before)

    // Recovery is idempotent: running it again rewrites nothing.
    let metadata = try metadataFiles(in: copy)
    let report = try open(copy).recoverAndRebuildIndex()
    #expect(report.unreadable == Self.unreadable && report.indexedCount == Self.listed.count)
    #expect(try metadataFiles(in: copy) == metadata)
    #expect(try identities(of: copy) == before)
  }

  /// Loading a sheet for use repairs its metadata on demand, even when the
  /// index is healthy and nothing marks the library unsynchronized, through
  /// the same path as full recovery and with the same result.
  @Test func loadingASheetRepairsItsMetadataOnDemand() throws {
    let copy = try copyLibrary()
    try installHealthyIndex(in: copy)
    let before = try identities(of: copy)
    let library = try open(copy)
    // Nothing ran yet: the corrupt files are still in place.
    #expect(library.unreadableSheetIDs.isEmpty)
    #expect(try metadataFiles(in: copy).keys.count == 10)
    #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "Quarantine").path))

    for (id, _) in Self.rebuilt {
      #expect(try library.load(id: id).metadataRepair == .rebuiltFromSource, "\(id)")
    }
    #expect(try library.load(id: Self.stale).metadataRepair == .checksum)
    #expect(try library.load(id: Self.healthy).metadataRepair == nil)
    #expect(throws: CocoaError.self) { try library.load(id: Self.orphan) }
    #expect(try library.load(id: Self.schema1).metadata.schemaVersion == 2)
    #expect(throws: DocumentStorageError.unsupportedSchemaVersion(3)) {
      try library.load(id: Self.schema3)
    }
    #expect(
      throws: DocumentStorageError.invalidUTF8(
        library.store.sourceURL(Self.notUTF8))
    ) {
      try library.load(id: Self.notUTF8)
    }
    // A repaired sheet loads again without another repair.
    for id in Self.listed {
      #expect(try library.load(id: id).metadataRepair == nil, "\(id)")
    }
    #expect(
      !FileManager.default.fileExists(atPath: copy.appending(path: "Index/unsynchronized").path))

    try expectRecovered(library, at: copy, sourcesBefore: before)

    // Full recovery of another copy writes the same metadata.
    let other = try copyLibrary("FullRecovery")
    _ = try open(other)
    #expect(try metadataFiles(in: copy) == metadataFiles(in: other))
  }

  /// Organizing and exporting a sheet load it for use, so they repair it too.
  @Test func organizingAndExportingRepairOnDemand() throws {
    let copy = try copyLibrary()
    try installHealthyIndex(in: copy)
    let library = try open(copy)

    let renamed = try library.rename(Self.missing, to: "Named")
    #expect(renamed.title == "Named" && renamed.hasCustomTitle)
    let favorite = try library.update(Self.garbage) { $0.isFavorite = true }
    #expect(favorite.isFavorite && favorite.title == "Garbage metadata drill")
    let duplicate = try library.duplicate(Self.copied)
    let duplicateSource = try library.store.load(id: duplicate.id).source
    let originalDocument = TableSourceDocument(try Self.source(Self.copied))
    let duplicateDocument = TableSourceDocument(duplicateSource)
    #expect(duplicateDocument.blocks.count == originalDocument.blocks.count)
    for (original, copy) in zip(originalDocument.blocks, duplicateDocument.blocks) {
      if let table = original.table {
        let copiedTable = try #require(copy.table)
        #expect(copiedTable.id != table.id && copiedTable.name == table.name)
      } else {
        #expect(Array(copy.rawSource.utf8) == Array(original.rawSource.utf8))
      }
    }
    // Duplication remints valid tables; recovery leaves the original intact.
    #expect(try library.store.load(id: Self.copied).source == Self.source(Self.copied))
    let package = root.appending(path: "Truncated.ganit")
    try library.exportSheet(Self.truncated, to: package, quickLook: nil)
    let exported = try SheetExchange.read(from: package)
    let truncatedSource = try Self.source(Self.truncated)
    #expect(exported.isChecksumValid && exported.source == truncatedSource)
    #expect(
      try Data(contentsOf: copy.appending(path: Self.sourcePath(Self.healthy)))
        == Self.data(Self.sourcePath(Self.healthy)))
    #expect(try quarantine(in: copy).count == 3)
  }

  /// A stale checksum is repaired by rewriting only the checksum: the source
  /// file is not replaced, every other metadata field is kept, and neither
  /// the backup's older source nor the index's cached copy is substituted.
  @Test(arguments: [false, true])
  func aStaleChecksumRewritesOnlyMetadata(onDemand: Bool) throws {
    let copy = try copyLibrary()
    if onDemand {
      try installHealthyIndex(in: copy)
    }
    let before = try identities(of: copy)
    let library = try open(copy)
    let sheet = try library.load(id: Self.stale)

    let canonical = try Self.source(Self.stale)
    #expect(sheet.source.utf8.elementsEqual(canonical.utf8) && sheet.isChecksumValid)
    #expect(try identities(of: copy) == before)
    let fixture = String(decoding: try Self.data(Self.metadataPath(Self.stale)), as: UTF8.self)
    let staleChecksum =
      "sha256:" + hex(try Self.data("Backups/\(Self.backupDay)/\(Self.sourcePath(Self.stale))"))
    #expect(fixture.contains(staleChecksum))
    let expected = fixture.replacingOccurrences(
      of: staleChecksum, with: "sha256:" + hex(Data(canonical.utf8)))
    #expect(
      try Data(contentsOf: copy.appending(path: Self.metadataPath(Self.stale)))
        == Data(expected.utf8))
    #expect(sheet.metadata.title == "Stale rates" && sheet.metadata.hasCustomTitle)
    #expect(sheet.metadata.state == .archived && sheet.metadata.isFavorite)
    #expect(sheet.metadata.tables.byTableID.count == 1)
    // Table content lives only in the source: the edited cell is projected
    // from it, and metadata never held either version of the cell.
    let rates = try #require(TableSourceDocument(sheet.source).blocks[0].table)
    #expect(rates.cells.map(\.source).contains("84.10"))
    #expect(!rates.cells.map(\.source).contains("83.25"))
    #expect(!expected.contains("83.25") && !expected.contains("84.10"))
    #expect(try library.index.search("subtotal = 6").contains(Self.stale))
    #expect(try !library.index.search("subtotal = 5").contains(Self.stale))
    #expect(
      try library.load(SheetBackup(sheetID: Self.stale, day: Self.backupDay)).source
        == String(
          decoding: Self.data("Backups/\(Self.backupDay)/\(Self.sourcePath(Self.stale))"),
          as: UTF8.self))
  }

  /// Recovery does not change how a sheet calculates: every table block line
  /// stays quarantined, with no answer, declaration, assistant prompt, or
  /// aggregate membership, in regular and Markdown sheets alike.
  @Test(arguments: [false, true])
  func recoveredSheetsKeepTablesOutOfOrdinaryCalculation(markdown: Bool) throws {
    let library = try open(try copyLibrary())
    var preferences = SheetPreferences.standard
    preferences.display.writesAnswersInline = markdown
    let context = try preferences.evaluationContext(now: Self.now)
    var control = SheetCalculator()
    let prompt = try control.evaluate(SheetSource("ask_assistant(hello)"), context: context)
    #expect(!prompt.lines[0].assistantPrompts.isEmpty)

    for id in Self.tableSheets {
      let sheet = try library.load(id: id)
      var calculator = SheetCalculator()
      let evaluation = try calculator.evaluate(SheetSource(sheet.source), context: context)
      var fixture = SheetCalculator()
      let expected = try fixture.evaluate(SheetSource(Self.source(id)), context: context)
      #expect(evaluation.lines.map(\.result) == expected.lines.map(\.result), "\(id)")
      #expect(evaluation.tableDiagnostics == expected.tableDiagnostics)
      #expect(
        evaluation.tableDiagnostics.map(\.code) == [.malformed, .unsupportedVersion, .unterminated])

      let document = TableSourceDocument(sheet.source)
      for block in document.blocks {
        for line in block.physicalLines {
          let result = evaluation.lines[line]
          #expect(result.result == nil, "\(id) line \(line)")
          #expect(result.declaredVariableName == nil && result.assistantPrompts.isEmpty)
        }
      }
      // `x = 999` and `x = 5` inside blocks declare nothing, and the block
      // lines join no aggregate: each `total` sums only the lines since the
      // block before it.
      #expect(evaluation.definitions.variables["x"] == (try value("10", context)))
      let lines = document.lines.map(\.text)
      let totals = lines.indices.filter { lines[$0] == "total" }
      let answered = totals.filter { evaluation.lines[$0].result != nil }
      #expect(answered.count == 2, "\(id)")
      #expect(evaluation.lines[answered[0]].result == .value(try value("12", context)))
      #expect(evaluation.lines[answered[1]].result == .value(try value("10", context)))
    }
  }

  // MARK: Expectations

  private func expectRecovered(
    _ library: SheetLibrary, at copy: URL, sourcesBefore: [String: FileIdentity],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) throws {
    // No source file was written, created, or removed.
    #expect(try identities(of: copy) == sourcesBefore, sourceLocation: sourceLocation)
    for (path, _) in Self.checksums where path.contains("/Sheets/") || path.contains("Backups/") {
      let relative = String(path.dropFirst("CorruptionDrill/".count))
      #expect(
        try Data(contentsOf: copy.appending(path: relative))
          == DocumentFormatFixtureTests.data(path),
        "\(relative)", sourceLocation: sourceLocation)
    }
    #expect(try library.store.load(id: Self.schema1).metadata.schemaVersion == 2)
    #expect(
      try Data(
        contentsOf: copy.appending(
          path: "MigrationBackups/schema-1/\(Self.metadataPath(Self.schema1))"))
        == Self.data(Self.metadataPath(Self.schema1)))
    // Metadata Ganit cannot or need not rebuild is untouched; the orphan
    // creates no sheet.
    for id in [Self.healthy, Self.orphan] + Self.unreadable {
      #expect(
        try Data(contentsOf: copy.appending(path: Self.metadataPath(id)))
          == Self.data(Self.metadataPath(id)), "\(id)", sourceLocation: sourceLocation)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: copy.appending(path: Self.sourcePath(Self.orphan)).path))

    // Rebuilt metadata is schema 2 with reset fields and a valid checksum.
    for (id, title) in Self.rebuilt {
      let sheet = try library.store.load(id: id)
      let metadata = sheet.metadata
      #expect(sheet.isChecksumValid, "\(id)", sourceLocation: sourceLocation)
      #expect(metadata.schemaVersion == 2 && metadata.id == id, sourceLocation: sourceLocation)
      #expect(metadata.title == title && !metadata.hasCustomTitle, sourceLocation: sourceLocation)
      #expect(metadata.folderID == nil && !metadata.isFavorite && metadata.state == .active)
      #expect(metadata.preferences == .standard && metadata.tables == TablePresentations())
      #expect(metadata.createdAt == Self.now && metadata.modifiedAt == Self.now)
      #expect(
        metadata.sourceChecksum == "sha256:" + hex(try Self.data(Self.sourcePath(id))),
        sourceLocation: sourceLocation)
      #expect(
        try SheetStore.encoder.encode(metadata)
          == Data(contentsOf: copy.appending(path: Self.metadataPath(id))))
    }
    #expect(try library.store.load(id: Self.stale).isChecksumValid)

    // Every table-bearing sheet keeps its blocks byte for byte: identities,
    // bindings, broken markers, and the malformed, unknown, and
    // unterminated blocks.
    for id in Self.tableSheets {
      let recovered = try library.store.load(id: id).source
      let fixture = try Self.source(id)
      #expect(recovered.utf8.elementsEqual(fixture.utf8), sourceLocation: sourceLocation)
      #expect(
        TableSourceDocument(recovered).blocks == TableSourceDocument(fixture).blocks,
        sourceLocation: sourceLocation)
    }

    // Bad metadata is kept byte for byte in quarantine, once per sheet.
    let quarantined = try quarantine(in: copy)
    #expect(quarantined.count == Self.quarantined.count, sourceLocation: sourceLocation)
    for id in Self.quarantined {
      let names = quarantined.filter { $0.hasPrefix(id.uuidString + "-") }
      #expect(names.count == 1, "\(id)", sourceLocation: sourceLocation)
      for name in names {
        #expect(
          try Data(contentsOf: copy.appending(path: "Quarantine/\(name)"))
            == Self.data(Self.metadataPath(id)), sourceLocation: sourceLocation)
      }
    }

    // The index lists and finds the recovered sheets by title and source.
    let summaries = Dictionary(
      uniqueKeysWithValues: try library.index.summaries().map { ($0.id, $0) })
    for (id, title) in Self.rebuilt {
      #expect(summaries[id]?.title == title, sourceLocation: sourceLocation)
    }
    #expect(summaries[Self.stale]?.title == "Stale rates")
    #expect(try library.index.search("Missing metadata drill") == [Self.missing])
    #expect(try library.index.search("@ganit-table 2").count == Self.tableSheets.count)
    #expect(Set(try library.index.search("Items[Amount]")) == Set(Self.tableSheets))
    #expect(try library.index.sheet(titled: "Copied metadata drill") == Self.copied)
  }

  /// Replaces the corrupt index with a healthy one listing the sheets as they
  /// were before their metadata was damaged, so opening runs no recovery.
  /// Its copy of the stale sheet's source is the older, cached version.
  private func installHealthyIndex(in copy: URL) throws {
    // Finish migration first so these tests isolate on-demand recovery.
    try DocumentMigration.migrateLibrary(at: copy)
    try? FileManager.default.removeItem(at: copy.appending(path: "Index/unsynchronized"))
    let url = copy.appending(path: "Index/index.sqlite")
    try FileManager.default.removeItem(at: url)
    let index = try SheetIndex(url: url)
    for id in Self.listed {
      let source =
        id == Self.stale
        ? String(
          decoding: try Self.data("Backups/\(Self.backupDay)/\(Self.sourcePath(id))"),
          as: UTF8.self)
        : try Self.source(id)
      try index.upsert(
        SheetMetadata(
          id: id, title: "Before corruption", createdAt: Date(timeIntervalSince1970: 0),
          preferences: .standard),
        source: source)
    }
  }

  private func metadataFiles(in copy: URL) throws -> [String: Data] {
    let directory = copy.appending(path: "Metadata")
    var files: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      files[name] = try Data(contentsOf: directory.appending(path: name))
    }
    return files
  }

  private func quarantine(in copy: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: copy.appending(path: "Quarantine").path)
      .sorted()
  }

  private func value(_ text: String, _ context: EvaluationContext) throws -> EngineValue {
    var calculator = SheetCalculator()
    guard
      case .value(let value) = try calculator.evaluate(SheetSource(text), context: context)
        .lines[0].result
    else {
      throw CocoaError(.featureUnsupported)
    }
    return value
  }

  private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
