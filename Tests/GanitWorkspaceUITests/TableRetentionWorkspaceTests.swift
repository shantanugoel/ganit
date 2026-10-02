import AppKit
import Foundation
import GanitDocuments
import Testing

@testable import GanitEditorUI
@testable import GanitEngine
@testable import GanitWorkspaceUI

/// A sheet whose table blocks are malformed, stale, duplicated, of another
/// version or unterminated is retained byte for byte through ordinary edits,
/// Undo and Redo, autosave, closing, reopening and restoring a backup. No
/// step reformats or repairs a block.
@MainActor
@Suite
struct TableRetentionWorkspaceTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitTableRetention-\(UUID().uuidString)", directoryHint: .isDirectory)

  static func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "GanitEngineTests/Fixtures/TableBlocks/\(name)")
    return try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
  }

  @Test(arguments: [
    "malformed-json.txt", "malformed-opener.txt", "unsupported-version.txt", "unterminated.txt",
    "duplicate-id.txt", "stale-fingerprint.txt", "orphan-target.txt", "line-endings-crlf.txt",
  ])
  func blocksSurviveEditsSavesReopeningAndRestore(fixture: String) async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Self.fixture(fixture)
    let clock = DayClock()
    let library = try SheetLibrary(root: root, timeZone: .gmt, now: clock.now)
    let id = try library.save(source: original, metadata: library.create(preferences: .standard)).id
    // Edits happen on a later day, so the first save backs up the original.
    clock.day = 1
    let workspace = try Workspace(library: library)
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: id)
    let editor = try #require(controller.editor)
    editor.documentUndoManager.groupsByEvent = false
    let stored = { Array(try workspace.library.store.load(id: id).source.utf8) }
    try await expectRetained(editor, original)

    // An edit above the blocks is saved once edits settle.
    var expected = original
    edit(editor, &expected, NSRange(location: 0, length: 0), "total =>\n")
    try await Task.sleep(for: SheetAutosaver.settleDelay)
    let deadline = ContinuousClock.now + .seconds(10)
    while try stored() != Array(expected.utf8), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try stored() == Array(expected.utf8))
    try await expectRetained(editor, expected)
    let edited = [expected]

    // Typing inside the first block saves exactly what was typed.
    let blocks = TableSourceDocument.blockLineRanges(in: editor.sheet)
    let line = try #require(blocks.first).lowerBound + 1
    let start = SheetSource(expected).lines.prefix(line).reduce(0) {
      $0 + $1.text.utf16.count + ($1.terminator?.rawValue.utf16.count ?? 0)
    }
    edit(editor, &expected, NSRange(location: start, length: 0), "Z")
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(expected.utf8))
    try await expectRetained(editor, expected)

    // Undo and Redo save each state exactly.
    editor.documentUndoManager.undo()
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(edited[0].utf8))
    editor.documentUndoManager.undo()
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(original.utf8))
    try await expectRetained(editor, original)
    editor.documentUndoManager.redo()
    editor.documentUndoManager.redo()
    try await expectRetained(editor, expected)

    // Closing saves, and the sheet reopens with the same bytes.
    controller.close()
    #expect(try stored() == Array(expected.utf8))
    let reopened = try Workspace(library: SheetLibrary(root: root, timeZone: .gmt, now: clock.now))
    defer { close(reopened) }
    let window = reopened.openWindow(showing: id)
    let reloaded = try #require(window.editor)
    try await expectRetained(reloaded, expected)

    // Restoring the backup brings back the original bytes as one Undo step.
    let backup = try #require(try reopened.library.backups(of: id).first)
    #expect(Array(try reopened.library.load(backup).source.utf8) == Array(original.utf8))
    window.restore(backup)
    try await expectRetained(reloaded, original)
    #expect(Array(try reopened.library.store.load(id: id).source.utf8) == Array(original.utf8))
    reloaded.documentUndoManager.undo()
    try await expectRetained(reloaded, expected)
    // Saving now also leaves no pending save to outlive the temporary library.
    try reopened.sheet(id).autosaver.saveNow()
    #expect(Array(try reopened.library.store.load(id: id).source.utf8) == Array(expected.utf8))
  }

  /// The text is exact, and no line of any block has an answer, a
  /// declaration or an assistant prompt.
  private func expectRetained(
    _ editor: SheetEditorViewController, _ expected: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) async throws {
    #expect(
      editor.textView.string.utf8.elementsEqual(expected.utf8), sourceLocation: sourceLocation)
    #expect(editor.sheet.text.utf8.elementsEqual(expected.utf8), sourceLocation: sourceLocation)
    await editor.scheduler?.waitUntilIdle()
    let evaluation = try #require(editor.latestEvaluation, sourceLocation: sourceLocation)
    let blocks = TableSourceDocument.blockLineRanges(in: editor.sheet)
    #expect(evaluation.tables.map(\.physicalLines) == blocks, sourceLocation: sourceLocation)
    #expect(
      evaluation.tables.allSatisfy { $0.diagnostics.isEmpty || $0.projection == nil },
      sourceLocation: sourceLocation)
    for line in blocks.joined().map({ evaluation.lines[$0] }) {
      #expect(
        line.result == nil && line.declaredVariableName == nil, sourceLocation: sourceLocation)
      #expect(line.assistantPrompts.isEmpty, sourceLocation: sourceLocation)
    }
  }

  private func edit(
    _ editor: SheetEditorViewController, _ expected: inout String, _ range: NSRange,
    _ replacement: String
  ) {
    editor.textView.breakUndoCoalescing()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(replacement, replacementRange: range)
    editor.documentUndoManager.endUndoGrouping()
    expected = (expected as NSString).replacingCharacters(in: range, with: replacement)
  }

  private func close(_ workspace: Workspace) {
    for controller in workspace.windows {
      controller.window?.orderOut(nil)
    }
  }
}

/// A clock whose day the test chooses, advancing a second per reading.
private final class DayClock: @unchecked Sendable {
  var day = 0
  private var seconds = 0.0

  func now() -> Date {
    seconds += 1
    return Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400 + seconds)
  }
}
