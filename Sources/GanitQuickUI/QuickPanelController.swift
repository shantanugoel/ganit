import AppKit
import GanitEditorUI
import GanitEngine

/// Quick Ganit: a standard floating panel with a disposable multiline sheet.
///
/// The panel is titled, resizable, and non-activating, so it takes keyboard
/// focus over the frontmost app without bringing Ganit's windows forward.
/// Hiding it keeps its text.
@MainActor
public final class QuickPanelController: NSWindowController, NSWindowDelegate {
  public let editor: SheetEditorViewController

  public init(context: EvaluationContext) {
    editor = SheetEditorViewController(context: context)
    let panel = QuickPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = String(localized: "quick.title", defaultValue: "Quick Ganit", bundle: .main)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.contentMinSize = NSSize(width: 320, height: 120)
    panel.contentViewController = editor
    panel.setAccessibilityLabel(panel.title)
    super.init(window: panel)
    panel.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public var isShown: Bool {
    window?.isVisible == true
  }

  /// Shows the panel near the center of the screen with the pointer, focused
  /// on its text.
  public func show() {
    guard let panel = window else {
      return
    }
    if !panel.isVisible {
      let screen =
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        ?? NSScreen.main
      if let visible = screen?.visibleFrame {
        panel.setFrameOrigin(
          NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2 + visible.height / 6
          )
        )
      }
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(editor.textView)
  }

  /// Hides the panel, keeping its text for next time.
  public func hide() {
    window?.orderOut(nil)
  }

  public func toggle() {
    if isShown && window?.isKeyWindow == true {
      hide()
    } else {
      show()
    }
  }

  @objc public func cancel(_ sender: Any?) {
    hide()
  }
}

/// A panel that can take key focus and hides on Escape instead of closing.
private final class QuickPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override func cancelOperation(_ sender: Any?) {
    orderOut(sender)
  }
}
