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
      completesWhileTyping: true,
      appearance: .system,
      opensAtLogin: false,
      startsInMenuBar: false
    )
    let settings = SettingsController(state: start) { seen.append($0) }
    settings.loadView()
    let autocomplete = try #require(
      settings.view.buttons.first { $0.title.contains("Autocomplete") })
    #expect(autocomplete.state == .on)
    autocomplete.performClick(nil)
    #expect(seen.last?.completesWhileTyping == false)
    let tour = try #require(settings.view.buttons.first { $0.title == "Show Tour" })
    let login = try #require(settings.view.buttons.first { $0.title.contains("login") })
    login.performClick(nil)
    #expect(seen.last?.opensAtLogin == true)
    let startsHidden = try #require(settings.view.buttons.first { $0.title.contains("without") })
    #expect(!startsHidden.isEnabled)
    let menuBar = try #require(settings.view.buttons.first { $0.title.contains("Stay in") })
    menuBar.performClick(nil)
    #expect(startsHidden.isEnabled)
    startsHidden.performClick(nil)
    #expect(seen.last?.startsInMenuBar == true)
    let appearance = try #require(settings.view.popUpButtons.first)
    #expect(appearance.titleOfSelectedItem == "System")
    appearance.selectItem(withTitle: "Dark")
    _ = appearance.target?.perform(appearance.action, with: appearance)
    #expect(seen.last?.appearance == .dark)
    #expect(AppearanceChoice.dark.appearance?.name == .darkAqua)
    #expect(AppearanceChoice.system.appearance == nil)
    #expect(tour.action == #selector(ApplicationCommands.showTour(_:)))
  }
}

extension NSView {
  fileprivate var popUpButtons: [NSPopUpButton] {
    buttons.compactMap { $0 as? NSPopUpButton }
  }

  fileprivate var buttons: [NSButton] {
    subviews.flatMap { view in
      [view as? NSButton].compactMap { $0 } + view.buttons
    }
  }
}
