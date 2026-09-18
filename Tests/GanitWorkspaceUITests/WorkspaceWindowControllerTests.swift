import AppKit
import Foundation
import GanitDocuments
import GanitFormatting
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
    let split = try #require(window.contentViewController as? NSSplitViewController)
    // The sidebar lists a title and a date, so it stays a narrow index of the
    // library rather than a second half of the window.
    let sidebarItem = try #require(split.splitViewItems.first)
    #expect(sidebarItem.minimumThickness == 150)
    #expect(sidebarItem.maximumThickness == 280)
    #expect((150...200).contains(controller.sidebar.view.frame.width))
    #expect(window.isRestorable && window.restorationClass == WorkspaceRestoration.self)
    #expect(window.toolbar?.items.map(\.itemIdentifier).contains(.searchSheets) == true)
    #expect(controller.editor?.view.superview != nil)
    #expect(window.title == "Untitled")
    #expect(Set(controller.sidebar.sheets.map(\.id)) == Set([SheetLibrary.scratchID] + ids))
  }

  /// An empty "Folders" heading sits immediately above the list of sheets,
  /// where it reads as though the sheets beneath it were the folders.
  @Test
  func namesTheFoldersOnlyOnceThereAreSome() throws {
    let (workspace, ids) = try makeWorkspace([""])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let outline = controller.sidebar.collectionsView
    let rows = {
      (0..<outline.numberOfRows).compactMap {
        (outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?
          .textField?.stringValue
      }
    }
    let collections = ["Library", "All Sheets", "Recent", "Favorites", "Archive", "Trash"]

    #expect(rows() == collections)
    _ = try workspace.library.createFolder(named: "Travel")
    controller.sidebar.reload()
    #expect(rows() == collections + ["Folders", "Travel"])
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
    #expect(controller.sidebar.view.frame.width >= 150)
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
    // The window moves off the trashed sheet to one still listed.
    let shown = try #require(controller.sheetID)
    #expect([ids[1], SheetLibrary.scratchID].contains(shown))

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
  func showingTheCurrentWindowReusesItInsteadOfOpeningAnother() throws {
    let (workspace, ids) = try makeWorkspace(["1 + 1"])
    defer { close(workspace) }
    let first = workspace.openWindow(showing: ids[0])
    let shown = try workspace.showCurrentWindow()
    #expect(shown === first)
    #expect(workspace.windows.count == 1)
  }

  @Test
  func searchNarrowsTheListedSheets() throws {
    let (workspace, ids) = try makeWorkspace(["hotel = 85", "rent = 2100"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])

    controller.sidebar.search = "HOTEL"
    #expect(controller.sidebar.sheets.map(\.id) == [ids[0]])
  }

  @Test
  func revealingAnOpenSheetRaisesItsWindowInsteadOfOpeningAnother() throws {
    let (workspace, ids) = try makeWorkspace(["1 + 1", "2 + 2"])
    defer { close(workspace) }
    let first = workspace.openWindow(showing: ids[0])

    #expect(workspace.reveal(ids[0]) === first)
    #expect(workspace.windows.count == 1)

    let second = workspace.reveal(ids[1])

    #expect(second !== first)
    #expect(workspace.windows.count == 2)
    #expect(second.sheetID == ids[1])
  }

  /// The Format menu writes the open sheet's answers the way it says, keeps the
  /// choice with the sheet, and checks the format the sheet is using.
  @Test
  func writesAnswersTheWayTheFormatMenuSays() async throws {
    let (workspace, ids) = try makeWorkspace(["1234.5"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let editor = try #require(controller.editor)
    #expect(await editor.exportedLines().first?.answer == "1,234.5")

    let fixed = NSMenuItem(
      title: "",
      action: #selector(WorkspaceCommands.setNumberFormat(_:)),
      keyEquivalent: ""
    )
    fixed.tag = NumberFormatMenu.tag(of: .fixedDecimals(2))
    controller.setNumberFormat(fixed)
    #expect(await editor.exportedLines().first?.answer == "1,234.50")
    #expect(controller.validateMenuItem(fixed))
    #expect(fixed.state == .on)

    let automatic = NSMenuItem(
      title: "",
      action: #selector(WorkspaceCommands.setNumberFormat(_:)),
      keyEquivalent: ""
    )
    automatic.tag = NumberFormatMenu.tag(of: .automatic)
    #expect(controller.validateMenuItem(automatic))
    #expect(automatic.state == .off)

    controller.toggleDigitGrouping(nil)
    #expect(await editor.exportedLines().first?.answer == "1234.50")

    let stored = try workspace.library.store.load(id: ids[0]).metadata.preferences.display
    #expect(stored == DisplayOptions(groupsDigits: false, numbers: .fixedDecimals(2)))
    let reopened = try Workspace(library: try SheetLibrary(root: root))
    defer { close(reopened) }
    let sheetAgain = try #require(reopened.openWindow(showing: ids[0]).editor)
    #expect(await sheetAgain.exportedLines().first?.answer == "1234.50")
  }

  @Test
  func anEmptyUntitledSheetIsDiscardedWhenItIsLeft() async throws {
    let (workspace, ids) = try makeWorkspace(["rent = 1"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])

    controller.newSheet(nil)
    let untitled = try #require(controller.sheetID)
    #expect(untitled != ids[0])

    // Moving away from an empty, unnamed sheet leaves nothing behind.
    controller.show(ids[0])
    #expect(throws: (any Error).self) { try workspace.library.store.load(id: untitled) }

    // One that was written in stays.
    controller.newSheet(nil)
    let written = try #require(controller.sheetID)
    controller.editor?.textView.insertText(
      "2 + 2", replacementRange: NSRange(location: 0, length: 0))
    controller.saveNow(nil)
    controller.show(ids[0])
    #expect(try workspace.library.store.load(id: written).source == "2 + 2")
  }

  @Test
  func theSidebarRewritesHowLongAgoASheetWasWritten() throws {
    let then = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(
      SidebarViewController.relativeTime(of: then, to: then.addingTimeInterval(120))
        .localizedCaseInsensitiveContains("2 minutes"))
    #expect(
      SidebarViewController.relativeTime(of: then, to: then.addingTimeInterval(7_200))
        .localizedCaseInsensitiveContains("2 hours"))
  }

  @Test
  func groupsASheetsAnswersInLakhsOnlyWhileItGroupsDigits() async throws {
    let (workspace, ids) = try makeWorkspace(["1234567"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])
    let editor = try #require(controller.editor)
    let lakhs = NSMenuItem(
      title: "", action: #selector(WorkspaceCommands.toggleLakhGrouping(_:)), keyEquivalent: "")

    controller.toggleLakhGrouping(nil)
    #expect(await editor.exportedLines().first?.answer == "12,34,567")
    #expect(controller.validateMenuItem(lakhs))
    #expect(lakhs.state == .on)

    controller.toggleDigitGrouping(nil)
    #expect(!controller.validateMenuItem(lakhs))
  }

  @Test
  func everyLibraryHasAScratchSheetThatCannotBePutAwayOrRenamed() throws {
    let (workspace, ids) = try makeWorkspace(["rent"])
    defer { close(workspace) }
    let controller = try workspace.openScratch()

    #expect(controller.sheetID == SheetLibrary.scratchID)
    #expect(controller.window?.title == "Scratch")
    #expect(try workspace.library.store.load(id: SheetLibrary.scratchID).source == "")

    select(SheetLibrary.scratchID, in: controller)
    for action in [
      #selector(WorkspaceCommands.renameSheet(_:)),
      #selector(WorkspaceCommands.archiveSheet(_:)),
      #selector(WorkspaceCommands.moveSheetToTrash(_:)),
      #selector(WorkspaceCommands.deleteSheetImmediately(_:)),
    ] {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      #expect(!controller.validateMenuItem(item), "\(action)")
    }
    #expect(
      controller.validateMenuItem(
        NSMenuItem(
          title: "", action: #selector(WorkspaceCommands.duplicateSheet(_:)), keyEquivalent: "")))
    #expect(throws: DocumentStorageError.self) {
      try workspace.library.deletePermanently(SheetLibrary.scratchID)
    }

    // An ordinary sheet is still put away and deleted as before.
    select(ids[0], in: controller)
    #expect(
      controller.validateMenuItem(
        NSMenuItem(
          title: "", action: #selector(WorkspaceCommands.moveSheetToTrash(_:)), keyEquivalent: "")))

    // Opening the library again finds the same scratch sheet, not another.
    let reopened = try Workspace(library: try SheetLibrary(root: root))
    defer { close(reopened) }
    #expect(
      Set(try reopened.library.index.summaries().map(\.id)) == Set([SheetLibrary.scratchID] + ids))
  }

  @Test
  func markdownModeAndTheAnswerRuleStayWithTheSheet() throws {
    let (workspace, ids) = try makeWorkspace(["2 + 2"])
    defer { close(workspace) }
    let controller = workspace.openWindow(showing: ids[0])

    let prose = NSMenuItem(
      title: "", action: #selector(WorkspaceCommands.toggleMarkdownMode(_:)), keyEquivalent: "")
    let rule = NSMenuItem(
      title: "", action: #selector(WorkspaceCommands.toggleAnswerSeparator(_:)), keyEquivalent: "")
    #expect(controller.validateMenuItem(rule))
    #expect(rule.state == .on)

    controller.toggleMarkdownMode(nil)
    #expect(controller.validateMenuItem(prose))
    #expect(prose.state == .on)
    #expect(controller.sidebar.sheets.first { $0.id == ids[0] }?.isMarkdown == true)
    let window = try #require(controller.window)
    window.layoutIfNeeded()
    let row = try #require(controller.sidebar.sheets.firstIndex { $0.id == ids[0] })
    controller.sidebar.sheetsView.layoutSubtreeIfNeeded()
    let cell = try #require(
      controller.sidebar.sheetsView.view(atColumn: 0, row: row, makeIfNecessary: true)
        as? NSTableCellView)
    cell.layoutSubtreeIfNeeded()
    let mark = try #require(firstImageView(in: cell))
    let markFrame = mark.convert(mark.bounds, to: cell)
    #expect(cell.bounds.width > 0)
    #expect(markFrame.maxX <= cell.bounds.maxX + 1)
    // Inline answers leave no column, so the rule has nothing to mark.
    #expect(!controller.validateMenuItem(rule))

    controller.toggleMarkdownMode(nil)
    controller.toggleAnswerSeparator(nil)
    let cad = NSMenuItem(
      title: "", action: #selector(WorkspaceCommands.setDollarCurrency(_:)), keyEquivalent: "")
    cad.representedObject = "CAD"
    controller.setDollarCurrency(cad)
    #expect(controller.validateMenuItem(cad))
    #expect(cad.state == .on)
    let stored = try workspace.library.store.load(id: ids[0]).metadata.preferences.display
    #expect(
      stored
        == DisplayOptions(
          writesAnswersInline: false, showsAnswerSeparator: false, dollarCurrency: "CAD"))

    let reopened = try Workspace(library: try SheetLibrary(root: root))
    defer { close(reopened) }
    let again = reopened.openWindow(showing: ids[0])
    #expect(again.validateMenuItem(rule))
    #expect(rule.state == .off)
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

@MainActor
private func firstImageView(in view: NSView) -> NSImageView? {
  if let image = view as? NSImageView {
    return image
  }
  for child in view.subviews {
    if let image = firstImageView(in: child) {
      return image
    }
  }
  return nil
}
