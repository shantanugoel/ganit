import AppKit
import GanitEditorUI
import GanitEngine

@MainActor
public final class WorkspaceWindowController: NSWindowController {
  public init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Ganit"
    window.minSize = NSSize(width: 640, height: 400)
    window.tabbingMode = .preferred
    window.isReleasedWhenClosed = false

    window.contentViewController = SheetEditorViewController(context: Self.newSheetContext())

    super.init(window: window)
    window.center()
  }

  /// New sheets parse the English grammar in `en-US` until sheet locale
  /// preferences exist, with the user's current time zone.
  static func newSheetContext() -> EvaluationContext {
    let timeZone = TimeZone(identifier: TimeZone.current.identifier) ?? .gmt
    // Every argument is a valid constant, so construction cannot fail.
    return try! EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(),
      calendar: Calendar(identifier: .gregorian),
      timeZone: timeZone
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }
}
