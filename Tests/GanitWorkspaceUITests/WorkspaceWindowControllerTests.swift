import AppKit
import Foundation
import GanitDocuments
import GanitEditorUI
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct WorkspaceWindowControllerTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func workspaceWindowUsesStandardMacWindowBehavior() throws {
    let library = try SheetLibrary(root: root)
    let controller = try open(
      library, try library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let window = try #require(controller.window)

    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.miniaturizable))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.minSize == NSSize(width: 640, height: 400))
    #expect(window.contentViewController === controller.editor)
    #expect(window.title == "Untitled")
  }

  @Test
  func savesEditsWhenTheySettleAndWhenTheWindowResignsKey() async throws {
    let library = try SheetLibrary(root: root)
    let sheet = try library.create(preferences: WorkspaceWindowController.newSheetPreferences)
    let controller = try open(library, sheet)
    let textView = controller.editor.textView

    textView.insertText("# Rent\n2,100", replacementRange: NSRange(location: 0, length: 0))
    #expect(try library.store.load(id: sheet.id).source == "")
    try await Task.sleep(for: SheetAutosaver.settleDelay + .milliseconds(300))
    #expect(try library.store.load(id: sheet.id).source == "# Rent\n2,100")
    #expect(controller.window?.title == "Rent")

    textView.insertText(" * 12", replacementRange: NSRange(location: 12, length: 0))
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification, object: controller.window)
    #expect(try library.store.load(id: sheet.id).source == "# Rent\n2,100 * 12")
    #expect(try library.index.search("* 12") == [sheet.id])
  }

  @Test
  func restoresABackupAsAnUndoableSavedEdit() throws {
    var now = Date(timeIntervalSince1970: 1_789_459_200)
    let library = try SheetLibrary(
      root: root,
      timeZone: try #require(TimeZone(identifier: "UTC")),
      now: { now }
    )
    var sheet = try library.create(preferences: WorkspaceWindowController.newSheetPreferences)
    sheet = try library.save(source: "yesterday", metadata: sheet)
    now += 86_400
    let controller = try open(library, sheet)
    let undoManager = controller.editor.documentUndoManager
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    controller.editor.textView.insertText(
      "today", replacementRange: NSRange(location: 0, length: 9))
    undoManager.endUndoGrouping()
    controller.saveNow(nil)

    let backup = try #require(try library.backups(of: sheet.id).first)
    undoManager.beginUndoGrouping()
    controller.restore(backup)
    undoManager.endUndoGrouping()

    #expect(controller.editor.textView.string == "yesterday")
    #expect(try library.store.load(id: sheet.id).source == "yesterday")
    controller.editor.documentUndoManager.undo()
    #expect(controller.editor.textView.string == "today")
  }

  private func open(_ library: SheetLibrary, _ metadata: SheetMetadata) throws
    -> WorkspaceWindowController
  {
    try WorkspaceWindowController(library: library, sheet: try library.store.load(id: metadata.id))
  }
}
