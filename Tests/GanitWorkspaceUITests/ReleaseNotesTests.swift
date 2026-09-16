import AppKit
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct ReleaseNotesTests {
  @Test
  func windowShowsTheGivenChangelog() {
    let notes = ReleaseNotesWindowController(text: "# Changelog\n\n## 0.1.0\n\nFirst release.")
    #expect(notes.window?.title == "Release Notes")
    #expect(notes.displayedText.contains("First release."))
  }

  @Test
  func menuListsReleaseNotes() {
    let application = NSApplication.shared
    MainMenu.install(in: application)
    let items = (application.helpMenu?.items ?? [])
    #expect(items.contains { $0.action == #selector(ApplicationCommands.showReleaseNotes(_:)) })
  }
}
