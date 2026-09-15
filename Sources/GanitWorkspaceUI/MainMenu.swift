import AppKit
import GanitEditorUI

/// Application-level actions handled by the application delegate.
@MainActor
@objc public protocol WorkspaceCommands {
  func newSheet(_ sender: Any?)
}

/// The standard main menu. It lists only commands that exist, with
/// conventional titles, shortcuts, and responder-chain actions.
@MainActor
public enum MainMenu {
  public static func install(in application: NSApplication) {
    let services = NSMenu(title: localized("menu.services", "Services"))
    let window = menu(
      localized("menu.window", "Window"),
      [
        item(
          localized("menu.minimize", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(localized("menu.zoom", "Zoom"), #selector(NSWindow.performZoom(_:))),
        .separator(),
        item(
          localized("menu.bringAllToFront", "Bring All to Front"),
          #selector(NSApplication.arrangeInFront(_:))),
      ]
    )
    let help = menu(localized("menu.help", "Help"), [])

    let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    let main = NSMenu()
    for submenu in [
      menu(
        "Ganit",
        [
          item(
            localized("menu.about", "About Ganit"),
            #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
          .separator(),
          servicesItem,
          .separator(),
          item(localized("menu.hide", "Hide Ganit"), #selector(NSApplication.hide(_:)), "h"),
          item(
            localized("menu.hideOthers", "Hide Others"),
            #selector(NSApplication.hideOtherApplications(_:)),
            "h",
            [.command, .option]
          ),
          item(
            localized("menu.showAll", "Show All"),
            #selector(NSApplication.unhideAllApplications(_:))),
          .separator(),
          item(localized("menu.quit", "Quit Ganit"), #selector(NSApplication.terminate(_:)), "q"),
        ]
      ),
      menu(
        localized("menu.file", "File"),
        [
          item(
            localized("menu.newSheet", "New Sheet"), #selector(WorkspaceCommands.newSheet(_:)), "n"),
          .separator(),
          item(localized("menu.close", "Close"), #selector(NSWindow.performClose(_:)), "w"),
          .separator(),
          item(localized("menu.print", "Print…"), #selector(NSView.printView(_:)), "p"),
        ]
      ),
      menu(
        localized("menu.edit", "Edit"),
        [
          item(localized("menu.undo", "Undo"), Selector(("undo:")), "z"),
          item(localized("menu.redo", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
          .separator(),
          item(localized("menu.cut", "Cut"), #selector(NSText.cut(_:)), "x"),
          item(localized("menu.copy", "Copy"), #selector(NSText.copy(_:)), "c"),
          item(localized("menu.paste", "Paste"), #selector(NSText.paste(_:)), "v"),
          item(localized("menu.delete", "Delete"), #selector(NSText.delete(_:))),
          item(localized("menu.selectAll", "Select All"), #selector(NSText.selectAll(_:)), "a"),
          .separator(),
          submenuItem(
            localized("menu.find", "Find"),
            [
              finder(localized("menu.findEllipsis", "Find…"), .showFindInterface, "f"),
              finder(
                localized("menu.findAndReplace", "Find and Replace…"),
                .showReplaceInterface,
                "f",
                [.command, .option]
              ),
              finder(localized("menu.findNext", "Find Next"), .nextMatch, "g"),
              finder(
                localized("menu.findPrevious", "Find Previous"), .previousMatch, "g",
                [.command, .shift]),
              finder(
                localized("menu.useSelectionForFind", "Use Selection for Find"), .setSearchString,
                "e"),
            ]
          ),
        ]
      ),
      menu(
        localized("menu.calculate", "Calculate"),
        [
          item(
            localized("menu.copyResult", "Copy Result"),
            #selector(SheetCommands.copyResult(_:)),
            "c",
            [.command, .shift]
          ),
          item(
            localized("menu.copyFullPrecision", "Copy Full Precision"),
            #selector(SheetCommands.copyFullPrecision(_:)),
            "c",
            [.command, .shift, .option]
          ),
          item(
            localized("menu.showInterpretation", "Show Interpretation"),
            #selector(SheetCommands.showInterpretation(_:))
          ),
          .separator(),
          item(
            localized("menu.insertReference", "Insert Reference"),
            #selector(SheetCommands.insertReference(_:)), "\\"),
          item(
            localized("menu.insertSubtotal", "Insert Subtotal"),
            #selector(SheetCommands.insertSubtotal(_:)), "t"),
          .separator(),
          item(
            localized("menu.recalculate", "Recalculate"), #selector(SheetCommands.recalculate(_:)),
            "r"),
          item(localized("menu.stop", "Stop"), #selector(SheetCommands.stopCalculation(_:)), "."),
        ]
      ),
      menu(
        localized("menu.format", "Format"),
        [
          item(localized("menu.heading", "Heading"), #selector(SheetCommands.toggleHeading(_:))),
          item(
            localized("menu.comment", "Comment"), #selector(SheetCommands.toggleComment(_:)), "/"),
          item(localized("menu.divider", "Divider"), #selector(SheetCommands.insertDivider(_:))),
        ]
      ),
      menu(
        localized("menu.view", "View"),
        [
          item(
            localized("menu.enterFullScreen", "Enter Full Screen"),
            #selector(NSWindow.toggleFullScreen(_:)),
            "f",
            [.command, .control]
          )
        ]
      ),
      window,
      help,
    ] {
      let menuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
      menuItem.submenu = submenu
      main.addItem(menuItem)
    }

    application.mainMenu = main
    application.servicesMenu = services
    application.windowsMenu = window
    application.helpMenu = help
  }

  private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    return menu
  }

  private static func submenuItem(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu(title, items)
    return item
  }

  private static func item(
    _ title: String,
    _ action: Selector,
    _ key: String = "",
    _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  private static func finder(
    _ title: String,
    _ action: NSTextFinder.Action,
    _ key: String,
    _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
    item.tag = action.rawValue
    return item
  }
}

private func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
