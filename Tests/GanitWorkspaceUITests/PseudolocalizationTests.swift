import AppKit
import Foundation
import GanitDocuments
import GanitQuickUI
import Testing

@testable import GanitWorkspaceUI

/// Lays out windows with the system's double-length pseudolocalization and
/// fails on labels and buttons too narrow for their text.
///
/// Bundles cache localized strings, so this runs only in its own process:
/// `GANIT_PSEUDOLOCALIZATION=1 swift test --filter PseudolocalizationTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GANIT_PSEUDOLOCALIZATION"] == "1"))
struct PseudolocalizationTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitPseudolocalization-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  mutating func doubleLengthStringsFitWithoutClipping() throws {
    UserDefaults.standard.set(true, forKey: "NSDoubleLocalizedStrings")
    defer { UserDefaults.standard.removeObject(forKey: "NSDoubleLocalizedStrings") }
    #expect(localized("menu.newSheet", "New Sheet") == "New Sheet New Sheet")

    let library = try SheetLibrary(root: root)
    let sheet = try library.save(source: "1 + 1", metadata: library.create(preferences: .standard))
    let workspace = Workspace(library: library)
    let controller = workspace.openWindow(showing: sheet.id)
    defer { controller.window?.orderOut(nil) }

    let settings = ShortcutSettingsController(hotKey: GlobalHotKey {}, menu: nil) { _ in }
    let settingsWindow = NSWindow(contentViewController: settings)
    let quick = try QuickPanelController(context: SheetPreferences.standard.evaluationContext())

    for window in [controller.window, settingsWindow, quick.window].compactMap({ $0 }) {
      window.layoutIfNeeded()
      #expect(clipped(in: window.contentView!) == [], "\(type(of: window))")
    }
    #expect(checked > 0)
  }

  /// Labels and buttons, outside tables, whose text needs more width than
  /// they have and does not wrap.
  private var checked = 0

  private mutating func clipped(in view: NSView) -> [String] {
    var problems: [String] = []
    var count = 0
    func visit(_ view: NSView) {
      guard !view.isHidden, !(view is NSTableView) else {
        return
      }
      let field = view as? NSTextField
      let button = view as? NSButton
      let wraps = field.map { $0.isEditable || $0.cell?.wraps == true } ?? false
      if let control = field ?? button, !wraps {
        count += 1
        if control.fittingSize.width > control.frame.width + 0.5 {
          problems.append(field?.stringValue ?? button?.title ?? "")
        }
      }
      view.subviews.forEach(visit)
    }
    visit(view)
    checked += count
    return problems
  }
}
