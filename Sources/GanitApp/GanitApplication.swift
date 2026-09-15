import AppKit
import GanitDocuments
import GanitQuickUI
import GanitWorkspaceUI

#if !arch(arm64)
  #error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate, ApplicationCommands {
  private static let shortcutDefaultsKey = "QuickGanitShortcut"
  private static var retainedDelegate: GanitApplication?
  private var workspace: Workspace?
  private var quickPanel: QuickPanelController?
  private var shortcutWindow: NSWindow?
  private lazy var hotKey = GlobalHotKey { [weak self] in
    self?.toggleQuickGanit()
  }

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
    if let data = UserDefaults.standard.data(forKey: Self.shortcutDefaultsKey),
      let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    {
      try? hotKey.register(shortcut)
    }
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

  /// Imports sheets opened from Finder and shows each in a window.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let workspace else {
      return
    }
    for url in urls {
      do {
        workspace.openWindow(showing: try workspace.importSheet(from: url))
      } catch {
        application.presentError(error)
      }
    }
  }

  // MARK: Quick Ganit

  @objc func showQuickGanit(_ sender: Any?) {
    quickGanit()?.show()
  }

  @objc func showQuickGanitShortcut(_ sender: Any?) {
    if let shortcutWindow {
      shortcutWindow.makeKeyAndOrderFront(nil)
      return
    }
    let settings = ShortcutSettingsController(hotKey: hotKey, menu: NSApplication.shared.mainMenu) {
      shortcut in
      let defaults = UserDefaults.standard
      if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
        defaults.set(data, forKey: Self.shortcutDefaultsKey)
      } else {
        defaults.removeObject(forKey: Self.shortcutDefaultsKey)
      }
    }
    let window = NSWindow(contentViewController: settings)
    window.title = String(
      localized: "menu.quickGanitShortcut", defaultValue: "Quick Ganit Shortcut…", bundle: .main)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    shortcutWindow = window
  }

  private func toggleQuickGanit() {
    quickGanit()?.toggle()
  }

  /// The Quick Ganit panel, created on first use.
  private func quickGanit() -> QuickPanelController? {
    if quickPanel == nil {
      quickPanel = try? QuickPanelController(context: SheetPreferences.standard.evaluationContext())
    }
    return quickPanel
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
        preferences: SheetPreferences.standard)
      workspace.openWindow(showing: metadata.id)
    } catch {
      NSApplication.shared.presentError(error)
    }
  }
}
