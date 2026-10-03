import AppKit
import Foundation
import GanitDocuments
import Testing

@testable import GanitEditorUI
@testable import GanitEngine
@testable import GanitWorkspaceUI

/// M3 task 4: a structural table edit is a document edit. It is autosaved
/// like typing, Undo and Redo are saved byte for byte, and a sheet opened
/// from a second window shows the same document (one editor, one text, one
/// Undo history), so no window shows a stale projection.
@MainActor
@Suite
struct TableStructuralWorkspaceTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitTableStructural-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func structuralEditsAreSavedAndSharedAcrossWindows() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var table = TableModel.creating(name: "Items", headers: [("Qty", .value)], rowCount: 1)
    table.cells = [TableCell(row: table.rows[0], column: table.columns[0].id, source: "2")]
    let original =
      "x = 1\n" + (try TableSourceDocument.canonicalBlock(for: table)) + "Items!A2 + @1\n"
    let library = try SheetLibrary(root: root, timeZone: .gmt)
    let id = try library.save(source: original, metadata: library.create(preferences: .standard)).id
    let workspace = try Workspace(library: library)
    defer {
      for controller in workspace.windows { controller.window?.orderOut(nil) }
    }
    let first = workspace.openWindow(showing: id)
    let editor = try #require(first.editor)
    editor.documentUndoManager.groupsByEvent = false
    let stored = { Array(try workspace.library.store.load(id: id).source.utf8) }

    try editor.renameTable(table.id, to: "Goods")
    let renamed = editor.textView.string
    #expect(renamed.hasSuffix("Goods!A2 + @1\n"))
    // The autosaver has the edit pending, exactly as for typing, and saves it.
    #expect(try workspace.sheet(id).autosaver.hasUnsavedChanges)
    first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(renamed.utf8))

    // A second window asked to show the sheet brings the first forward: the
    // sheet has one editor, so there is no second projection to refresh.
    let second = workspace.openWindow(showing: id)
    #expect(second !== first)
    #expect(second.editor == nil)
    #expect(try workspace.sheet(id).editor === editor)
    try editor.appendTableRows(table.id)
    let appended = editor.textView.string
    first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(appended.utf8))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableResult(table.id)?.rows.count == 2)

    // Undo and Redo are saved byte for byte.
    editor.documentUndoManager.undo()
    first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(renamed.utf8))
    editor.documentUndoManager.undo()
    first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try stored() == Array(original.utf8))
    editor.documentUndoManager.redo()
    editor.documentUndoManager.redo()
    try workspace.sheet(id).autosaver.saveNow()
    #expect(try stored() == Array(appended.utf8))
  }
}
