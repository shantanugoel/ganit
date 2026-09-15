import AppKit

/// Records the Quick Ganit shortcut, shows its known conflicts, and saves or
/// removes it. There is no default shortcut; `⌥Space` is only suggested.
@MainActor
public final class ShortcutSettingsController: NSViewController {
  private let hotKey: GlobalHotKey
  private let commandMenu: NSMenu?
  private let didChange: (KeyboardShortcut?) -> Void
  private let recorder = ShortcutRecorder()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton()

  /// The shortcut shown in the recorder, not yet registered.
  public private(set) var candidate: KeyboardShortcut?

  public init(hotKey: GlobalHotKey, menu: NSMenu?, didChange: @escaping (KeyboardShortcut?) -> Void)
  {
    self.hotKey = hotKey
    commandMenu = menu
    self.didChange = didChange
    candidate = hotKey.shortcut ?? .suggested
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let explanation = NSTextField(
      wrappingLabelWithString: localized(
        "shortcut.explanation",
        "Choose a shortcut that opens Quick Ganit from any app. Click the field and press the keys, including at least one modifier."
      )
    )
    recorder.didRecord = { [weak self] shortcut in
      self?.select(shortcut)
    }
    status.textColor = .secondaryLabelColor
    saveButton.title = localized("shortcut.save", "Use Shortcut")
    saveButton.bezelStyle = .push
    saveButton.keyEquivalent = "\r"
    saveButton.target = self
    saveButton.action = #selector(save(_:))
    let remove = NSButton(
      title: localized("shortcut.remove", "No Shortcut"),
      target: self,
      action: #selector(remove(_:))
    )
    let buttons = NSStackView(views: [remove, saveButton])
    let stack = NSStackView(views: [explanation, recorder, status, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      recorder.widthAnchor.constraint(equalToConstant: 180),
      explanation.widthAnchor.constraint(equalToConstant: 380),
      status.widthAnchor.constraint(equalToConstant: 380),
    ])
    view = container
    select(candidate)
  }

  /// Shows a recorded shortcut with its conflicts; nothing is registered yet.
  func select(_ shortcut: KeyboardShortcut?) {
    candidate = shortcut
    recorder.shortcut = shortcut
    guard let shortcut else {
      status.stringValue = localized(
        "shortcut.none", "Quick Ganit stays available from the Window menu.")
      return
    }
    let messages = shortcut.conflicts(in: commandMenu).map { conflict in
      switch conflict {
      case .system:
        return localized(
          "shortcut.conflict.system", "macOS uses this shortcut, so it may not reach Ganit.")
      case .menu(let title):
        return String(
          format: localized("shortcut.conflict.menu", "Ganit's “%@” command uses this shortcut."),
          title
        )
      case .otherApplication:
        return localized("shortcut.conflict.other", "Another app is already using this shortcut.")
      }
    }
    status.stringValue =
      messages.isEmpty
      ? localized("shortcut.noConflicts", "No known conflicts.") : messages.joined(separator: " ")
  }

  @objc func save(_ sender: Any?) {
    guard let candidate else {
      return remove(sender)
    }
    do {
      try hotKey.register(candidate)
      didChange(candidate)
      view.window?.sheetParent?.endSheet(view.window!)
      view.window?.close()
    } catch {
      status.stringValue = localized(
        "shortcut.conflict.other", "Another app is already using this shortcut.")
    }
  }

  @objc func remove(_ sender: Any?) {
    hotKey.unregister()
    didChange(nil)
    view.window?.close()
  }
}

/// A field that records the next key combination pressed while focused.
final class ShortcutRecorder: NSButton {
  var didRecord: (KeyboardShortcut) -> Void = { _ in }
  var shortcut: KeyboardShortcut? {
    didSet {
      title = shortcut?.displayName ?? localized("shortcut.record", "Record Shortcut")
      setAccessibilityValue(title)
    }
  }

  convenience init() {
    self.init(frame: .zero)
    bezelStyle = .push
    setButtonType(.pushOnPushOff)
    setAccessibilityLabel(localized("shortcut.recorder", "Quick Ganit shortcut"))
    title = localized("shortcut.record", "Record Shortcut")
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, let recorded = KeyboardShortcut(event: event) else {
      return super.performKeyEquivalent(with: event)
    }
    didRecord(recorded)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard let recorded = KeyboardShortcut(event: event) else {
      super.keyDown(with: event)
      return
    }
    didRecord(recorded)
  }
}

func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
