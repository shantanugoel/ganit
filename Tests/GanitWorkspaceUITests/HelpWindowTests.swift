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
  func opensWideEnoughToReadTheTopicBesideTheList() throws {
    let help = HelpWindowController()
    let window = try #require(help.window)
    #expect(window.contentLayoutRect.width >= 700)
    #expect(window.contentLayoutRect.height >= 460)
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

  @Test
  func listSitsBesideTheReadingAndSelectionShowsTheTopic() throws {
    let help = HelpWindowController()
    let window = try #require(help.window)
    help.show()
    window.setContentSize(NSSize(width: 720, height: 500))
    window.layoutIfNeeded()
    help.reveal("function.round")
    window.layoutIfNeeded()
    defer { window.orderOut(nil) }
    #expect(help.selectedTopic?.id == "function.round")

    let content = try #require(window.contentView)
    let split = try #require(first(NSSplitView.self, in: content))
    #expect(split.isVertical)
    #expect(split.subviews.count == 2)
    let list = split.subviews[0].frame
    let reading = split.subviews[1].frame
    #expect(list.minX < reading.minX)
    #expect(list.width >= 180)
    #expect(reading.width > 200)
    let text = try #require(first(NSTextView.self, in: split.subviews[1]))
    #expect(text.string.localizedCaseInsensitiveContains("round"))
    let wrapped = try #require(text.textContainer?.containerSize.width)
    #expect(wrapped > 200)
    #expect(wrapped < .greatestFiniteMagnitude / 2)
  }
}

@MainActor
private func first<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
  if let view = root as? View {
    return view
  }
  for child in root.subviews {
    if let view = first(type, in: child) {
      return view
    }
  }
  return nil
}
