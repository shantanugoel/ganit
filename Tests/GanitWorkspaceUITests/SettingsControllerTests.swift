import AppKit
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct SettingsControllerTests {
  @Test
  func togglingABoxReportsTheNewState() throws {
    var seen: [SettingsState] = []
    let start = SettingsState(
      staysInMenuBar: false,
      spotlightTitles: false,
      quickGanitStartsEmpty: false,
      automaticExchangeRates: true,
      automaticUpdates: false,
      completesWhileTyping: true
    )
    let settings = SettingsController(state: start) { seen.append($0) }
    settings.loadView()
    let autocomplete = try #require(
      settings.view.buttons.first { $0.title.contains("Autocomplete") })
    #expect(autocomplete.state == .on)
    autocomplete.performClick(nil)
    #expect(seen.last?.completesWhileTyping == false)
    let tour = try #require(settings.view.buttons.first { $0.title == "Show Tour" })
    #expect(tour.action == #selector(ApplicationCommands.showTour(_:)))
  }
}

extension NSView {
  fileprivate var buttons: [NSButton] {
    subviews.flatMap { view in
      [view as? NSButton].compactMap { $0 } + view.buttons
    }
  }
}
