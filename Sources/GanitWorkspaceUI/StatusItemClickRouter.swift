import AppKit

/// Decides what a click on the menu bar icon does: a double-click opens the
/// window, and a single click or a right-click opens the menu.
///
/// A menu that opens on the first click would take the second click, so a
/// single click waits for the system double-click interval before it opens
/// the menu. A second click in that time cancels the wait and opens the
/// window. A right-click or a control-click opens the menu at once, because
/// it cannot start a double-click.
@MainActor
public final class StatusItemClickRouter {
  private let doubleClickInterval: Duration
  private let showWindow: () -> Void
  private let showMenu: () -> Void
  private var pendingMenu: Task<Void, Never>?

  public init(
    doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval,
    showWindow: @escaping () -> Void,
    showMenu: @escaping () -> Void
  ) {
    self.doubleClickInterval = .seconds(doubleClickInterval)
    self.showWindow = showWindow
    self.showMenu = showMenu
  }

  /// Handles the mouse-up of a click on the icon.
  public func click(count: Int, opensMenuAtOnce: Bool) {
    pendingMenu?.cancel()
    pendingMenu = nil
    if opensMenuAtOnce {
      showMenu()
    } else if count >= 2 {
      showWindow()
    } else {
      let interval = doubleClickInterval
      pendingMenu = Task { [weak self] in
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else {
          return
        }
        self?.pendingMenu = nil
        self?.showMenu()
      }
    }
  }

  /// Drops a waiting single click, as when the icon goes away.
  public func cancel() {
    pendingMenu?.cancel()
    pendingMenu = nil
  }
}
