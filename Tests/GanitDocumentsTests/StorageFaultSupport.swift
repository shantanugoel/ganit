import Foundation
import Testing
import os

@_spi(StorageFaults) @testable import GanitDocuments
@testable import GanitEngine

/// A storage write point an operation reached, with its URL relative to the
/// directory the operation worked in and temporary names written as `*`.
struct ReachedPoint: Equatable, CustomStringConvertible {
  let point: StorageWritePoint
  let path: String

  var description: String { "\(point.rawValue) \(path)" }
}

/// Runs operations under a `StorageFaults` handler.
enum WriteFaults {
  struct Injected: Error {}

  /// Every point `operation` reaches, in order.
  static func record(in base: URL, _ operation: () throws -> Void) throws -> [ReachedPoint] {
    let reached = OSAllocatedUnfairLock<[ReachedPoint]>(initialState: [])
    try StorageFaults.$handler.withValue(
      { point, url in
        let path = relativePath(of: url, in: base)
        reached.withLock { $0.append(ReachedPoint(point: point, path: path)) }
      },
      operation: operation)
    return reached.withLock { $0 }
  }

  /// Runs `operation`, throwing `Injected` from the `hit`th point it reaches,
  /// counting from 1, and returns what `operation` threw.
  static func failing(atHit hit: Int, _ operation: () throws -> Void) -> (any Error)? {
    let reached = OSAllocatedUnfairLock(initialState: 0)
    return failing(
      when: { _, _ in
        reached.withLock {
          $0 += 1
          return $0 == hit
        }
      }, operation)
  }

  /// Runs `operation`, throwing `Injected` from every point for which
  /// `fails` is true, and returns what `operation` threw.
  static func failing(
    when fails: @escaping @Sendable (StorageWritePoint, URL) -> Bool,
    _ operation: () throws -> Void
  ) -> (any Error)? {
    do {
      try StorageFaults.$handler.withValue(
        { point, url in
          if fails(point, url) {
            throw Injected()
          }
        },
        operation: operation)
      return nil
    } catch {
      return error
    }
  }

  /// The points an atomic write of the file at `path` reaches.
  static func atomicWrite(_ path: String) -> [ReachedPoint] {
    let directory = path.split(separator: "/").dropLast().joined(separator: "/")
    return [.temporaryCreated, .temporaryWritten, .temporaryFlushed, .renamed]
      .map { ReachedPoint(point: $0, path: path) }
      + [ReachedPoint(point: .synchronizingDirectory, path: directory)]
  }

  /// The points writing the package `name`, with Quick Look files, reaches
  /// in the directory it is written to, replacing a package or not.
  static func packageWrite(_ name: String, replacing: Bool) -> [ReachedPoint] {
    [ReachedPoint(point: .packageDirectoryCreated, path: name)]
      + ["source.txt", "manifest.json", "QuickLook/Preview.pdf", "QuickLook/Thumbnail.png"]
      .flatMap { atomicWrite("*/\($0)") }
      + [
        ReachedPoint(point: .packageAssembled, path: name),
        ReachedPoint(point: .packageReplaced, path: name),
        ReachedPoint(point: .synchronizingDirectory, path: ""),
      ]
      + (replacing ? [ReachedPoint(point: .removingReplacedPackage, path: name)] : [])
  }

  /// Every file in a package by relative path, or `nil` when there is none.
  static func packageContents(_ url: URL) throws -> [String: Data]? {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    var contents: [String: Data] = [:]
    for case let path as String in FileManager.default.enumerator(atPath: url.path)! {
      var isDirectory: ObjCBool = false
      let file = url.appending(path: path)
      if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        contents[path] = try Data(contentsOf: file)
      }
    }
    return contents
  }

  static func relativePath(of url: URL, in base: URL) -> String {
    let components = url.standardizedFileURL.pathComponents
    let baseComponents = base.standardizedFileURL.pathComponents
    precondition(components.starts(with: baseComponents), "\(url.path) is outside \(base.path)")
    return components.dropFirst(baseComponents.count)
      .map { AtomicFile.isTemporary($0) ? "*" : $0 }
      .joined(separator: "/")
  }

  /// Hidden temporary names anywhere under `directory`.
  static func temporaryNames(under directory: URL) -> [String] {
    let names = FileManager.default.enumerator(atPath: directory.path)?.allObjects ?? []
    return names.compactMap { $0 as? String }
      .filter { AtomicFile.isTemporary(URL(fileURLWithPath: $0).lastPathComponent) }
  }
}

