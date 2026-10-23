import AppKit
import GanitData
import Testing

@testable import GanitWorkspaceUI

/// The response timeout is one setting made of a field and a stepper, so the
/// tests read both together, and one number now covers every address.
@MainActor
@Suite
struct AssistantResponseTimeoutSettingsTests {
  private func controller(_ settings: AssistantSettings) -> AssistantSettingsController {
    let controller = AssistantSettingsController(settings: settings) { _ in }
    controller.loadView()
    return controller
  }

  private func controls<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { controls($0, as: type) }
  }

  private func field(in controller: AssistantSettingsController) throws -> NSTextField {
    try #require(
      controls(controller.view, as: NSTextField.self).first {
        $0.accessibilityLabel() == "Response timeout"
      })
  }

  private func stepper(in controller: AssistantSettingsController) throws -> NSStepper {
    try #require(controls(controller.view, as: NSStepper.self).first)
  }

  @Test func theSavedWaitIsOnScreenAndInTheStepper() throws {
    let controller = controller(AssistantSettings(responseTimeout: 45))
    #expect(try field(in: controller).stringValue == "45")
    #expect(try stepper(in: controller).doubleValue == 45)
    #expect(controller.settings.responseTimeout == 45)
  }

  @Test func nobodyWhoNeverOpenedSettingsGetsTheLongerDefaultWait() throws {
    let controller = controller(AssistantSettings())
    #expect(try field(in: controller).stringValue == "120")
    #expect(controller.settings.responseTimeout == 120)
    #expect(AssistantSettings.defaultResponseTimeout == 120)
  }

  @Test func typingAWaitIsWhatSaveReports() throws {
    var reported: AssistantSettings?
    let controller = AssistantSettingsController(settings: AssistantSettings()) {
      reported = $0
    }
    controller.loadView()
    let field = try field(in: controller)
    field.stringValue = "300"
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(try stepper(in: controller).doubleValue == 300)
    #expect(controller.settings.responseTimeout == 300)
    controller.save(nil)
    #expect(reported?.responseTimeout == 300)
  }

  /// The stepper and the field are one control: the stepper writes the number
  /// the field shows.
  @Test func steppingTheWaitWritesTheField() throws {
    let controller = controller(AssistantSettings(responseTimeout: 90))
    let stepper = try stepper(in: controller)
    stepper.doubleValue = 95
    _ = stepper.target?.perform(stepper.action, with: stepper)
    #expect(try field(in: controller).stringValue == "95")
    #expect(controller.settings.responseTimeout == 95)
  }

  /// A field can hold anything, so what leaves Settings is always a wait with
  /// a chance of being answered.
  @Test(arguments: [("9999", 600.0), ("0", 5.0), ("", 120.0), ("ninety", 120.0)])
  func anUnusableNumberSavesTheNearestUsableWait(typed: String, saved: TimeInterval) throws {
    let controller = controller(AssistantSettings())
    let field = try field(in: controller)
    field.stringValue = typed
    #expect(controller.settings.responseTimeout == saved)
  }

  /// The wait belongs to the request, not to the address, so a change of
  /// provider keeps it.
  @Test func changingTheProviderKeepsTheWait() throws {
    let controller = controller(AssistantSettings(responseTimeout: 240))
    let provider = try #require(
      controls(controller.view, as: NSPopUpButton.self).first {
        $0.accessibilityLabel() == "Provider"
      })
    provider.selectItem(withTitle: "Ollama")
    _ = provider.sendAction(provider.action, to: provider.target)
    #expect(controller.settings.provider == .ollama)
    #expect(controller.settings.responseTimeout == 240)
  }
}
