import AppKit
import GanitDocuments
import GanitQuickUI
import GanitWorkspaceUI

#if !arch(arm64)
  #error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate, ApplicationCommands,
  NSMenuItemValidation
{
  private static let shortcutDefaultsKey = "QuickGanitShortcut"
  private static let startsEmptyDefaultsKey = "QuickGanitStartsEmpty"
  private static var retainedDelegate: GanitApplication?
  private var workspace: Workspace?
  private var quickPanel: QuickPanelController?
  private var quickBufferStore: QuickBufferStore?
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
      quickBufferStore = QuickBufferStore(url: root.appending(path: "QuickBuffer.txt"))
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
    if workspace?.windows.isEmpty == true {
      openMostRecentSheet()
    }
    NSApplication.shared.activate()
  }

  /// Ganit keeps running without windows so Quick Ganit's shortcut works.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Clicking the Dock icon without workspace windows opens the most recent
  /// sheet.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if workspace?.windows.isEmpty == true {
      openMostRecentSheet()
    }
    return true
  }

  private func openMostRecentSheet() {
    do {
      try workspace?.openMostRecentSheet()
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  /// Opens a window with a new sheet when no workspace window handles the
  /// command.
  @objc func newSheet(_ sender: Any?) {
    do {
      try workspace?.openNewSheet(source: "")
    } catch {
      NSApplication.shared.presentError(error)
    }
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

  /// Chooses whether Quick Ganit restores its last text or starts empty.
  @objc func toggleQuickGanitStartsEmpty(_ sender: Any?) {
    let startsEmpty = !UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)
    UserDefaults.standard.set(startsEmpty, forKey: Self.startsEmptyDefaultsKey)
    if let quickPanel {
      quickPanel.startsEmpty = startsEmpty
    } else if startsEmpty {
      try? quickBufferStore?.clear()
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleQuickGanitStartsEmpty(_:)) {
      menuItem.state = UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey) ? .on : .off
    }
    return true
  }

  private func toggleQuickGanit() {
    quickGanit()?.toggle()
  }

  /// The Quick Ganit panel, created on first use.
  private func quickGanit() -> QuickPanelController? {
    if quickPanel == nil {
      quickPanel = try? QuickPanelController(
        context: SheetPreferences.standard.evaluationContext(),
        store: quickBufferStore,
        startsEmpty: UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)
      )
      quickPanel?.promote = { [weak self] source in
        try self?.workspace?.openNewSheet(source: source)
        NSApplication.shared.activate()
      }
    }
    return quickPanel
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }
}
