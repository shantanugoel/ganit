import AppKit
import GanitDocuments
import GanitEditorUI
import GanitEngine

/// A window editing one library sheet, saved as it changes.
@MainActor
public final class WorkspaceWindowController: NSWindowController {
  /// Preferences for new sheets until sheet preference settings exist.
  public static let newSheetPreferences = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .radians,
    significantDecimalDigits: 15
  )

  public let editor: SheetEditorViewController
  private let library: SheetLibrary
  private var autosaver: SheetAutosaver!

  public var sheetID: UUID {
    autosaver.metadata.id
  }

  public init(library: SheetLibrary, sheet: StoredSheet) throws {
    self.library = library
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.minSize = NSSize(width: 640, height: 400)
    window.tabbingMode = .preferred
    window.isReleasedWhenClosed = false
    editor = SheetEditorViewController(
      text: sheet.source,
      context: try Self.context(for: sheet.metadata.preferences)
    )
    window.contentViewController = editor
    super.init(window: window)

    autosaver = SheetAutosaver(
      library: library,
      metadata: sheet.metadata,
      source: { [editor] in editor.sheet.text },
      didSave: { [weak self] _ in self?.updateTitle() },
      didFail: { [weak window] error in window?.presentError(error) }
    )
    editor.sourceDidChange = { [weak self] in
      self?.autosaver.sourceDidChange()
    }
    updateTitle()
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(saveNow(_:)),
        name: name,
        object: window
      )
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveNow(_:)),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  /// Saves unsaved edits immediately.
  @objc public func saveNow(_ sender: Any?) {
    autosaver.saveNow()
  }

  /// Offers the sheet's daily backups and restores the chosen one.
  @objc public func restorePreviousVersion(_ sender: Any?) {
    guard let window else {
      return
    }
    saveNow(nil)
    let backups: [SheetBackup]
    do {
      backups = try library.backups(of: sheetID)
    } catch {
      window.presentError(error)
      return
    }
    let alert = NSAlert()
    guard !backups.isEmpty else {
      alert.messageText = localized("restore.none", "There are no previous versions of this sheet.")
      alert.beginSheetModal(for: window)
      return
    }
    alert.messageText = localized("restore.title", "Restore a previous version?")
    alert.informativeText = localized(
      "restore.message",
      "The sheet is replaced with its contents from before the first change on the chosen day. You can undo this."
    )
    let days = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
    days.addItems(withTitles: backups.map(\.day))
    alert.accessoryView = days
    alert.addButton(withTitle: localized("restore.confirm", "Restore"))
    alert.addButton(withTitle: localized("restore.cancel", "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      self?.restore(backups[days.indexOfSelectedItem])
    }
  }

  /// Replaces the editor's text with a backup as one undoable edit, which is
  /// then saved.
  func restore(_ backup: SheetBackup) {
    do {
      let source = try library.load(backup).source
      let textView = editor.textView
      textView.insertText(
        source, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
      )
      textView.undoManager?.setActionName(localized("restore.undo", "Restore Previous Version"))
      saveNow(nil)
    } catch {
      window?.presentError(error)
    }
  }

  private func updateTitle() {
    let title = autosaver.metadata.title
    window?.title = title.isEmpty ? localized("sheet.untitled", "Untitled") : title
  }

  private static func context(for preferences: SheetPreferences) throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: preferences.localeIdentifier,
      // English grammar with `en-US` separators is the only lexing syntax so far.
      lexingConfiguration: .englishUnitedStates,
      angleMode: preferences.angleMode,
      precision: PrecisionContext(significantDecimalDigits: preferences.significantDecimalDigits),
      now: Date(),
      calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: TimeZone.current.identifier) ?? .gmt
    )
  }
}

private func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
