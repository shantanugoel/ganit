import AppKit
import GanitWorkspaceUI

#if !arch(arm64)
#error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: GanitApplication?
    private var workspaceWindowController: WorkspaceWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = GanitApplication()

        retainedDelegate = delegate
        application.delegate = delegate
        delegate.installMainMenu(on: application)
        application.setActivationPolicy(.regular)
        application.run()
        retainedDelegate = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowController = WorkspaceWindowController()
        workspaceWindowController = windowController
        windowController.showWindow(nil)
        NSApplication.shared.activate()
    }

    private func installMainMenu(on application: NSApplication) {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()

        applicationMenu.addItem(
            withTitle: String(
                localized: "menu.about",
                defaultValue: "About Ganit",
                bundle: .main
            ),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: String(
                localized: "menu.hide",
                defaultValue: "Hide Ganit",
                bundle: .main
            ),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: String(
                localized: "menu.quit",
                defaultValue: "Quit Ganit",
                bundle: .main
            ),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)
        application.mainMenu = mainMenu
    }
}
