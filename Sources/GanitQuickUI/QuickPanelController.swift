import AppKit
import GanitDocuments
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
  /// When true, the stored text is cleared and each showing starts empty.
  public var startsEmpty: Bool {
    didSet {
      if startsEmpty {
        try? store?.clear()
      }
    }
  }
  private let store: TextDocumentStore?

  /// Restores and keeps the buffer in `store` unless `startsEmpty` is true.
  public init(
    context: EvaluationContext,
    store: TextDocumentStore? = nil,
    startsEmpty: Bool = false
  ) {
    self.store = store
    self.startsEmpty = startsEmpty
    if startsEmpty {
      try? store?.clear()
    }
    editor = SheetEditorViewController(
      text: startsEmpty ? "" : store?.load() ?? "",
      context: context
    )
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
    panel.cancel = { [weak self] in self?.hide() }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveBuffer(_:)),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(otherWindowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )

    copyButton.title = Self.copyTitle
    copyButton.target = self
    copyButton.action = #selector(copyResultAndDismiss(_:))
    copyButton.toolTip = String(
      localized: "quick.copyResultHelp",
      defaultValue:
        "Copies the answer on the insertion point's line, or else the last answer, and closes Quick Ganit. Keep as Sheet saves all of the text as a new sheet instead.",
      bundle: .main)
    let keep = NSButton(
      title: String(localized: "quick.keepAsSheet", defaultValue: "Keep as Sheet", bundle: .main),
      target: self,
      action: #selector(keepAsSheet(_:))
    )
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .trailing
    accessory.view = NSView(frame: .zero)
    var x: CGFloat = 0
    for button in [copyButton, keep] {
      button.bezelStyle = .accessoryBarAction
      button.controlSize = .small
      button.setFrameSize(button.fittingSize)
      button.frame.origin = NSPoint(x: x, y: (28 - button.fittingSize.height) / 2)
      accessory.view.addSubview(button)
      x += button.fittingSize.width + 6
    }
    accessory.view.setFrameSize(NSSize(width: x + 6, height: 28))
    panel.addTitlebarAccessoryViewController(accessory)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public var isShown: Bool {
    window?.isVisible == true
  }

  /// The usable area of the display containing a point, such as the pointer.
  static func visibleFrame(
    containing point: NSPoint, screens: [(frame: NSRect, visibleFrame: NSRect)]
  ) -> NSRect? {
    screens.first { NSMouseInRect(point, $0.frame, false) }?.visibleFrame
  }

  /// A panel origin centered horizontally and above center in `visible`,
  /// kept inside it so the panel is never partly off a small display.
  static func origin(for size: NSSize, in visible: NSRect) -> NSPoint {
    let x = visible.midX - size.width / 2
    let y = visible.midY - size.height / 2 + visible.height / 6
    return NSPoint(
      x: max(visible.minX, min(x, visible.maxX - size.width)),
      y: max(visible.minY, min(y, visible.maxY - size.height))
    )
  }

  /// Shows the panel near the center of the screen with the pointer, focused
  /// on its text. Text kept from last time is selected, so typing replaces it
  /// rather than joining it.
  public func show() {
    guard let panel = window else {
      return
    }
    if startsEmpty, !panel.isVisible, !editor.textView.string.isEmpty {
      editor.textView.insertText(
        "",
        replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
      editor.documentUndoManager.removeAllActions()
    }
    let wasHidden = !panel.isVisible
    if wasHidden || !panel.isOnActiveSpace,
      let visible = Self.visibleFrame(
        containing: NSEvent.mouseLocation,
        screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
      ) ?? NSScreen.main?.visibleFrame
    {
      panel.setFrameOrigin(Self.origin(for: panel.frame.size, in: visible))
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(editor.textView)
    if wasHidden {
      editor.textView.selectAll(nil)
    }
  }

  /// Hides the panel, keeping its text for next time.
  public func hide() {
    window?.orderOut(nil)
    saveBuffer(nil)
  }

  public func windowDidResignKey(_ notification: Notification) {
    saveBuffer(nil)
  }

  /// Moving to one of Ganit's own windows hides the panel instead of leaving
  /// it floating over that window. Other apps never post this, so the panel
  /// still floats over them.
  @objc func otherWindowDidBecomeKey(_ notification: Notification) {
    guard isShown, let other = notification.object as? NSWindow, other !== window,
      !(other is NSPanel)
    else {
      return
    }
    hide()
  }

  /// Stores the buffer for the next launch unless the panel starts empty.
  @objc func saveBuffer(_ sender: Any?) {
    guard !startsEmpty else {
      return
    }
    try? store?.save(editor.textView.string)
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

  /// The button showing Command-Return's action, which also performs it.
  let copyButton = NSButton(title: "", target: nil, action: nil)
  static let copyTitle = String(
    localized: "quick.copyResult", defaultValue: "⌘↩ Copy Result and Close", bundle: .main)

  /// Copies the insertion point's result, or else the last result, and hides
  /// the panel. Without a result it beeps, says so on the button for a
  /// moment, and stays open.
  @objc func copyResultAndDismiss(_ sender: Any? = nil) {
    guard editor.copyCurrentOrLastResult() else {
      NSSound.beep()
      copyButton.title = String(
        localized: "quick.noResult", defaultValue: "No Result to Copy", bundle: .main)
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        self?.copyButton.title = Self.copyTitle
      }
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
  var cancel: () -> Void = {}

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
    cancel()
  }
}
