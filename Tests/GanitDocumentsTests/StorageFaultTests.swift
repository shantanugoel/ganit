import Foundation
import Testing

@_spi(StorageFaults) @testable import GanitDocuments
@testable import GanitEngine

/// Interruptions, corruption, and full or read-only storage never leave a
/// partial canonical sheet or lose content.
///
/// Child processes are only waited on with a deadline, and each test has a
/// time limit, so a stuck helper fails the test instead of hanging the run.
@Suite(.serialized, .timeLimit(.minutes(5)))
final class StorageFaultTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitFaultTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
  /// Two table-bearing sources of about 1 MB each, under the source limit.
  private static let sources = ["a", "b"].map { TableSources.large(prose: $0) }
  private static let helper = Bundle(for: HelperLocator.self).bundleURL
    .deletingLastPathComponent()
    .appending(path: "GanitStorageStressHelper")

  @Test
  func largeTableSourcesStayWithinTheSourceAndCellLimits() {
    for source in Self.sources {
      #expect(source.utf8.count > 900_000)
      #expect(source.utf8.count <= SheetExchange.maximumSourceBytes)
      let document = TableSourceDocument(source)
      #expect(document.diagnostics.isEmpty)
      #expect(document.blocks.compactMap(\.table).count == 200)
      let cells = document.blocks.compactMap(\.table).map(\.cells.count).reduce(0, +)
      #expect(cells < TableSourceDocument.maximumPopulatedCells)
    }
  }

  @Test
  func killedSavesLeaveOneCompleteVersionAndARecoverableLibrary() throws {
    let files = try writeSources()
    let id = try SheetLibrary(root: root).save(
      source: Self.sources[0],
      metadata: SheetLibrary(root: root).create(preferences: .standard)
    ).id

    try killRepeatedly(["save-loop", root.path, id.uuidString] + files) {
      let bytes = try Data(contentsOf: root.appending(path: "Sheets/\(id.uuidString).txt"))
      #expect(
        Self.sources.contains { Data($0.utf8) == bytes }, "partial source of \(bytes.count) bytes")

      let library = try SheetLibrary(root: root)
      let sheet = try library.store.load(id: id)
      #expect(sheet.isChecksumValid)
      #expect(Self.sources.contains(sheet.source))
      #expect(TableSourceDocument(sheet.source).diagnostics.isEmpty)
      #expect(try library.store.sheetIDs() == [id])
      #expect(WriteFaults.temporaryNames(under: root.appending(path: "Sheets")).isEmpty)
      #expect(WriteFaults.temporaryNames(under: root.appending(path: "Metadata")).isEmpty)
      let marker = sheet.source.contains("a = 1") ? "a = 1" : "b = 1"
      #expect(try library.index.search(marker) == [id])
    }
  }

  @Test
  func killedPackageExportsLeaveTheOldOrTheNewPackage() throws {
    let files = try writeSources()
    let package = root.appending(path: "Export.ganit")
    try SheetExchange.write(
      source: Self.sources[0],
      metadata: SheetMetadata(title: "", createdAt: Date(), preferences: .standard),
      to: package, quickLook: nil)

    try killRepeatedly(["export-loop", package.path] + files) {
      let exchanged = try SheetExchange.read(from: package)
      #expect(exchanged.isChecksumValid)
      #expect(Self.sources.contains(exchanged.source))
      #expect(TableSourceDocument(exchanged.source).diagnostics.isEmpty)
      #expect(
        Set(try FileManager.default.contentsOfDirectory(atPath: package.path))
          == ["manifest.json", "source.txt"])
    }
  }

  /// Kills a save at each of its write points in turn, including the backup
  /// it takes first, with no chance to clean up.
  @Test
  func savesKilledAtEveryWritePointKeepOneCompleteVersion() throws {
    // Saved two days ago, so the killed save backs the sheet up first.
    let template = root.appending(path: "Template", directoryHint: .isDirectory)
    let earlier = Date() - 2 * 86_400
    let id = try {
      let library = try SheetLibrary(root: template, now: { earlier })
      return try library.save(
        source: TableSources.old, metadata: library.create(preferences: .standard)
      ).id
    }()
    let newSource = root.appending(path: "new.txt")
    try Data(TableSources.new.utf8).write(to: newSource)
    let recording = root.appending(path: "Recording", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: template, to: recording)
    let points = try WriteFaults.record(in: recording) {
      let library = try SheetLibrary(root: recording)
      try library.save(source: TableSources.new, metadata: library.store.load(id: id).metadata)
    }
    #expect(points.count == 21)

    for hit in 1...points.count + 1 {
      let directory = root.appending(path: "Kill-\(hit)", directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: template, to: directory)
      let output = try runHelper([
        "crash-save", directory.path, id.uuidString, newSource.path, "\(hit)",
      ])
      guard hit <= points.count else {
        #expect(output == "completed \(points.count)\n")
        continue
      }
      let reached = points[..<hit]
      let point = "\(reached.last!)"
      #expect(output == "killed", "\(point)")
      let replaced = reached.contains(
        ReachedPoint(point: .renamed, path: "Sheets/\(id.uuidString).txt"))
      let expected = replaced ? TableSources.new : TableSources.old
      let store = SheetStore(root: directory)
      TableSources.expectIntact(
        String(decoding: try Data(contentsOf: store.sourceURL(id)), as: UTF8.self),
        equals: expected, "\(point)")
      // A kill while a sheet file's temporary sibling exists abandons it.
      let last = reached.last!
      let abandoned =
        [.temporaryCreated, .temporaryWritten, .temporaryFlushed].contains(last.point)
        && !last.path.hasPrefix("Backups/")
      let temporaries = ["Sheets", "Metadata"].flatMap {
        WriteFaults.temporaryNames(under: directory.appending(path: $0))
      }
      #expect(temporaries.count == (abandoned ? 1 : 0), "\(point)")
      // The marker is on disk from the index directory's synchronization on.
      let marked = reached.contains(ReachedPoint(point: .synchronizingDirectory, path: "Index"))
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appending(path: "Index/unsynchronized").path)
          == marked, "\(point)")

      // Reopening recovers stale metadata and removes abandoned temporary
      // files; the backup taken first holds the replaced version.
      let library = try SheetLibrary(root: directory)
      let sheet = try library.store.load(id: id)
      #expect(sheet.isChecksumValid, "\(point)")
      TableSources.expectIntact(sheet.source, equals: expected, "\(point)")
      #expect(try library.store.sheetIDs() == [id])
      #expect(WriteFaults.temporaryNames(under: directory.appending(path: "Sheets")).isEmpty)
      #expect(WriteFaults.temporaryNames(under: directory.appending(path: "Metadata")).isEmpty)
      #expect(try library.index.search(replaced ? "subtotal = 6" : "subtotal = 5") == [id])
      try library.save(source: TableSources.new, metadata: sheet.metadata)
      let backup = try library.load(try #require(library.backups(of: id).first))
      TableSources.expectIntact(backup.source, equals: TableSources.old, "\(point)")
    }
  }

  /// Kills a package export over an existing package at each of its write
  /// points in turn.
  @Test
  func packageExportsKilledAtEveryWritePointLeaveACompletePackage() throws {
    let template = root.appending(path: "Template", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let files = try [TableSources.old, TableSources.new].enumerated().map { index, source in
      let file = root.appending(path: "source-\(index).txt")
      try Data(source.utf8).write(to: file)
      return file.path
    }
    #expect(
      try runHelper(["crash-export", template.appending(path: "Export.ganit").path, files[0], "99"])
        == "completed \(WriteFaults.packageWrite("Export.ganit", replacing: false).count)\n")
    var references: [[String: Data]] = []
    for (index, file) in files.enumerated() {
      let package = root.appending(path: "Reference-\(index).ganit")
      _ = try runHelper(["crash-export", package.path, file, "99"])
      references.append(try #require(try WriteFaults.packageContents(package)))
    }
    let points = WriteFaults.packageWrite("Export.ganit", replacing: true)

    for hit in 1...points.count {
      let directory = root.appending(path: "Kill-\(hit)", directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: template, to: directory)
      let package = directory.appending(path: "Export.ganit")
      let point = "\(points[hit - 1])"
      #expect(try runHelper(["crash-export", package.path, files[1], "\(hit)"]) == "killed")

      let replaced = points[..<hit].contains(
        ReachedPoint(point: .packageReplaced, path: "Export.ganit"))
      #expect(
        try WriteFaults.packageContents(package) == references[replaced ? 1 : 0], "\(point)")
      TableSources.expectIntact(
        try SheetExchange.read(from: package).source,
        equals: replaced ? TableSources.new : TableSources.old, "\(point)")
      // A killed export leaves exactly one hidden temporary sibling: the
      // unfinished new package before the swap, holding only complete new
      // files besides its own temporary files, or the whole old package
      // after it. It never replaces the destination.
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0 != "Export.ganit" }
      #expect(leftovers.count == 1, "\(point)")
      let name = try #require(leftovers.first)
      #expect(AtomicFile.isWriterTemporary(name), "\(point)")
      let sibling = try #require(try WriteFaults.packageContents(directory.appending(path: name)))
      if replaced {
        #expect(sibling == references[0], "\(point)")
      } else {
        let complete = sibling.filter {
          !AtomicFile.isTemporary(URL(fileURLWithPath: $0.key).lastPathComponent)
        }
        #expect(complete.allSatisfy { references[1][$0.key] == $0.value }, "\(point)")
      }
    }
  }

  /// Writes `sources` to files the helper reads, returning their paths.
  private func writeSources() throws -> [String] {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try Self.sources.enumerated().map { index, source in
      let file = root.appending(path: "source-\(index).txt")
      try Data(source.utf8).write(to: file)
      return file.path
    }
  }

  /// Starts the helper with `arguments` twelve times, kills it with
  /// `SIGKILL` at a random moment after it is ready, and runs `check`.
  private func killRepeatedly(_ arguments: [String], check: () throws -> Void) throws {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<12 {
      let child = try ChildProcess(Self.helper, arguments)
      #expect(child.waitForOutput() == "ready\n")
      Thread.sleep(forTimeInterval: Double.random(in: 0.005...0.25, using: &generator))
      child.kill()
      guard child.waitForExit() else {
        return
      }
      // A helper that died on its own wrote nothing worth checking.
      #expect(child.wasKilled)
      try check()
    }
  }

  /// Runs the helper to completion, returning its output, or `killed` when
  /// it killed itself.
  private func runHelper(_ arguments: [String]) throws -> String {
    let child = try ChildProcess(Self.helper, arguments)
    guard child.waitForExit() else {
      return "timed out"
    }
    if child.wasKilled {
      return "killed"
    }
    #expect(child.terminationStatus == 0)
    return child.readOutput()
  }

  @Test
  func recoversSheetsWithCorruptOrMissingMetadataFromTheirSource() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let corrupt = try library!.save(
      source: "# Corrupt\n1", metadata: library!.create(preferences: .standard))
    let missing = try library!.save(
      source: "# Missing\n2", metadata: library!.create(preferences: .standard))
    library = nil
    try Data("{\"schemaVersion\": 2, \"id\":".utf8).write(
      to: root.appending(path: "Metadata/\(corrupt.id.uuidString).json"))
    try FileManager.default.removeItem(
      at: root.appending(path: "Metadata/\(missing.id.uuidString).json"))
    try FileManager.default.removeItem(at: root.appending(path: "Index"))

    let recovered = try SheetLibrary(root: root)

    #expect(Set(try recovered.index.summaries().map(\.title)) == ["Corrupt", "Missing"])
    #expect(try recovered.store.load(id: corrupt.id).source == "# Corrupt\n1")
    #expect(try recovered.store.load(id: missing.id).isChecksumValid)
    let quarantined = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Quarantine").path)
    #expect(quarantined.count == 1 && quarantined[0].hasPrefix(corrupt.id.uuidString))
  }

  @Test
  func reindexesChangesInterruptedBeforeTheIndexWasUpdated() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let sheet = try library!.save(
      source: "hotel = 85", metadata: library!.create(preferences: .standard))
    library = nil
    // Simulate a save that replaced files but stopped before updating the index.
    try SheetStore(root: root).save(source: "rent = 2100", metadata: sheet)
    FileManager.default.createFile(
      atPath: root.appending(path: "Index/unsynchronized").path, contents: nil)

    let reopened = try SheetLibrary(root: root)

    #expect(try reopened.index.search("2100") == [sheet.id])
    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: "Index/unsynchronized").path))
  }

  @Test
  func readOnlyLibrariesStillLoadAndRejectSavesWithoutPartialFiles() throws {
    let library = try SheetLibrary(root: root)
    let sheet = try library.save(source: "kept", metadata: library.create(preferences: .standard))
    let sheets = root.appending(path: "Sheets")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sheets.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sheets.path)
    }

    #expect(throws: (any Error).self) {
      try library.save(source: "lost?", metadata: sheet)
    }
    #expect(try library.store.load(id: sheet.id).source == "kept")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: sheets.path) == [
        "\(sheet.id.uuidString).txt"
      ])
  }

  /// Cleanup of abandoned temporary files is best effort: a library whose
  /// sheets directory is read-only still opens, recovers, and searches.
  @Test
  func readOnlyLibrariesWithAbandonedTemporaryFilesStillOpen() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let sheet = try library!.save(
      source: TableSources.old, metadata: library!.create(preferences: .standard))
    library = nil
    let sheets = root.appending(path: "Sheets")
    let abandoned = ".\(sheet.id.uuidString).txt.\(UUID().uuidString).tmp"
    try Data("partial".utf8).write(to: sheets.appending(path: abandoned))
    FileManager.default.createFile(
      atPath: root.appending(path: "Index/unsynchronized").path, contents: nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sheets.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sheets.path)
    }

    let reopened = try SheetLibrary(root: root)

    #expect(try reopened.index.search("subtotal = 5") == [sheet.id])
    TableSources.expectIntact(
      try reopened.store.load(id: sheet.id).source, equals: TableSources.old)
    #expect(try reopened.store.sheetIDs() == [sheet.id])
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: sheets.path))
        == ["\(sheet.id.uuidString).txt", abandoned])
  }

  /// Recovery removes only regular files named exactly as atomic writes name
  /// their temporary files, never names a person could have chosen.
  @Test
  func recoveryRemovesOnlyAtomicWriteTemporaryFiles() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let sheet = try library!.save(source: "kept", metadata: library!.create(preferences: .standard))
    library = nil
    let sheets = root.appending(path: "Sheets")
    let metadata = root.appending(path: "Metadata")
    let uuid = UUID().uuidString
    let abandoned = [
      sheets.appending(path: ".\(sheet.id.uuidString).txt.\(uuid).tmp"),
      metadata.appending(path: ".\(sheet.id.uuidString).json.\(UUID().uuidString).tmp"),
    ]
    let kept = [".tmp", "..tmp", ".notes.tmp", ".\(uuid).tmp", ".notes.\(uuid.lowercased()).tmp"]
      .map { sheets.appending(path: $0) }
    for file in abandoned + kept {
      try Data("x".utf8).write(to: file)
    }
    let keptDirectories = [".a.tmp", ".folder.\(uuid).tmp"].map { sheets.appending(path: $0) }
    for directory in keptDirectories {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    try SheetLibrary(root: root).recoverAndRebuildIndex()

    for file in abandoned {
      #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
    }
    for file in kept + keptDirectories {
      #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
    }
    #expect(try SheetStore(root: root).load(id: sheet.id).source == "kept")
  }

  @Test
  func fullDisksRejectSavesAndKeepThePreviousVersion() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let image = root.appending(path: "Full.dmg")
    let mount = root.appending(path: "Volume", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try hdiutil(["create", "-size", "8m", "-fs", "HFS+", "-volname", "GanitFull", image.path])
    // Registered first, so an attach that fails or times out partway is
    // still detached, best effort.
    defer { try? hdiutil(["detach", mount.path, "-force"]) }
    try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path])

    let libraryRoot = mount.appending(path: "Library", directoryHint: .isDirectory)
    let library = try SheetLibrary(root: libraryRoot)
    let sheet = try library.save(source: "small", metadata: library.create(preferences: .standard))
    let filler = mount.appending(path: "filler")
    FileManager.default.createFile(atPath: filler.path, contents: nil)
    let handle = try FileHandle(forWritingTo: filler)
    let chunk = Data(repeating: 0, count: 256 << 10)
    while (try? handle.write(contentsOf: chunk)) != nil {}
    try? handle.close()

    #expect(throws: (any Error).self) {
      try library.save(source: String(repeating: "x", count: 1 << 20), metadata: sheet)
    }
    #expect(try library.store.load(id: sheet.id).source == "small")
    #expect(try library.store.load(id: sheet.id).isChecksumValid)
    let sheets = libraryRoot.appending(path: "Sheets").path
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: sheets) == ["\(sheet.id.uuidString).txt"])
  }

  private func hdiutil(_ arguments: [String]) throws {
    let child = try ChildProcess(
      URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments + ["-quiet"], capturesOutput: false)
    guard child.waitForExit(), child.terminationStatus == 0 else {
      throw CocoaError(.executableLoad)
    }
  }
}

/// Locates the test bundle, beside which SwiftPM builds the stress helper.
private final class HelperLocator {}
