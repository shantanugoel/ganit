import AppKit
import Foundation
import GanitDocuments
import GanitEngine
import GanitQuickUI
import Testing

@testable import GanitWorkspaceUI

/// Automated rows of the accessibility matrix: control and text sizes,
/// accessibility labels, and that no action is reachable only by pointer.
@MainActor
@Suite
struct AccessibilityAuditTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitAccessibilityAudit-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func workspaceWindowMeetsSizeAndLabelRequirements() throws {
    let library = try SheetLibrary(root: root)
    let sheet = try library.save(
      source: "# Trip\nhotel = 85 * 3\n1 m + 1 s", metadata: library.create(preferences: .standard))
    _ = try library.createFolder(named: "Travel")
    let workspace = Workspace(library: library)
    let controller = workspace.openWindow(showing: sheet.id)
    defer { controller.window?.orderOut(nil) }
    let window = try #require(controller.window)
    window.layoutIfNeeded()

    #expect(audit(window.contentView!) == [])
    let spacers: Set<NSToolbarItem.Identifier> = [
      .flexibleSpace, .space, .sidebarTrackingSeparator,
    ]
    for item in window.toolbar?.items ?? [] where !spacers.contains(item.itemIdentifier) {
      #expect(!item.label.isEmpty, "\(item.itemIdentifier.rawValue) has no label")
    }
  }

  @Test
  func quickPanelMeetsSizeAndLabelRequirements() throws {
    let panel = try QuickPanelController(context: SheetPreferences.standard.evaluationContext())
    let window = try #require(panel.window)
    window.layoutIfNeeded()
    #expect(audit(window.contentView!) == [])
    #expect(window.accessibilityLabel() == "Quick Ganit")
  }

  @Test
  func everyContextMenuAndToolbarActionIsInTheMainMenu() throws {
    MainMenu.install(in: NSApplication.shared)
    let mainActions = Set(
      items(in: try #require(NSApplication.shared.mainMenu)).compactMap(\.action))

    let library = try SheetLibrary(root: root)
    var ids: [UUID] = []
    for state in [SheetState.active, .archived, .trashed] {
      let sheet = try library.save(source: "1", metadata: library.create(preferences: .standard))
      _ = try library.update(sheet.id) { $0.state = state }
      ids.append(sheet.id)
    }
    _ = try library.createFolder(named: "Travel")
    let workspace = Workspace(library: library)
    let controller = workspace.openWindow(showing: ids[0])
    defer { controller.window?.orderOut(nil) }
    let sidebar = controller.sidebar
    controller.window?.makeKeyAndOrderFront(nil)

    var contextActions: Set<Selector> = []
    for collection in [SheetCollection.all, .archive, .trash] {
      sidebar.show(collection)
      for row in sidebar.sheets.indices {
        sidebar.sheetsView.selectRowIndexes([row], byExtendingSelection: false)
        let menu = try #require(sidebar.sheetsView.menu)
        sidebar.menuNeedsUpdate(menu)
        contextActions.formUnion(items(in: menu).compactMap(\.action))
      }
    }
    let folder = try #require(sidebar.folders.first)
    sidebar.show(.folder(folder.id))
    let folderMenu = try #require(sidebar.collectionsView.menu)
    sidebar.menuNeedsUpdate(folderMenu)
    contextActions.formUnion(items(in: folderMenu).compactMap(\.action))
    #expect(contextActions.contains(#selector(WorkspaceCommands.deleteFolder(_:))))
    #expect(contextActions.contains(#selector(WorkspaceCommands.deleteSheetImmediately(_:))))

    // Menus filled when they open, such as Move to Folder, list the actions
    // for the key window's selected sheet.
    sidebar.show(.all)
    sidebar.sheetsView.selectRowIndexes([0], byExtendingSelection: false)
    var openedActions = mainActions
    for submenu in items(in: try #require(NSApplication.shared.mainMenu)).compactMap(\.submenu)
    where submenu.delegate != nil {
      submenu.delegate?.menuNeedsUpdate?(submenu)
      openedActions.formUnion(items(in: submenu).compactMap(\.action))
    }

    // The search field is reached with Search Sheets, which focuses it.
    let toolbarActions = Set(
      (controller.window?.toolbar?.items ?? []).filter { $0.itemIdentifier != .searchSheets }
        .compactMap(\.action))
    #expect(!contextActions.isEmpty)
    #expect(
      contextActions.subtracting(openedActions).isEmpty,
      "\(contextActions.subtracting(openedActions))")
    #expect(
      toolbarActions.subtracting(mainActions).isEmpty, "\(toolbarActions.subtracting(mainActions))")
  }

  /// Problems found in a view tree: controls under 20×20 points, text under
  /// 10 points, and image-only controls without an accessibility label.
  private func audit(_ view: NSView) -> [String] {
    var problems: [String] = []
    func visit(_ view: NSView) {
      guard !view.isHidden else {
        return
      }
      let name = String(describing: type(of: view))
      if view is NSButton || view is NSPopUpButton || view is NSSegmentedControl {
        if view.frame.width < 20 || view.frame.height < 20 {
          problems.append("\(name) is \(view.frame.size)")
        }
        let title = (view as? NSButton)?.title ?? ""
        if title.isEmpty, (view.accessibilityLabel() ?? "").isEmpty {
          problems.append("\(name) has no accessibility label")
        }
      }
      if let field = view as? NSTextField, let size = field.font?.pointSize, size < 10 {
        problems.append("\(name) \"\(field.stringValue)\" uses \(size) pt")
      }
      if let text = view as? NSTextView, let size = text.font?.pointSize, size < 10 {
        problems.append("\(name) uses \(size) pt")
      }
      view.subviews.forEach(visit)
    }
    visit(view)
    return problems
  }

  private func items(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(items(in:)) ?? []) }
  }
}
