import Foundation
import Testing

@testable import GanitDocuments

/// Interruptions, corruption, and full or read-only storage never leave a
/// partial canonical sheet or lose content.
@Suite(.serialized)
struct StorageFaultTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitFaultTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let sources = ["a", "b"].map { String(repeating: "\($0) = 1 + 2\n", count: 100_000) }

  @Test
  func killedSavesLeaveOneCompleteVersionAndARecoverableLibrary() async throws {
    let id = try SheetLibrary(root: root).save(
      source: sources[0],
      metadata: SheetLibrary(root: root).create(preferences: .standard)
    ).id
    let helper = Bundle(for: HelperLocator.self).bundleURL
      .deletingLastPathComponent()
      .appending(path: "GanitStorageStressHelper")
    var generator = SystemRandomNumberGenerator()

    for _ in 0..<12 {
      let process = Process()
      process.executableURL = helper
      process.arguments = [root.path, id.uuidString]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      _ = output.fileHandleForReading.availableData
      try await Task.sleep(for: .milliseconds(Int.random(in: 5...250, using: &generator)))
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()

      let bytes = try Data(contentsOf: root.appending(path: "Sheets/\(id.uuidString).txt"))
      #expect(sources.contains { Data($0.utf8) == bytes }, "partial source of \(bytes.count) bytes")

      let library = try SheetLibrary(root: root)
      let sheet = try library.store.load(id: id)
      #expect(sheet.isChecksumValid)
      #expect(sources.contains(sheet.source))
      #expect(try library.store.sheetIDs() == [id])
      let marker = sheet.source.hasPrefix("a") ? "a = 1" : "b = 1"
      #expect(try library.index.search(marker) == [id])
    }
  }

  @Test
  func recoversSheetsWithCorruptOrMissingMetadataFromTheirSource() throws {
    var library: SheetLibrary? = try SheetLibrary(root: root)
    let corrupt = try library!.save(
      source: "# Corrupt\n1", metadata: library!.create(preferences: .standard))
    let missing = try library!.save(
      source: "# Missing\n2", metadata: library!.create(preferences: .standard))
    library = nil
    try Data("{\"schemaVersion\": 1, \"id\":".utf8).write(
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

  @Test
  func fullDisksRejectSavesAndKeepThePreviousVersion() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let image = root.appending(path: "Full.dmg")
    let mount = root.appending(path: "Volume", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try hdiutil(["create", "-size", "8m", "-fs", "HFS+", "-volname", "GanitFull", image.path])
    try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path])
    defer { try? hdiutil(["detach", mount.path, "-force"]) }

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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments + ["-quiet"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CocoaError(.executableLoad)
    }
  }
}

/// Locates the test bundle, beside which SwiftPM builds the stress helper.
private final class HelperLocator {}
