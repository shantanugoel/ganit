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

  @Test func settingsDescribeTheDisclosedRequestAndExplicitApply() {
    let controller = AssistantSettingsController(settings: AssistantSettings()) { _ in }
    controller.loadView()
    func texts(_ view: NSView) -> [String] {
      (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
    }
    let copy = texts(controller.view).joined(separator: " ")
    #expect(copy.contains("Nothing is sent until you send an Ask."))
    #expect(copy.contains("Context shows the exact request."))
    #expect(copy.contains("source dependencies"))
    #expect(copy.contains("calculation settings"))
    #expect(copy.contains("select Apply"))
    #expect(!copy.contains("that line, the model's name"))
    #expect(!copy.contains("nothing else:"))
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
