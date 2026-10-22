import AppKit
import GanitData
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct AssistantRepairSettingsControllerTests {
  private func popups(_ view: NSView) -> [NSPopUpButton] {
    (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
  }

  @Test(arguments: [0, 1, 2, 3])
  func savedRepairAttemptsAreSelectedAndSaveReportsTheNewChoice(_ saved: Int) throws {
    var reported: AssistantSettings?
    let controller = AssistantSettingsController(settings: AssistantSettings(repairAttempts: saved))
    {
      reported = $0
    }
    controller.loadView()
    let popup = try #require(
      popups(controller.view).first { $0.accessibilityLabel() == "Repair attempts" })
    #expect(popup.itemTitles == ["0", "1", "2", "3"])
    #expect(popup.titleOfSelectedItem == String(saved))
    #expect(controller.settings.repairAttempts == saved)
    #expect(popup.accessibilityHelp()?.contains("request limit") == true)
    let chosen = (saved + 1) % 4
    popup.selectItem(at: chosen)
    controller.save(nil)
    #expect(reported?.repairAttempts == chosen)
  }

  @Test func repairAttemptsStartAtTwoAndDoNotChangeEffort() throws {
    let controller = AssistantSettingsController(settings: AssistantSettings()) { _ in }
    controller.loadView()
    let popup = try #require(
      popups(controller.view).first { $0.accessibilityLabel() == "Repair attempts" })
    #expect(popup.titleOfSelectedItem == "2")
    popup.selectItem(at: 0)
    #expect(controller.settings.repairAttempts == 0)
    #expect(controller.settings.effort == .medium)
  }
}
