import AppKit
import GanitFormatting
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct HelpWindowTests {
  @Test
  func searchFiltersToMatchingFunction() {
    let help = HelpWindowController()
    help.search(for: "sqrt")
    #expect(help.selectedTopic?.title == "sqrt")
    help.search(for: "no-such-topic")
    #expect(help.selectedTopic == nil)
  }

  @Test
  func revealSelectsANamedTopic() {
    let help = HelpWindowController()
    help.reveal("function.round")
    #expect(help.selectedTopic?.id == "function.round")
    help.search(for: "sqrt")
    help.reveal("grammar.money")
    #expect(help.selectedTopic?.id == "grammar.money")
  }
}
