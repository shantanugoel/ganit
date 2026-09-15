import AppKit
import GanitDocuments
import GanitWorkspaceUI

#if !arch(arm64)
  #error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate {
  private static var retainedDelegate: GanitApplication?
  private var library: SheetLibrary?
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
    do {
      let root = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appending(
        path: Bundle.main.bundleIdentifier ?? "com.shantanugoel.Ganit", directoryHint: .isDirectory)
      let library = try SheetLibrary(root: root)
      self.library = library
      if let recent = try library.index.summaries().first(where: { $0.state == .active }) {
        try open(library.store.load(id: recent.id))
      } else {
        newSheet(nil)
      }
    } catch {
      NSApplication.shared.presentError(error)
      NSApplication.shared.terminate(nil)
    }
    NSApplication.shared.activate()
  }

  @objc func newSheet(_ sender: Any?) {
    guard let library else {
      return
    }
    do {
      let metadata = try library.create(preferences: WorkspaceWindowController.newSheetPreferences)
      try open(library.store.load(id: metadata.id))
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  private func open(_ sheet: StoredSheet) throws {
    guard let library else {
      return
    }
    let windowController = try WorkspaceWindowController(library: library, sheet: sheet)
    workspaceWindowControllers.append(windowController)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: windowController.window
    )
    windowController.showWindow(nil)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    workspaceWindowControllers.removeAll { $0.window === notification.object as? NSWindow }
  }
}
