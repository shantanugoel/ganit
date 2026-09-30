import AppKit

/// A feature-specific announcement, shown once even across later releases.
@MainActor
public final class ReferenceFeatureAnnouncement {
  public static let seenKey = "HasSeenReferencePicker"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var shouldShow: Bool {
    !defaults.bool(forKey: Self.seenKey)
  }

  public func show(in window: NSWindow) {
    guard shouldShow, window.isVisible, window.attachedSheet == nil else { return }
    let alert = Self.alert()
    alert.beginSheetModal(for: window)
    defaults.set(true, forKey: Self.seenKey)
  }

  static func alert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = localized("references.new.title", "New: quick references with @")
    alert.informativeText = localized(
      "references.new.body",
      "Type @ to choose a variable or an earlier line’s answer. Type @rent to find rent, or use @6 instead of line 6. Press Tab or Return to choose. Variable names stay plain, and line references follow edits. New sheets show line numbers; View ▸ Show Line Numbers controls them."
    )
    alert.addButton(withTitle: localized("references.new.done", "Got it"))
    return alert
  }
}
