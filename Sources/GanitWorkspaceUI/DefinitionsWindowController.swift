import AppKit
import GanitDocuments
import GanitEditorUI
import GanitEngine

/// The definitions sheet's window.
///
/// The definitions sheet is one text document, not a library sheet: it is not
/// listed, searched, or exported, because it is the vocabulary every sheet
/// reads rather than a calculation of its own. Its text is saved when the
/// window stops being the key window, when it closes, and when Ganit quits,
/// so a sheet never reads definitions that are gone.
@MainActor
final class DefinitionsWindowController: NSWindowController, NSWindowDelegate {
  let editor: SheetEditorViewController
  private let store: TextDocumentStore

  init(store: TextDocumentStore, editor: SheetEditorViewController) {
    self.store = store
    self.editor = editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentMinSize = NSSize(width: 320, height: 200)
    window.title = localized("definitions.title", "Definitions")
    window.contentViewController = editor
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    super.init(window: window)
    window.delegate = self
    window.center()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(save(_:)),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  @objc private func save(_ sender: Any?) {
    try? store.save(editor.textView.string)
  }

  func windowDidResignKey(_ notification: Notification) {
    save(nil)
  }

  func windowWillClose(_ notification: Notification) {
    save(nil)
  }
}
