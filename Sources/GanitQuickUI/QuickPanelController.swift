import AppKit
import GanitEditorUI
import GanitEngine

/// Quick Ganit: a standard floating panel with a disposable multiline sheet.
///
/// The panel is titled, resizable, and non-activating, so it takes keyboard
/// focus over the frontmost app without activating Ganit or bringing its
/// windows forward, and focus returns to that app when it hides. It opens on
/// the active Space, including over full-screen apps, on the screen with the
/// pointer. Hiding it keeps its text.
@MainActor
public final class QuickPanelController: NSWindowController, NSWindowDelegate {
  public let editor: SheetEditorViewController
  /// Keeps the buffer as a new sheet; the app provides it.
  public var promote: (String) throws -> Void = { _ in }

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
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.contentMinSize = NSSize(width: 320, height: 120)
    panel.contentViewController = editor
    panel.setAccessibilityLabel(panel.title)
    super.init(window: panel)
    panel.delegate = self
    panel.commandReturn = { [weak self] in self?.copyResultAndDismiss() }

    let keep = NSButton(
      title: String(localized: "quick.keepAsSheet", defaultValue: "Keep as Sheet", bundle: .main),
      target: self,
      action: #selector(keepAsSheet(_:))
    )
    keep.bezelStyle = .accessoryBarAction
    keep.controlSize = .small
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .trailing
    accessory.view = NSView(
      frame: NSRect(x: 0, y: 0, width: keep.fittingSize.width + 12, height: 28))
    keep.frame.origin = NSPoint(x: 0, y: (28 - keep.fittingSize.height) / 2)
    keep.setFrameSize(keep.fittingSize)
    accessory.view.addSubview(keep)
    panel.addTitlebarAccessoryViewController(accessory)
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
    if !panel.isVisible || !panel.isOnActiveSpace {
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

  /// Copies the insertion point's result, or else the last result, and hides
  /// the panel. Without a result it beeps and stays open.
  func copyResultAndDismiss() {
    guard editor.copyCurrentOrLastResult() else {
      NSSound.beep()
      return
    }
    hide()
  }

  /// Saves the buffer as a new sheet, then clears the buffer and hides.
  @objc public func keepAsSheet(_ sender: Any?) {
    let text = editor.textView.string
    guard !text.isEmpty else {
      NSSound.beep()
      return
    }
    do {
      try promote(text)
      editor.textView.insertText(
        "", replacementRange: NSRange(location: 0, length: (text as NSString).length))
      editor.documentUndoManager.removeAllActions()
      hide()
    } catch {
      window?.presentError(error)
    }
  }
}

/// A panel that can take key focus, hides on Escape instead of closing, and
/// routes Command-Return to copy-and-dismiss before the text view sees it.
private final class QuickPanel: NSPanel {
  var commandReturn: () -> Void = {}

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "\r"
    {
      commandReturn()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override var canBecomeKey: Bool {
    true
  }

  override func cancelOperation(_ sender: Any?) {
    orderOut(sender)
  }
}
