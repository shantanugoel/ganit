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
  private var workspace: Workspace?

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

  /// Opens the library before AppKit restores windows that need it.
  func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      let root = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appending(
        path: Bundle.main.bundleIdentifier ?? "com.shantanugoel.Ganit", directoryHint: .isDirectory)
      workspace = Workspace(library: try SheetLibrary(root: root))
    } catch {
      NSApplication.shared.presentError(error)
      NSApplication.shared.terminate(nil)
    }
  }

  /// Opens the most recent sheet when no window was restored.
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let workspace, workspace.windows.isEmpty {
      let recent = try? workspace.library.index.summaries().first { $0.state == .active }
      if let recent {
        workspace.openWindow(showing: recent.id)
      } else {
        newSheet(nil)
      }
    }
    NSApplication.shared.activate()
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  /// Opens a window with a new sheet when no workspace window handles the
  /// command.
  @objc func newSheet(_ sender: Any?) {
    guard let workspace else {
      return
    }
    do {
      let metadata = try workspace.library.create(
        preferences: WorkspaceWindowController.newSheetPreferences)
      workspace.openWindow(showing: metadata.id)
    } catch {
      NSApplication.shared.presentError(error)
    }
  }
}
