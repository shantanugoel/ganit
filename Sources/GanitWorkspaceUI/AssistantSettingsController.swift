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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let explanation = NSTextField(
      wrappingLabelWithString: localized(
        "assistant.explanation",
        "Select a provider and check its address. Fetch Models sends only a model-list request. Nothing is sent until you select Fetch Models or send an Ask. Context shows the exact request. It can include your question, selected source, source dependencies, matched definitions, calculation settings, and model name. The provider receives this context. A model list does not confirm support for Chat Completions or the Ganit reply format. Ganit checks proposed calculations. Review the preview, then select Apply to change the sheet. Review Example opens a local sheet and sends nothing."
      )
    )
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

    let fields = NSGridView(views: [
      [label(localized("assistant.provider", "Provider")), provider],
      [label(localized("assistant.address", "Address")), endpoint],
      [label(localized("assistant.model", "Model")), model],
      [label(localized("assistant.key", "API Key")), key],
      [label(localized("assistant.effort", "Effort")), effortField],
      [label(localized("assistant.repairAttempts", "Repair attempts")), repairAttempts],
    ])
    fields.yPlacement = .center
    for field in [endpoint, model, key, customEffort] {
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: field.fittingSize.height)
        .isActive = true
    }
    fields.rowSpacing = VisualStyle.Spacing.related
    fields.columnSpacing = VisualStyle.Spacing.related
    fields.column(at: 0).xPlacement = .trailing
    // The word belongs to Custom alone, so it is dimmed and uneditable
    // otherwise rather than sitting there looking settable.
    effortField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    customEffort.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    // Spare height belongs to the wrapping explanation, not between rows.
    fields.setContentHuggingPriority(.defaultHigh, for: .vertical)

    modelSearch.setAccessibilityLabel(localized("assistant.models.search", "Search models"))
    modelSearch.placeholderString = localized("assistant.models.search", "Search models")
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
    column.width = 440
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
    discoveryStatus.stringValue = localized(
      "assistant.models.manual", "Enter a model identifier, or fetch models from the address above."
    )
    let discoveryButtons = NSStackView(views: [fetchModels, cancelFetch])
    let discoveryControls = NSStackView(views: [
      modelSearch, scroll, discoveryButtons, discoveryStatus,
    ])
    discoveryControls.orientation = .vertical
    discoveryControls.alignment = .leading
    discoveryControls.spacing = VisualStyle.Spacing.related
    NSLayoutConstraint.activate([
      discoveryControls.widthAnchor.constraint(equalToConstant: 440),
      modelSearch.widthAnchor.constraint(equalTo: discoveryControls.widthAnchor),
      scroll.widthAnchor.constraint(equalTo: discoveryControls.widthAnchor),
      scroll.heightAnchor.constraint(equalToConstant: 110),
      discoveryStatus.widthAnchor.constraint(equalTo: discoveryControls.widthAnchor),
    ])

    let save = NSButton(
      title: localized("assistant.save", "Save"), target: self, action: #selector(save(_:)))
    save.keyEquivalent = "\r"
    let test = NSButton(
      title: localized("assistant.test", "Review Example"), target: self,
      action: #selector(test(_:)))
    let buttons = NSStackView(views: [test, save])

    let stack = NSStackView(views: [
      explanation, enabled, fields, discoveryControls, markAIDerivedAnswers, status, buttons,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.group
    let margin = VisualStyle.Spacing.window
    stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      explanation.widthAnchor.constraint(equalToConstant: 440),
      status.widthAnchor.constraint(equalToConstant: 440),
      fields.widthAnchor.constraint(equalToConstant: 440),
    ])
    syncCustomEffortField()
    view = container
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

  /// Only Custom has a word to type, so only then is the field live.
  private func syncCustomEffortField() {
    let isCustom = effort.indexOfSelectedItem == AssistantEffort.choices.count
    customEffort.isEnabled = isCustom
    customEffort.placeholderString =
      isCustom
      ? localized("assistant.effort.customPlaceholder", "A word the server knows")
      : nil
  }

  private func label(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.textColor = VisualStyle.Color.secondary
    return field
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