/// Table-bearing sources built from the engine's frozen table block fixtures.
enum TableSources {
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "GanitEngineTests/Fixtures/TableBlocks", directoryHint: .isDirectory)

  static func fixture(_ name: String) -> String {
    // The fixtures are checked in; a missing one is a broken checkout.
    try! String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
  }

  /// Two valid tables, one of them with deleted bindings spelled as `#REF!`
  /// markers, prose that names them, and a malformed block.
  static let old =
    fixture("valid-two-tables.txt")
    + "lost = 1 // Items[Amount] lost a row: #REF!\n"
    + fixture("malformed-json.txt")

  /// `old` with a prose line and a table cell edited.
  static let new =
    old
    .replacingOccurrences(of: "subtotal = 5", with: "subtotal = 6")
    .replacingOccurrences(of: "\"83.25\"", with: "\"84.10\"")

  /// Expects `text` to be `expected` byte for byte, with the same table
  /// blocks, projections, bindings, and diagnostics.
  static func expectIntact(
    _ text: String, equals expected: String, _ comment: Comment? = nil,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    #expect(
      text.utf8.elementsEqual(expected.utf8), comment, sourceLocation: sourceLocation)
    #expect(
      TableSourceDocument(text).blocks == TableSourceDocument(expected).blocks, comment,
      sourceLocation: sourceLocation)
  }

  /// About 1 MB, under the source limit: `copies` renamed copies of the
  /// fixture's two tables, each with deleted bindings, separated by prose
  /// lines `<prose> = 1 + 2`.
  static func large(prose: String, copies: Int = 100) -> String {
    let lines = fixture("valid-two-tables.txt").split(
      separator: "\n", omittingEmptySubsequences: false)
    // The Rates block, a prose line, and the Items block that refers to Rates.
    let pair = lines[2..<9].joined(separator: "\n") + "\n"
    let filler = String(repeating: "\(prose) = 1 + 2\n", count: 620)
    var text = ""
    for copy in 0..<copies {
      // Same-length names and identities keep every binding's offsets valid.
      let letters = String(
        [copy / 26 / 26, copy / 26 % 26, copy % 26].map { Character(UnicodeScalar(97 + $0)!) })
      text +=
        pair
        .replacingOccurrences(of: "Rates", with: "R\(letters)z")
        .replacingOccurrences(of: "Items", with: "I\(letters)z")
        .replacingOccurrences(
          of: "10000000-0000", with: String(format: "1%07x-0000", copy)
        )
        .replacingOccurrences(
          of: "20000000-0000", with: String(format: "2%07x-0000", copy))
      text += filler
    }
    return text
  }
}

/// A child process that is never waited on without a deadline. A child that
/// outlives a deadline is killed with `SIGKILL` and recorded as an issue.
final class ChildProcess {
  static let deadline: TimeInterval = 60

  private let process = Process()
  private let exited = DispatchSemaphore(value: 0)
  private let output = Pipe()

  /// Starts `executable`, capturing its standard output unless
  /// `capturesOutput` is false.
  init(_ executable: URL, _ arguments: [String], capturesOutput: Bool = true) throws {
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = capturesOutput ? output : FileHandle.nullDevice
    // Set before launch, so the exit cannot be missed.
    process.terminationHandler = { [exited] _ in exited.signal() }
    try process.run()
  }

  /// Waits up to the deadline for the child's first output, and returns
  /// it, or an empty string if it printed nothing before exiting.
  func waitForOutput(sourceLocation: Testing.SourceLocation = #_sourceLocation) -> String {
    let received = DispatchSemaphore(value: 0)
    let text = OSAllocatedUnfairLock(initialState: "")
    let handle = output.fileHandleForReading
    // A blocked read ends when the child is killed and the pipe closes.
    DispatchQueue.global().async {
      let data = handle.availableData
      text.withLock { $0 = String(decoding: data, as: UTF8.self) }
      received.signal()
    }
    if received.wait(timeout: .now() + Self.deadline) == .timedOut {
      Issue.record("helper printed nothing in \(Self.deadline) s", sourceLocation: sourceLocation)
      kill()
    }
    return text.withLock { $0 }
  }

  /// Kills the child unless it already exited, so a reused process ID is
  /// never signalled.
  func kill() {
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }

  /// Waits up to the deadline for the child to exit, killing it after that.
  @discardableResult
  func waitForExit(sourceLocation: Testing.SourceLocation = #_sourceLocation) -> Bool {
    if exited.wait(timeout: .now() + Self.deadline) == .success {
      return true
    }
    Issue.record("helper did not exit in \(Self.deadline) s", sourceLocation: sourceLocation)
    kill()
    _ = exited.wait(timeout: .now() + 10)
    return false
  }

  /// Whether the child was killed with `SIGKILL`. Call after it exits.
  var wasKilled: Bool {
    process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
  }

  var terminationStatus: Int32 { process.terminationStatus }

  /// Everything the child printed. Call after it exits.
  func readOutput() -> String {
    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
}
