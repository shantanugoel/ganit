import AppKit
import GanitAssistance
import GanitData
import GanitEditorUI
import GanitEngine

/// Sets up the provider. Each source request needs a separate review action.
@MainActor
public final class AssistantSettingsController: NSViewController {
  static let example = "bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways."
  private let coordinator: SuggestionCoordinator
  private var exampleWindow: NSWindow?

  private var connection: AssistantConnectionDraft
  private let discovery: any AssistantModelDiscovery
  private var discoveryTask: Task<Void, Never>?
  private var discoveryRevision = UUID()
  private var fetchedModels: [AssistantModel] = []
  private var visibleModels: [AssistantModel] = []
  private let provider = NSPopUpButton(frame: .zero, pullsDown: false)
  private let modelSearch = NSSearchField(string: "")
  private let modelList = NSTableView()
  private let discoveryStatus = NSTextField(wrappingLabelWithString: "")
  private let fetchModels = NSButton(
    title: localized("assistant.models.fetch", "Fetch Models"), target: nil, action: nil)
  private let cancelFetch = NSButton(
    title: localized("assistant.models.cancel", "Cancel"), target: nil, action: nil)

  private let didSave: (AssistantSettings) -> Void
  private let enabled = NSButton(
    checkboxWithTitle: localized(
      "assistant.enabled", "Use this provider for Ask Ganit"),
    target: nil,
    action: nil
  )
  private let endpoint = NSTextField(string: "")
  private let model = NSTextField(string: "")
  private let key = NSSecureTextField(string: "")
  /// The named levels, then Custom, which hands the word to the field beside
  /// it instead of naming one of Ganit's own.
  private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
  /// The word to send when the popup says Custom.
  private let customEffort = NSTextField(string: "")
  private let repairAttempts = NSPopUpButton(frame: .zero, pullsDown: false)
  /// Seconds one Ask request waits for its reply, with the stepper beside it.
  private let timeout = NSTextField(string: "")
  private let timeoutStepper = NSStepper()
  private let timeoutUnit = NSTextField(
    labelWithString: localized("assistant.responseTimeout.unit", "seconds"))
  private let markAIDerivedAnswers = NSButton(
    checkboxWithTitle: localized("assistant.markDerived", "Mark AI-derived answers"),
    target: nil, action: nil)
  private let status = NSTextField(wrappingLabelWithString: "")

