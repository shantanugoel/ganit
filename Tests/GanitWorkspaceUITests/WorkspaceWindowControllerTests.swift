import AppKit
import Foundation
import GanitDocuments
import Testing

@testable import GanitEditorUI
@testable import GanitWorkspaceUI

@MainActor
@Suite
struct WorkspaceWindowControllerTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func showsTheSidebarBesideTheOpenSheet() throws {
    let (workspace, ids) = try makeWorkspace([""])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let window = try #require(controller.window)

    #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
    #expect(window.contentMinSize == NSSize(width: 640, height: 400))
    #expect(window.contentViewController is NSSplitViewController)
    #expect(window.isRestorable && window.restorationClass == WorkspaceRestoration.self)
    #expect(window.toolbar?.items.map(\.itemIdentifier).contains(.searchSheets) == true)
    #expect(controller.editor?.view.superview != nil)
    #expect(window.title == "Untitled")
    #expect(controller.sidebar.sheets.map(\.id) == ids)
  }

  @Test
  func fitsSidebarSourceAndAnswersAtMinimumSizeAndSupportsFullScreen() throws {
    let (workspace, ids) = try makeWorkspace(["monthly rent = 2,100\nmonthly rent * 12"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let window = try #require(controller.window)
    window.setContentSize(window.contentMinSize)
    window.layoutIfNeeded()

    #expect(window.contentView?.frame.size == window.contentMinSize)
    #expect(controller.sidebar.view.frame.width >= 200)
    let textView = try #require(controller.editor?.textView as? SheetTextView)
    #expect(textView.answerColumnWidth >= SheetTextView.answerColumnWidthRange.lowerBound)
    #expect(textView.bounds.width - textView.answerColumnWidth >= textView.answerColumnWidth)
    #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    #expect(window.tabbingMode == .preferred)
  }

  @Test
  func savesEditsWhenTheySettleAndWhenTheWindowResignsKey() async throws {
    let (workspace, ids) = try makeWorkspace([""])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let textView = try #require(controller.editor?.textView)

    textView.insertText("# Rent\n2,100", replacementRange: NSRange(location: 0, length: 0))
    #expect(try workspace.library.store.load(id: ids[0]).source == "")
    try await Task.sleep(for: SheetAutosaver.settleDelay)
    let deadline = ContinuousClock.now + .seconds(10)
    while try workspace.library.store.load(id: ids[0]).source.isEmpty,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try workspace.library.store.load(id: ids[0]).source == "# Rent\n2,100")
    #expect(controller.window?.title == "Rent")
    #expect(controller.sidebar.sheets.first?.title == "Rent")

    textView.insertText(" * 12", replacementRange: NSRange(location: 12, length: 0))
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(try workspace.library.store.load(id: ids[0]).source == "# Rent\n2,100 * 12")
  }

  @Test
  func keepsEachSheetsTextAndUndoWhenSwitchingSheets() throws {
    let (workspace, ids) = try makeWorkspace(["first", "second"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let firstEditor = try #require(controller.editor)
    firstEditor.documentUndoManager.groupsByEvent = false
    firstEditor.documentUndoManager.beginUndoGrouping()
    firstEditor.textView.insertText(" edited", replacementRange: NSRange(location: 5, length: 0))
    firstEditor.documentUndoManager.endUndoGrouping()

    select(ids[1], in: controller)
    #expect(controller.editor?.textView.string == "second")
    #expect(try workspace.library.store.load(id: ids[0]).source == "first edited")

    select(ids[0], in: controller)
    #expect(controller.editor === firstEditor)
    firstEditor.documentUndoManager.undo()
    #expect(firstEditor.textView.string == "first")
  }

  @Test
  func showsASheetInOnlyOneWindow() throws {
    let (workspace, ids) = try makeWorkspace(["first", "second"])
    defer { close(workspace) }
    let main = workspace.openWindow(showing: ids[0])

    main.sidebar.select(sheet: ids[1])
    main.openInNewWindow(nil)
    let other = try #require(workspace.windows.last)
    #expect(workspace.windows.count == 2)
    #expect(other.sheetID == ids[1])

    // Selecting a sheet shown elsewhere brings that window forward instead.
    select(ids[1], in: main)
    #expect(main.sheetID == ids[0])
    #expect(other.sheetID == ids[1])
  }

  @Test
  func organizingIsUndoableAndSurvivesLaterSaves() throws {
    let library = try SheetLibrary(root: root)
    let folder = try library.createFolder(named: "Travel")
    let (workspace, ids) = try makeWorkspace(["trip", "rent"], library: library)
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let undoManager = try #require(controller.window?.undoManager)
    undoManager.groupsByEvent = false

    controller.editor?.textView.insertText("!", replacementRange: NSRange(location: 4, length: 0))
    undoManager.beginUndoGrouping()
    controller.toggleFavorite(nil)
    undoManager.endUndoGrouping()
    controller.saveNow(nil)
    #expect(try library.store.load(id: ids[0]).metadata.isFavorite)
    #expect(try library.store.load(id: ids[0]).source == "trip!")

    let move = NSMenuItem()
    move.representedObject = folder.id
    undoManager.beginUndoGrouping()
    controller.moveSheetToFolder(move)
    undoManager.endUndoGrouping()
    undoManager.beginUndoGrouping()
    controller.moveSheetToTrash(nil)
    undoManager.endUndoGrouping()
    #expect(try library.store.load(id: ids[0]).metadata.state == .trashed)
    #expect(controller.sheetID == ids[1])

    undoManager.undo()
    #expect(try library.store.load(id: ids[0]).metadata.state == .active)
    undoManager.undo()
    #expect(try library.store.load(id: ids[0]).metadata.folderID == nil)
    undoManager.redo()
    #expect(try library.store.load(id: ids[0]).metadata.folderID == folder.id)
  }

  @Test
  func restoresTheWindowsSheetSelectionAndSidebar() throws {
    let (workspace, ids) = try makeWorkspace(["hotel = 85\nrent = 2100", "other"])
    defer { close(workspace) }
    let original = workspace.openWindow(showing: ids[0])
    original.sidebar.show(.favorites)
    original.sidebar.show(.all)
    original.editor?.textView.setSelectedRange(NSRange(location: 11, length: 4))

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    original.window(try #require(original.window), willEncodeRestorableState: archiver)
    archiver.finishEncoding()
    original.close()

    let restored = workspace.openWindow(showing: nil)
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    restored.window(try #require(restored.window), didDecodeRestorableState: unarchiver)

    #expect(restored.sheetID == ids[0])
    #expect(restored.sidebar.collection == .all)
    #expect(restored.editor?.textView.selectedRange() == NSRange(location: 11, length: 4))
  }

  @Test
  func restoresABackupAsAnUndoableSavedEdit() throws {
    var now = Date(timeIntervalSince1970: 1_789_459_200)
    let library = try SheetLibrary(
      root: root,
      timeZone: try #require(TimeZone(identifier: "UTC")),
      now: { now }
    )
    let (workspace, ids) = try makeWorkspace(["yesterday"], library: library)
    defer { close(workspace) }
    now += 86_400
    let controller = workspace.openWindow(showing: ids[0])
    let editor = try #require(controller.editor)
    let undoManager = editor.documentUndoManager
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    editor.textView.insertText("today", replacementRange: NSRange(location: 0, length: 9))
    undoManager.endUndoGrouping()
    controller.saveNow(nil)

    let backup = try #require(try library.backups(of: ids[0]).first)
    undoManager.beginUndoGrouping()
    controller.restore(backup)
    undoManager.endUndoGrouping()

    #expect(editor.textView.string == "yesterday")
    #expect(try library.store.load(id: ids[0]).source == "yesterday")
    undoManager.undo()
    #expect(editor.textView.string == "today")
  }

  @Test
  func importedSheetsAppearInOpenWindows() throws {
    let (workspace, ids) = try makeWorkspace(["existing"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "Groceries.txt")
    try Data("# Groceries\nmilk = 3.50".utf8).write(to: file)

    let imported = try workspace.importSheet(from: file)

    #expect(controller.sidebar.sheets.contains { $0.id == imported && $0.title == "Groceries" })
    #expect(try workspace.library.store.load(id: imported).source == "# Groceries\nmilk = 3.50")
  }

  @Test
  func opensPromotedTextAsANewSheet() throws {
    let (workspace, _) = try makeWorkspace([])
    defer { close(workspace) }

    let controller = try workspace.openNewSheet(source: "# Quick\n6 * 7")

    let id = try #require(controller.sheetID)
    #expect(try workspace.library.store.load(id: id).source == "# Quick\n6 * 7")
    #expect(controller.window?.title == "Quick")
  }

  @Test
  func reopensTheMostRecentActiveSheetOrANewOne() throws {
    let library = try SheetLibrary(root: root)
    let empty = try Workspace(library: library)
    let created = try empty.openMostRecentSheet()
    defer { close(empty) }
    #expect(created.sheetID != nil)

    let (workspace, ids) = try makeWorkspace(["older", "newer"], library: library)
    defer { close(workspace) }
    try library.update(ids[1]) { $0.state = .archived }
    let reopened = try workspace.openMostRecentSheet()
    #expect(reopened.sheetID == ids[0] || reopened.sheetID == created.sheetID)
    #expect(reopened.sheetID != ids[1])
  }

  @Test
  func searchNarrowsTheListedSheets() throws {
    let (workspace, ids) = try makeWorkspace(["hotel = 85", "rent = 2100"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])

    controller.sidebar.search = "HOTEL"
    #expect(controller.sidebar.sheets.map(\.id) == [ids[0]])
  }

  private func makeWorkspace(
    _ sources: [String],
    library: SheetLibrary? = nil
  ) throws -> (Workspace, [UUID]) {
    let library = try library ?? SheetLibrary(root: root)
    let ids = try sources.map { source in
      try library.save(
        source: source,
        metadata: library.create(preferences: SheetPreferences.standard)
      ).id
    }
    return (try Workspace(library: library), ids)
  }

  private func select(_ id: UUID, in controller: WorkspaceWindowController) {
    guard let row = controller.sidebar.sheets.firstIndex(where: { $0.id == id }) else {
      Issue.record("Sheet is not listed")
      return
    }
    controller.sidebar.sheetsView.selectRowIndexes([row], byExtendingSelection: false)
  }

  private func close(_ workspace: Workspace) {
    for controller in workspace.windows {
      controller.window?.orderOut(nil)
    }
  }
}
