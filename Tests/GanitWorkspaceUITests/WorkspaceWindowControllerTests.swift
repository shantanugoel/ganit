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
  func showsTheSidebarBesideTheOpenSheet() throws {
    let library = try SheetLibrary(root: root)
    let controller = try open(
      library, try library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let window = try #require(controller.window)

    #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
    #expect(window.contentMinSize == NSSize(width: 640, height: 400))
    #expect(window.contentViewController is NSSplitViewController)
    #expect(window.toolbar?.items.map(\.itemIdentifier).contains(.searchSheets) == true)
    #expect(controller.editor?.view.superview != nil)
    #expect(window.title == "Untitled")
    #expect(controller.sidebar.sheets.map(\.id) == [controller.sheetID])
  }

  @Test
  func savesEditsWhenTheySettleAndWhenTheWindowResignsKey() async throws {
    let library = try SheetLibrary(root: root)
    let sheet = try library.create(preferences: WorkspaceWindowController.newSheetPreferences)
    let controller = try open(library, sheet)
    let textView = try #require(controller.editor?.textView)

    textView.insertText("# Rent\n2,100", replacementRange: NSRange(location: 0, length: 0))
    #expect(try library.store.load(id: sheet.id).source == "")
    try await Task.sleep(for: SheetAutosaver.settleDelay + .milliseconds(300))
    #expect(try library.store.load(id: sheet.id).source == "# Rent\n2,100")
    #expect(controller.window?.title == "Rent")
    #expect(controller.sidebar.sheets.first?.title == "Rent")

    textView.insertText(" * 12", replacementRange: NSRange(location: 12, length: 0))
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification, object: controller.window)
    #expect(try library.store.load(id: sheet.id).source == "# Rent\n2,100 * 12")
  }

  @Test
  func selectingSheetsSavesAndOpensThem() throws {
    let library = try SheetLibrary(root: root)
    let first = try library.save(
      source: "first",
      metadata: library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let second = try library.save(
      source: "second",
      metadata: library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let controller = try open(library, first)
    controller.editor?.textView.insertText(
      " edited", replacementRange: NSRange(location: 5, length: 0))

    let row = try #require(controller.sidebar.sheets.firstIndex { $0.id == second.id })
    controller.sidebar.sheetsView.selectRowIndexes([row], byExtendingSelection: false)

    #expect(controller.sheetID == second.id)
    #expect(controller.editor?.textView.string == "second")
    #expect(try library.store.load(id: first.id).source == "first edited")
  }

  @Test
  func organizesSheetsThroughCollectionsFoldersFavoritesArchiveAndTrash() throws {
    let library = try SheetLibrary(root: root)
    let folder = try library.createFolder(named: "Travel")
    let first = try library.save(
      source: "first",
      metadata: library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let controller = try open(library, first)
    let sidebar = controller.sidebar

    sidebar.show(.folder(folder.id))
    controller.newSheet(nil)
    let created = try #require(controller.sheetID)
    #expect(try library.store.load(id: created).metadata.folderID == folder.id)
    #expect(sidebar.sheets.map(\.id) == [created])

    controller.toggleFavorite(nil)
    sidebar.show(.favorites)
    sidebar.select(sheet: created)
    #expect(sidebar.sheets.map(\.id) == [created])

    controller.archiveSheet(nil)
    #expect(sidebar.sheets.isEmpty)
    #expect(controller.editor == nil)
    sidebar.show(.archive)
    sidebar.select(sheet: created)
    controller.moveSheetToTrash(nil)
    sidebar.show(.trash)
    sidebar.select(sheet: created)
    #expect(controller.editor?.textView.isEditable == false)
    controller.restoreSheet(nil)
    sidebar.show(.all)
    #expect(Set(sidebar.sheets.map(\.id)) == [first.id, created])
  }

  @Test
  func searchNarrowsTheListedSheets() throws {
    let library = try SheetLibrary(root: root)
    let hotel = try library.save(
      source: "hotel = 85",
      metadata: library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    _ = try library.save(
      source: "rent = 2100",
      metadata: library.create(preferences: WorkspaceWindowController.newSheetPreferences))
    let controller = try open(library, hotel)

    controller.sidebar.search = "HOTEL"
    #expect(controller.sidebar.sheets.map(\.id) == [hotel.id])
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
    let editor = try #require(controller.editor)
    let undoManager = editor.documentUndoManager
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    editor.textView.insertText("today", replacementRange: NSRange(location: 0, length: 9))
    undoManager.endUndoGrouping()
    controller.saveNow(nil)

    let backup = try #require(try library.backups(of: sheet.id).first)
    undoManager.beginUndoGrouping()
    controller.restore(backup)
    undoManager.endUndoGrouping()

    #expect(editor.textView.string == "yesterday")
    #expect(try library.store.load(id: sheet.id).source == "yesterday")
    undoManager.undo()
    #expect(editor.textView.string == "today")
  }

  private func open(_ library: SheetLibrary, _ metadata: SheetMetadata) throws
    -> WorkspaceWindowController
  {
    try WorkspaceWindowController(library: library, sheet: try library.store.load(id: metadata.id))
  }
}
