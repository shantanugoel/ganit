import AppKit
import GanitData
import GanitSuggestionProtocol
import Testing

@testable import GanitWorkspaceUI

/// The sharing popup and the line under it read as one setting: the line
/// always says what the chosen level sends.
@MainActor
@Suite
struct AssistantContextSharingSettingsTests {
  private func controller(_ settings: AssistantSettings) -> AssistantSettingsController {
    let controller = AssistantSettingsController(settings: settings) { _ in }
    controller.loadView()
    return controller
  }

  private func controls<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { controls($0, as: type) }
  }

  private func popup(in controller: AssistantSettingsController) throws -> NSPopUpButton {
    try #require(
      controls(controller.view, as: NSPopUpButton.self).first {
        $0.accessibilityLabel() == "Share with assistant"
      })
  }

  private func texts(_ controller: AssistantSettingsController) -> String {
    controls(controller.view, as: NSTextField.self).map(\.stringValue).joined(separator: " ")
  }

  @Test func theDefaultSharesOnlyWhatIsNeeded() throws {
    let controller = controller(AssistantSettings())
    let popup = try popup(in: controller)
    #expect(popup.itemTitles == ["Only what's needed", "Also variable names", "Whole sheet"])
    #expect(popup.indexOfSelectedItem == 0)
    #expect(texts(controller).contains(AssistantSettingsController.detail(for: .needed)))
  }

  @Test(arguments: AssistantContextSharing.allCases)
  func choosingALevelExplainsItAndSavesIt(level: AssistantContextSharing) throws {
    let controller = controller(AssistantSettings())
    let popup = try popup(in: controller)
    popup.selectItem(at: AssistantContextSharing.allCases.firstIndex(of: level)!)
    _ = popup.target?.perform(popup.action, with: popup)
    #expect(texts(controller).contains(AssistantSettingsController.detail(for: level)))
    #expect(controller.settings.contextSharing == level)
  }

  @Test func theSavedLevelIsOnScreen() throws {
    let controller = controller(AssistantSettings(contextSharing: .sheet))
    #expect(try popup(in: controller).titleOfSelectedItem == "Whole sheet")
  }
}