  public init(
    settings: AssistantSettings, discovery: any AssistantModelDiscovery = ProviderModelDiscovery(),
    coordinator: SuggestionCoordinator = SuggestionCoordinator(),
    didSave: @escaping (AssistantSettings) -> Void
  ) {
    self.connection = AssistantConnectionDraft(settings: settings)
    self.discovery = discovery
    self.coordinator = coordinator
    self.didSave = didSave
    super.init(nibName: nil, bundle: nil)
    provider.addItems(withTitles: AssistantProvider.allCases.map(Self.title(for:)))
    provider.selectItem(at: AssistantProvider.allCases.firstIndex(of: settings.provider)!)
    enabled.state = settings.isEnabled ? .on : .off
    markAIDerivedAnswers.state = settings.markAIDerivedAnswers ? .on : .off
    endpoint.stringValue = settings.endpoint.absoluteString
    model.stringValue = settings.model
    key.stringValue = settings.apiKey
    for level in AssistantEffort.choices {
      effort.addItem(withTitle: Self.title(for: level))
    }
    effort.addItem(withTitle: localized("assistant.effort.custom", "Custom…"))
    customEffort.stringValue = {
      if case .custom(let word) = settings.effort {
        return word
      }
      return ""
    }()
    effort.selectItem(
      at: settings.effort.isCustom
        ? AssistantEffort.choices.count
        : AssistantEffort.choices.firstIndex(of: settings.effort) ?? AssistantEffort.choices.count)
    repairAttempts.addItems(withTitles: (0...3).map(String.init))
    repairAttempts.selectItem(at: settings.repairAttempts)
    timeout.stringValue = String(Int(settings.responseTimeout))
    timeoutStepper.minValue = AssistantSettings.minimumResponseTimeout
    timeoutStepper.maxValue = AssistantSettings.maximumResponseTimeout
    timeoutStepper.increment = 5
    timeoutStepper.doubleValue = settings.responseTimeout
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let explanation = SettingsLayout.caption(
      localized(
        "assistant.explanation",
        "Select a provider, then check its address. Nothing is sent until you select Fetch Models or send an Ask. Context shows the exact request. It can include your question, selected source, source dependencies, matched definitions, calculation settings, and model name. The provider receives this context."
      ))
    let disclosure = SettingsLayout.caption(
      localized(
        "assistant.explanation.provider",
        "Fetch Models sends only a model-list request. A model list does not confirm support for Chat Completions or the Ganit reply format. Ganit checks proposed calculations. Review the preview, then select Apply to change the sheet. Review Example opens a local sheet and sends nothing."
      ))
    status.textColor = VisualStyle.Color.secondary
    provider.setAccessibilityLabel(localized("assistant.provider", "Provider"))
    provider.target = self
    provider.action = #selector(providerChanged(_:))
    endpoint.delegate = self
    model.delegate = self
    key.delegate = self
    modelSearch.delegate = self
    endpoint.setAccessibilityLabel(localized("assistant.address", "Address"))
    model.setAccessibilityLabel(localized("assistant.model", "Model"))
    key.setAccessibilityLabel(localized("assistant.key", "API Key"))
    effort.setAccessibilityLabel(localized("assistant.effort", "Effort"))
    repairAttempts.setAccessibilityLabel(localized("assistant.repairAttempts", "Repair attempts"))
    repairAttempts.toolTip = localized(
      "assistant.repairAttempts.help",
      "Maximum automatic repair attempts for each Ask. The request limit can reduce this number.")
    repairAttempts.setAccessibilityHelp(repairAttempts.toolTip)
    timeout.setAccessibilityLabel(
      localized("assistant.responseTimeout", "Response timeout"))
    timeout.alignment = .right
    timeout.placeholderString = String(Int(AssistantSettings.defaultResponseTimeout))
    let seconds = NumberFormatter()
    seconds.numberStyle = .none
    seconds.allowsFloats = false
    seconds.usesGroupingSeparator = false
    seconds.minimum = NSNumber(value: AssistantSettings.minimumResponseTimeout)
    seconds.maximum = NSNumber(value: AssistantSettings.maximumResponseTimeout)
    timeout.formatter = seconds
    timeout.toolTip = localized(
      "assistant.responseTimeout.help",
      "Seconds one Ask waits for its reply. A model that thinks before it answers needs the longer waits. Between 5 and 600."
    )
    timeout.setAccessibilityHelp(timeout.toolTip)
    timeoutStepper.target = self
    timeoutStepper.action = #selector(timeoutStepperChanged(_:))
    timeoutStepper.setAccessibilityLabel(
      localized("assistant.responseTimeout", "Response timeout"))
    timeoutUnit.textColor = VisualStyle.Color.secondary
    effort.target = self
    effort.action = #selector(effortChanged(_:))
    customEffort.setAccessibilityLabel(
      localized("assistant.effort.customField", "Custom effort"))
    customEffort.placeholderString = localized(
      "assistant.effort.customPlaceholder", "A word the server knows")
    endpoint.placeholderString = AssistantSettings.defaultEndpoint.absoluteString
    model.placeholderString = AssistantSettings.defaultModel
    syncKeyPlaceholder()

    let effortField = NSStackView(views: [effort, customEffort])
    effortField.orientation = .horizontal
    effortField.spacing = VisualStyle.Spacing.related
    // A short number, its unit, and the stepper that steps it: one setting.
    let timeoutField = NSStackView(views: [timeout, timeoutUnit, timeoutStepper])
    timeoutField.orientation = .horizontal
    timeoutField.spacing = VisualStyle.Spacing.tight

    modelSearch.setAccessibilityLabel(localized("assistant.models.search", "Search models"))
    modelSearch.placeholderString = localized("assistant.models.search", "Search models")
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
    column.width = SettingsLayout.controlAreaWidth
    modelList.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    column.title = localized("assistant.models.available", "Available models")
    modelList.addTableColumn(column)
    modelList.headerView = nil
    modelList.setAccessibilityLabel(column.title)
    modelList.dataSource = self
    modelList.delegate = self
    modelList.allowsEmptySelection = true
    modelList.usesAlternatingRowBackgroundColors = true
    let scroll = NSScrollView()
    scroll.documentView = modelList
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    fetchModels.target = self
    fetchModels.action = #selector(fetchModelsClicked(_:))
    cancelFetch.target = self
    cancelFetch.action = #selector(cancelModelsClicked(_:))
    cancelFetch.isEnabled = false
    discoveryStatus.textColor = VisualStyle.Color.secondary
    discoveryStatus.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    discoveryStatus.stringValue = localized(
      "assistant.models.manual", "Enter a model identifier, or fetch models from the address above."
    )
    let discoveryButtons = NSStackView(views: [fetchModels, cancelFetch])

    let connection = SettingsLayout.section(
      localized("assistant.section.connection", "Connection"),
      SettingsLayout.rows([
        (localized("assistant.provider", "Provider"), provider),
        (localized("assistant.address", "Address"), endpoint),
        (localized("assistant.key", "API Key"), key),
      ]))
    let modelSection = SettingsLayout.section(
      localized("assistant.section.model", "Model"),
      SettingsLayout.stack([
        SettingsLayout.rows([(localized("assistant.model", "Model"), model)]),
        modelSearch,
        scroll,
        discoveryButtons,
        discoveryStatus,
      ]))
    let generation = SettingsLayout.section(
      localized("assistant.section.generation", "Generation"),
      SettingsLayout.rows([
        (localized("assistant.effort", "Effort"), effortField),
        (localized("assistant.repairAttempts", "Repair attempts"), repairAttempts),
        (localized("assistant.responseTimeout", "Response timeout"), timeoutField),
      ]))
    for field in [endpoint, model, key] {
      field.widthAnchor.constraint(equalToConstant: SettingsLayout.fieldWidth).isActive = true
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: field.fittingSize.height)
        .isActive = true
    }
    // The word belongs to Custom alone, so it appears only when Custom is
    // chosen: an empty box beside the popup would read as a second setting.
    // The popup names that setting, so when the row runs short it is the word
    // that gives way.
    effortField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    let customWidth = customEffort.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
    customWidth.priority = .defaultLow
    customWidth.isActive = true
    customEffort.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    effort.setContentCompressionResistancePriority(.required, for: .horizontal)
    timeout.widthAnchor.constraint(equalToConstant: 52).isActive = true
    NSLayoutConstraint.activate([
      modelSearch.widthAnchor.constraint(equalToConstant: SettingsLayout.controlAreaWidth),
      scroll.widthAnchor.constraint(equalToConstant: SettingsLayout.controlAreaWidth),
      scroll.heightAnchor.constraint(equalToConstant: 120),
      discoveryStatus.widthAnchor.constraint(equalToConstant: SettingsLayout.controlAreaWidth),
    ])

