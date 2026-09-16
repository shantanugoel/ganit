import AppKit
import GanitEditorUI

/// The changelog, shown as a readable window from Help ▸ Release Notes.
@MainActor
public final class ReleaseNotesWindowController: NSWindowController {
  public convenience init(text: String) {
    let view = NSTextView()
    view.string = text
    view.isEditable = false
    view.isRichText = false
    view.drawsBackground = false
    view.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    view.textColor = VisualStyle.Color.primary
    view.textContainerInset = NSSize(
      width: VisualStyle.Spacing.standard, height: VisualStyle.Spacing.standard)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = localized("menu.releaseNotes", "Release Notes")
    window.contentMinSize = NSSize(width: 360, height: 240)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.center()
    self.init(window: window)
  }

  /// The text the window is showing, for tests.
  public var displayedText: String {
    ((window?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
  }

  /// The changelog shipped in the app, or `nil` when it is missing.
  public static func text(in bundle: Bundle) -> String? {
    guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
