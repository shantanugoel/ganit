import AppKit
import GanitWorkspaceUI

#if !arch(arm64)
  #error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate, WorkspaceCommands {
  private static var retainedDelegate: GanitApplication?
  private var workspaceWindowControllers: [WorkspaceWindowController] = []

  static func main() {
    let application = NSApplication.shared
    let delegate = GanitApplication()

    retainedDelegate = delegate
    application.delegate = delegate
    MainMenu.install(in: application)
    application.setActivationPolicy(.regular)
    application.run()
    retainedDelegate = nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    newSheet(nil)
    NSApplication.shared.activate()
  }

  func newSheet(_ sender: Any?) {
    let windowController = WorkspaceWindowController()
    workspaceWindowControllers.append(windowController)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: windowController.window
    )
    windowController.showWindow(sender)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    workspaceWindowControllers.removeAll { $0.window === notification.object as? NSWindow }
  }
}