    let save = NSButton(
      title: localized("assistant.save", "Save"), target: self, action: #selector(save(_:)))
    save.keyEquivalent = "\r"
    let test = NSButton(
      title: localized("assistant.test", "Review Example"), target: self,
      action: #selector(test(_:)))
    // The default button sits where a person looks for it, at the end, and the
    // secondary action keeps the leading edge.
    let buttons = SettingsLayout.actions(test, trailing: save)

    NSLayoutConstraint.activate([
      SettingsLayout.bindWidth(explanation),
      SettingsLayout.bindWidth(disclosure),
      SettingsLayout.bindWidth(status),
    ])
    view = SettingsLayout.panel(
      [
        explanation, disclosure, enabled, connection, modelSection, generation,
        markAIDerivedAnswers, status, buttons,
      ],
      height: 620)
    syncCustomEffortField()
  }

  static func title(for provider: AssistantProvider) -> String {
    switch provider {
    case .openAI: "OpenAI"
    case .openRouter: "OpenRouter"
    case .ollama: "Ollama"
    case .lmStudio: "LM Studio"
    case .custom: localized("assistant.provider.custom", "Custom")
    }
  }

  private func syncKeyPlaceholder() {
    key.placeholderString =
      connection.provider.requiresKey
      ? localized("assistant.key.required", "Required")
      : localized("assistant.key.optional", "Optional Bearer token")
  }

  @objc private func providerChanged(_ sender: Any?) {
    let index = provider.indexOfSelectedItem
    guard AssistantProvider.allCases.indices.contains(index) else { return }
    connection.selectProvider(AssistantProvider.allCases[index])
    endpoint.stringValue = connection.endpoint
    key.stringValue = connection.apiKey
    syncKeyPlaceholder()
    invalidateDiscovery()
  }

  private func synchronizeConnection() {
    if endpoint.stringValue != connection.endpoint {
      connection.setEndpoint(endpoint.stringValue)
      key.stringValue = connection.apiKey
    } else {
      connection.apiKey = key.stringValue
    }
  }

  private func reloadModels() {
    let query = modelSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    modelList.deselectAll(nil)
    visibleModels = fetchedModels.filter {
      query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
        || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
    }
    modelList.reloadData()
  }

  private func cancelDiscovery() {
    discoveryRevision = UUID()
    discoveryTask?.cancel()
    discoveryTask = nil
    fetchModels.isEnabled = true
    cancelFetch.isEnabled = false
  }

  private func invalidateDiscovery() {
    status.stringValue = ""
    cancelDiscovery()
    fetchedModels = []
    reloadModels()
    fetchModels.title = localized("assistant.models.fetch", "Fetch Models")
    discoveryStatus.stringValue = localized(
      "assistant.models.manual", "Enter a model identifier, or fetch models from the address above."
    )
  }

  @objc private func timeoutStepperChanged(_ sender: Any?) {
    timeout.stringValue = String(Int(timeoutStepper.doubleValue))
  }

  @objc private func cancelModelsClicked(_ sender: Any?) {
    cancelDiscovery()
    discoveryStatus.stringValue = localized(
      "assistant.models.cancelled", "Model fetch cancelled. You can enter a model identifier.")
  }

  @objc private func fetchModelsClicked(_ sender: Any?) {
    synchronizeConnection()
    guard
      let address = URL(
        string: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
      Assistant.isAllowed(address)
    else {
      discoveryStatus.stringValue = localized(
        "assistant.invalidAddress", "Enter an HTTPS address or a local HTTP address.")
      return
    }
    cancelDiscovery()
    let revision = discoveryRevision
    let selectedSettings = settings
    let service = discovery
    fetchModels.isEnabled = false
    cancelFetch.isEnabled = true
    discoveryStatus.stringValue = localized("assistant.models.loading", "Fetching models…")
    discoveryTask = Task { [weak self] in
      do {
        let models = try await service.models(settings: selectedSettings)
        guard let self, self.discoveryRevision == revision, !Task.isCancelled else { return }
        var ids: Set<String> = []
        self.fetchedModels = models.filter { ids.insert($0.id).inserted }
        self.fetchModels.title = localized("assistant.models.refresh", "Refresh")
        self.reloadModels()
        self.discoveryStatus.stringValue =
          models.isEmpty
          ? localized(
            "assistant.models.empty",
            "The provider returned no models. You can enter a model identifier.")
          : localized("assistant.models.select", "Select a model, or enter its identifier above.")
      } catch {
        guard let self, self.discoveryRevision == revision, !Task.isCancelled else { return }
        let failure = error as? ProviderFailure
        let detail = failure.map { ProviderErrorMessages.message(for: $0.category) } ?? ""
        self.discoveryStatus.stringValue =
          localized(
            "assistant.models.failed", "Model discovery failed. You can enter a model identifier.")
          + (detail.isEmpty ? "" : " " + detail)
      }
      guard let self, self.discoveryRevision == revision else { return }
      self.discoveryTask = nil
      self.fetchModels.isEnabled = true
      self.cancelFetch.isEnabled = false
    }
  }

  public override func viewDidDisappear() {
    super.viewDidDisappear()
    cancelDiscovery()
  }

  /// The name Settings shows for a level.
  static func title(for effort: AssistantEffort) -> String {
    switch effort {
    case .off:
      return localized("assistant.effort.off", "Off")
    case .low:
      return localized("assistant.effort.low", "Low")
    case .medium:
      return localized("assistant.effort.medium", "Medium")
    case .high:
      return localized("assistant.effort.high", "High")
    case .xhigh:
      return localized("assistant.effort.xhigh", "Extra high")
    case .max:
      return localized("assistant.effort.max", "Max")
    case .custom:
      return localized("assistant.effort.custom", "Custom…")
    }
  }

  @objc private func effortChanged(_ sender: Any?) {
    syncCustomEffortField()
    if effort.indexOfSelectedItem == AssistantEffort.choices.count {
      view.window?.makeFirstResponder(customEffort)
    }
  }

  /// Only Custom has a word to type, so only then is the field live. An empty
  /// box beside the popup would read as another setting nobody chose.
  private func syncCustomEffortField() {
    let isCustom = effort.indexOfSelectedItem == AssistantEffort.choices.count
    customEffort.isHidden = !isCustom
    customEffort.isEnabled = isCustom
    customEffort.placeholderString =
      isCustom
      ? localized("assistant.effort.customPlaceholder", "A word the server knows")
      : nil
  }

  /// The seconds on screen, or the default when the field holds no number.
  private var chosenTimeout: TimeInterval {
    if let number = timeout.objectValue as? NSNumber { return number.doubleValue }
    return Double(timeout.stringValue.trimmingCharacters(in: .whitespaces))
      ?? AssistantSettings.defaultResponseTimeout
  }

  /// What the fields currently say, whether or not it has been saved.
  var settings: AssistantSettings {
    synchronizeConnection()
    return AssistantSettings(
      provider: connection.provider,
      isEnabled: enabled.state == .on,
      endpoint: URL(string: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        ?? URL(string: "about:invalid")!,
      model: model.stringValue.trimmingCharacters(in: .whitespaces),
      apiKey: key.stringValue.trimmingCharacters(in: .whitespaces),
      effort: chosenEffort,
      repairAttempts: max(0, repairAttempts.indexOfSelectedItem),
      responseTimeout: chosenTimeout,
      markAIDerivedAnswers: markAIDerivedAnswers.state == .on
    )
  }

  /// The popup and the field beside it read as one setting: whatever the
  /// popup last said, not what the field still holds from an earlier Custom.
  private var chosenEffort: AssistantEffort {
    let index = effort.indexOfSelectedItem
    guard index >= 0, index < AssistantEffort.choices.count else {
      return AssistantEffort(storage: "custom:\(customEffort.stringValue)")
    }
    return AssistantEffort.choices[index]
  }

  @objc func save(_ sender: Any?) {
    guard
      let address = URL(
        string: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
      Assistant.isAllowed(address)
    else {
      status.stringValue = localized(
        "assistant.invalidAddress", "Enter an HTTPS address or a local HTTP address.")
      return
    }
    cancelDiscovery()
    didSave(settings)
    view.window?.close()
  }

  /// Prepare a synthetic example. Opening it makes no network request.
  @objc func test(_ sender: Any?) {
    guard settings.isReady else {
      status.stringValue = "Enable the provider and supply an allowed address and model."
      return
    }
    do {
      let context = try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates, angleMode: .radians,
        precision: PrecisionContext(significantDecimalDigits: 15), now: Date(),
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!)
      let editor = SheetEditorViewController(text: Self.example, context: context)
      editor.suggestionConfiguration = SheetSuggestionConfiguration(
        coordinator: coordinator, settings: settings)
      editor.textView.setSelectedRange(
        NSRange(location: "bill = 2400 INR\n".utf16.count, length: 0))
      exampleWindow?.close()
      let window = NSWindow(contentViewController: editor)
      window.title = "Suggestion Example"
      window.setContentSize(NSSize(width: 640, height: 420))
      window.isReleasedWhenClosed = false
      window.delegate = self
      exampleWindow = window
      window.makeKeyAndOrderFront(nil)
      editor.askGanit(nil)
      status.stringValue = "Review the synthetic source scope. Send is a separate action."
    } catch { status.stringValue = "The synthetic example cannot be prepared." }
  }

}

extension AssistantSettingsController: NSWindowDelegate {
  public func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === exampleWindow else { return }
    (window.contentViewController as? SheetEditorViewController)?.stopCalculation(nil)
    exampleWindow = nil
  }
}

extension AssistantSettingsController: NSSearchFieldDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  public func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    if field === model {
      modelList.deselectAll(nil)
      return
    }
    if field === modelSearch {
      reloadModels()
      return
    }
    if field === timeout {
      // The stepper follows the typed number, so the two read as one control.
      if let typed = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) {
        timeoutStepper.doubleValue = min(
          AssistantSettings.maximumResponseTimeout,
          max(AssistantSettings.minimumResponseTimeout, typed))
      }
      return
    }
    guard field === endpoint || field === key else { return }
    synchronizeConnection()
    invalidateDiscovery()
  }

  public func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

  public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    guard visibleModels.indices.contains(row) else { return nil }
    let item = visibleModels[row]
    let title = item.name.map { $0 + " — " + item.id } ?? item.id
    let cell = NSTextField(labelWithString: title)
    cell.lineBreakMode = .byTruncatingTail
    cell.toolTip = title
    return cell
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    let row = modelList.selectedRow
    guard visibleModels.indices.contains(row) else { return }
    model.stringValue = visibleModels[row].id
  }
}
