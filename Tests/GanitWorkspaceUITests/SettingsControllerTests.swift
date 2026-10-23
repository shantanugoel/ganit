import AppKit
import GanitData
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
    let assistant = AssistantSettingsController(settings: AssistantSettings()) { _ in }
    let dialog = SettingsDialogController(general: settings, assistant: assistant)
    _ = dialog.view
    #expect(dialog.tabViewItems.map(\.label) == ["General", "Assistant"])
    #expect(dialog.tabViewItems[1].viewController === assistant)
    dialog.selectedTabViewItemIndex = 1
    dialog.selectedTabViewItemIndex = 0
    _ = settings.view
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

  fileprivate var editableFields: [NSTextField] {
    subviews.flatMap { view in
      (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
    } + subviews.flatMap { $0.editableFields }
  }
}

/// Effort is one control made of two, so the tests read both together.
@MainActor
@Suite
struct AssistantSettingsEffortTests {
  private func controller(_ effort: AssistantEffort) -> AssistantSettingsController {
    let settings = AssistantSettings(effort: effort)
    let controller = AssistantSettingsController(settings: settings) { _ in }
    controller.loadView()
    return controller
  }

  private func popup(in controller: AssistantSettingsController) throws -> NSPopUpButton {
    try #require(
      controller.view.popUpButtons.first { $0.accessibilityLabel() == "Effort" }, "the Effort popup"
    )
  }

  private func customField(
    in controller: AssistantSettingsController
  ) throws -> NSTextField {
    try #require(
      controller.view.editableFields.first { $0.accessibilityLabel() == "Custom effort" },
      "the custom Effort field")
  }

  @Test
  func theChoiceStartsOnMediumAndOffersTheWholeRange() throws {
    let controller = self.controller(.medium)
    let popup = try popup(in: controller)

    #expect(
      popup.itemTitles == [
        "Off", "Low", "Medium", "High", "Extra high", "Max", "Custom…",
      ])
    #expect(popup.titleOfSelectedItem == "Medium")
    #expect(controller.settings.effort == .medium)
  }

  @Test(
    arguments: [
      ("Off", AssistantEffort.off), ("Low", .low), ("Medium", .medium), ("High", .high),
      ("Extra high", .xhigh), ("Max", .max),
    ]
  )
  func choosingANamedLevelIsWhatSaveReports(title: String, effort: AssistantEffort) throws {
    let controller = self.controller(.low)
    let popup = try popup(in: controller)

    popup.selectItem(withTitle: title)
    _ = popup.target?.perform(popup.action, with: popup)

    #expect(controller.settings.effort == effort)
  }

  /// Custom is the way out for a word Ganit has never heard; with nothing
  /// typed it asks for nothing, and its leftover text is not a preference
  /// once a named level is chosen again.
  @Test
  func customSendsWhatWasTyped() throws {
    let controller = self.controller(.medium)
    let popup = try popup(in: controller)
    let field = try customField(in: controller)
    #expect(!field.isEnabled)

    popup.selectItem(at: AssistantEffort.choices.count)
    _ = popup.target?.perform(popup.action, with: popup)
    #expect(field.isEnabled)
    #expect(controller.settings.effort == .off)

    field.stringValue = "minimal"
    #expect(controller.settings.effort == .custom("minimal"))

    popup.selectItem(withTitle: "Low")
    _ = popup.target?.perform(popup.action, with: popup)
    #expect(!field.isEnabled)
    #expect(controller.settings.effort == .low)
  }

  @Test
  func aLevelSavedAsCustomComesBackSelectedAndFilled() throws {
    let controller = self.controller(.custom("none"))
    let popup = try popup(in: controller)
    let field = try customField(in: controller)

    #expect(popup.indexOfSelectedItem == AssistantEffort.choices.count)
    #expect(field.isEnabled)
    #expect(field.stringValue == "none")
    #expect(controller.settings.effort == .custom("none"))
  }

  /// Try It asks with the settings on screen, Effort included.
  @Test
  func theExampleIsAskedWithTheEffortOnScreen() throws {
    let controller = self.controller(.medium)
    let popup = try popup(in: controller)
    popup.selectItem(withTitle: "Max")
    _ = popup.target?.perform(popup.action, with: popup)

    #expect(controller.settings.effort == .max)
    #expect(controller.settings.isReady == false)
  }
}
