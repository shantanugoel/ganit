import AppKit
import GanitData
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite(.serialized)
struct AssistantProviderSettingsTests {
  private func controls<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { controls($0, as: type) }
  }

  private func field(_ label: String, in controller: AssistantSettingsController) throws
    -> NSTextField
  {
    try #require(
      controls(controller.view, as: NSTextField.self).first { $0.accessibilityLabel() == label })
  }

  private func button(_ title: String, in controller: AssistantSettingsController) throws
    -> NSButton
  {
    try #require(controls(controller.view, as: NSButton.self).first { $0.title == title })
  }

  private func edit(_ field: NSTextField, _ text: String, controller: AssistantSettingsController) {
    field.stringValue = text
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(predicate())
  }

  @Test func editableControlsHaveEnoughHeightAndInvalidAddressesStayInvalid() throws {
    let controller = AssistantSettingsController(
      settings: AssistantSettings(isEnabled: true, apiKey: "saved-key")
    ) { _ in }
    let window = NSWindow(contentViewController: controller)
    window.layoutIfNeeded()
    for control in controls(controller.view, as: NSTextField.self)
    where control.isEditable && control.isEnabled {
      #expect(
        control.frame.height >= control.fittingSize.height,
        "\(control.accessibilityLabel() ?? "field"): \(control.frame.height) < \(control.fittingSize.height)"
      )
      #expect(control.acceptsFirstResponder)
    }
    edit(try field("Address", in: controller), "http://[", controller: controller)
    #expect(!controller.settings.isReady)
    #expect(controller.settings.apiKey.isEmpty)
  }

  @Test func providerAndOriginChangesClearOnlyTheUnsavedKey() async throws {
    let service = ControlledModelDiscovery()
    var saved: AssistantSettings?
    let original = AssistantSettings(
      isEnabled: true, endpoint: URL(string: "https://example.test/v1")!, model: "manual",
      apiKey: "old-key")
    let controller = AssistantSettingsController(settings: original, discovery: service) {
      saved = $0
    }
    controller.loadView()
    let address = try field("Address", in: controller)
    let key = try field("API Key", in: controller)
    #expect(await service.count() == 0)
    edit(address, "https://example.test:443/path/v1", controller: controller)
    #expect(key.stringValue == "old-key")
    edit(address, "https://new.example.test/v1", controller: controller)
    #expect(key.stringValue.isEmpty)
    #expect(saved == nil)
    #expect(original.apiKey == "old-key")
    edit(key, "new-key", controller: controller)
    #expect(await service.count() == 0)
    let provider = try #require(
      controls(controller.view, as: NSPopUpButton.self).first {
        $0.accessibilityLabel() == "Provider"
      })
    provider.selectItem(withTitle: "LM Studio")
    // Send the selection action as AppKit does after menu selection.
    _ = provider.sendAction(provider.action, to: provider.target)
    #expect(controller.settings.provider == .lmStudio)
    #expect(address.stringValue == "http://localhost:1234/v1")
    #expect(key.stringValue.isEmpty)
    #expect(await service.count() == 0)
    controller.save(nil)
    #expect(saved?.provider == .lmStudio)
    #expect(saved?.model == "manual")
    #expect(saved?.apiKey.isEmpty == true)
  }

  @Test func fetchSearchRefreshAndManualEntryKeepTheSelectedModel() async throws {
    let service = ControlledModelDiscovery()
    let controller = AssistantSettingsController(
      settings: AssistantSettings(model: "manual"), discovery: service
    ) { _ in }
    controller.loadView()
    let table = try #require(controls(controller.view, as: NSTableView.self).first)
    let search = try field("Search models", in: controller)
    let fetch = try button("Fetch Models", in: controller)
    fetch.performClick(nil)
    await service.waitForRequests(1)
    #expect(!fetch.isEnabled)
    #expect(try button("Cancel", in: controller).isEnabled)
    await service.complete(
      0,
      result: .success([
        AssistantModel(id: "a", name: "Alpha"), AssistantModel(id: "b", name: "Beta"),
        AssistantModel(id: "a"),
      ]))
    await waitUntil { fetch.isEnabled }
    #expect(table.numberOfRows == 2)
    #expect(fetch.title == "Refresh")
    #expect(controller.settings.model == "manual")
    edit(search, "beta", controller: controller)
    #expect(table.numberOfRows == 1)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    #expect(controller.settings.model == "b")
    fetch.performClick(nil)
    await service.waitForRequests(2)
    await service.complete(
      1, result: .failure(ProviderFailure(status: 401, category: .authentication)))
    await waitUntil { fetch.isEnabled }
    #expect(controller.settings.model == "b")
    #expect(table.numberOfRows == 1)
    let manual = try field("Model", in: controller)
    edit(manual, "typed-model", controller: controller)
    #expect(controller.settings.model == "typed-model")
    #expect(table.selectedRow == -1)
    fetch.performClick(nil)
    await service.waitForRequests(3)
    await service.complete(2, result: .success([]))
    await waitUntil { fetch.isEnabled }
    #expect(table.numberOfRows == 0)
    #expect(controller.settings.model == "typed-model")
  }

  @Test(arguments: ["Address", "API Key", "Provider", "Cancel"])
  func lateDiscoveryCannotReplaceTheListAfterConnectionChangeOrCancellation(_ change: String)
    async throws
  {
    let service = ControlledModelDiscovery()
    let controller = AssistantSettingsController(
      settings: AssistantSettings(model: "manual"), discovery: service
    ) { _ in }
    controller.loadView()
    let fetch = try button("Fetch Models", in: controller)
    let table = try #require(controls(controller.view, as: NSTableView.self).first)
    fetch.performClick(nil)
    await service.waitForRequests(1)
    switch change {
    case "Address":
      edit(try field("Address", in: controller), "https://another.test/v1", controller: controller)
    case "API Key": edit(try field("API Key", in: controller), "new-key", controller: controller)
    case "Provider":
      let provider = try #require(
        controls(controller.view, as: NSPopUpButton.self).first {
          $0.accessibilityLabel() == "Provider"
        })
      provider.selectItem(withTitle: "Ollama")
      _ = provider.sendAction(provider.action, to: provider.target)
    default: try button("Cancel", in: controller).performClick(nil)
    }
    fetch.performClick(nil)
    await service.waitForRequests(2)
    await service.complete(1, result: .success([AssistantModel(id: "current")]))
    await waitUntil { fetch.isEnabled && table.numberOfRows == 1 }
    await service.complete(
      0, result: .success([AssistantModel(id: "late"), AssistantModel(id: "stale")]))
    for _ in 0..<20 { await Task.yield() }
    #expect(table.numberOfRows == 1)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    #expect(controller.settings.model == "current")
  }
}

private actor ControlledModelDiscovery: AssistantModelDiscovery {
  private var requests: [AssistantSettings] = []
  private var pending: [Int: CheckedContinuation<[AssistantModel], any Error>] = [:]
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func models(settings: AssistantSettings) async throws -> [AssistantModel] {
    let index = requests.count
    requests.append(settings)
    return try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      let ready = waiters.filter { requests.count >= $0.0 }
      waiters.removeAll { requests.count >= $0.0 }
      for waiter in ready { waiter.1.resume() }
    }
  }
  func count() -> Int { requests.count }
  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
  func complete(_ index: Int, result: Result<[AssistantModel], any Error>) {
    pending.removeValue(forKey: index)?.resume(with: result)
  }
}
