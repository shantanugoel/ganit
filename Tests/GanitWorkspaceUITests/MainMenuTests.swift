import AppKit
import GanitEditorUI
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct MainMenuTests {
  @Test
  func installsStandardAndSheetCommandsWithUniqueShortcuts() throws {
    let application = NSApplication.shared
    MainMenu.install(in: application)
    let main = try #require(application.mainMenu)
    let items = allItems(in: main)

    #expect(
      main.items.compactMap(\.submenu?.title).dropFirst() == [
        "File", "Edit", "Calculate", "Format", "View", "Window", "Help",
      ])
    #expect(application.windowsMenu?.title == "Window")
    #expect(application.helpMenu?.title == "Help")
    #expect(application.servicesMenu == nil)
    #expect(items.filter { $0.action == #selector(WorkspaceCommands.printSheet(_:)) }.count == 1)
    #expect(!items.contains { $0.action == #selector(NSView.printView(_:)) })
    #expect(!items.contains { $0.title == "Services" })
    let ganitHelp = items.first { $0.action == #selector(ApplicationCommands.showHelp(_:)) }
    #expect(ganitHelp?.title == "Ganit Help")
    #expect(ganitHelp?.keyEquivalent == "?")
    #expect(items.contains { $0.action == #selector(ApplicationCommands.showAbout(_:)) })
    #expect(items.contains { $0.action == #selector(ApplicationCommands.showSettings(_:)) })
    #expect(items.contains { $0.action == #selector(ApplicationCommands.showTour(_:)) })
    #expect(items.contains { $0.action == #selector(ApplicationCommands.toggleAutocomplete(_:)) })

    let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
      (#selector(WorkspaceCommands.newSheet(_:)), "n", .command),
      (#selector(WorkspaceCommands.importSheets(_:)), "o", [.command, .shift]),
      (#selector(WorkspaceCommands.exportSheet(_:)), "e", [.command, .shift]),
      (#selector(WorkspaceCommands.restorePreviousVersion(_:)), "", .command),
      (#selector(NSWindow.performClose(_:)), "w", .command),
      (Selector(("undo:")), "z", .command),
      (Selector(("redo:")), "z", [.command, .shift]),
      (#selector(NSText.copy(_:)), "c", .command),
      (#selector(SheetCommands.copyResult(_:)), "c", [.command, .shift]),
      (#selector(SheetCommands.copyFullPrecision(_:)), "c", [.command, .shift, .option]),
      (#selector(SheetCommands.insertReference(_:)), "\\", .command),
      (#selector(SheetCommands.insertSubtotal(_:)), "t", .command),
      (#selector(SheetCommands.recalculate(_:)), "r", .command),
      (#selector(SheetCommands.toggleComment(_:)), "/", .command),
    ]
    for (action, key, modifiers) in expected {
      let item = items.first { $0.action == action }
      #expect(item?.keyEquivalent == key, "\(action)")
      #expect(item?.keyEquivalentModifierMask == modifiers, "\(action)")
    }
    let find = items.first {
      $0.action == #selector(NSResponder.performTextFinderAction(_:))
        && $0.tag == NSTextFinder.Action.showFindInterface.rawValue
    }
    #expect(find?.keyEquivalent == "f")

    let shortcuts = items.filter { !$0.keyEquivalent.isEmpty }.map {
      "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)"
    }
    #expect(Set(shortcuts).count == shortcuts.count)
  }

  private func allItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
  }
}
