import AppKit

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

    let contentViewController = NSViewController()
    contentViewController.view = NSView()
    window.contentViewController = contentViewController

    super.init(window: window)
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }
}
