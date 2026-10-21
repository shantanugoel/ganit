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

  private let didSave: (AssistantSettings) -> Void
  private let enabled = NSButton(
    checkboxWithTitle: localized(
      "assistant.enabled", "Use this provider for expression suggestions"),
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
  private let status = NSTextField(wrappingLabelWithString: "")

  public init(
    settings: AssistantSettings, coordinator: SuggestionCoordinator = SuggestionCoordinator(),
    didSave: @escaping (AssistantSettings) -> Void
  ) {
    self.coordinator = coordinator
    self.didSave = didSave
    super.init(nibName: nil, bundle: nil)
    enabled.state = settings.isEnabled ? .on : .off
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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let explanation = NSTextField(
      wrappingLabelWithString: localized(
        "assistant.explanation",
        "The address is any OpenAI-compatible base, such as https://api.openai.com/v1, http://localhost:11434/v1, or https://host/v1. Ganit POSTs that base's chat/completions. A request about one line carries that line, the model's name, and the Effort you picked, and nothing else: not the rest of the sheet, its title, or anything about this Mac. Effort is how hard the model is asked to think; Medium is the default, Off sends no preference at all and leaves it to the model, and Custom sends a word Ganit does not know, such as minimal. A suggestion can send selected source, attached notes, matching declarations and their values, and calculation settings; review the context before sending. Provider setup does not grant source permission or enable automatic suggestions. Ganit checks expressions with its local engine, and only an explicit apply changes source."
      )
    )
    status.textColor = VisualStyle.Color.secondary
    endpoint.setAccessibilityLabel(localized("assistant.address", "Address"))
    model.setAccessibilityLabel(localized("assistant.model", "Model"))
    key.setAccessibilityLabel(localized("assistant.key", "API Key"))
    effort.setAccessibilityLabel(localized("assistant.effort", "Effort"))
    effort.target = self
    effort.action = #selector(effortChanged(_:))
    customEffort.setAccessibilityLabel(
      localized("assistant.effort.customField", "Custom effort"))
    customEffort.placeholderString = localized(
      "assistant.effort.customPlaceholder", "A word the server knows")
    endpoint.placeholderString = AssistantSettings.defaultEndpoint.absoluteString
    model.placeholderString = AssistantSettings.defaultModel
    key.placeholderString = localized("assistant.keyPlaceholder", "Not needed for a local model")

    let effortField = NSStackView(views: [effort, customEffort])
    effortField.orientation = .horizontal
    effortField.spacing = VisualStyle.Spacing.related

    let fields = NSGridView(views: [
      [label(localized("assistant.address", "Address")), endpoint],
      [label(localized("assistant.model", "Model")), model],
      [label(localized("assistant.key", "API Key")), key],
      [label(localized("assistant.effort", "Effort")), effortField],
    ])
    fields.rowSpacing = VisualStyle.Spacing.related
    fields.columnSpacing = VisualStyle.Spacing.related
    fields.column(at: 0).xPlacement = .trailing
    // The word belongs to Custom alone, so it is dimmed and uneditable
    // otherwise rather than sitting there looking settable.
    effortField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    customEffort.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    // Spare height belongs to the wrapping explanation, not between rows.
    fields.setContentHuggingPriority(.defaultHigh, for: .vertical)

    let save = NSButton(
      title: localized("assistant.save", "Save"), target: self, action: #selector(save(_:)))
    save.keyEquivalent = "\r"
    let test = NSButton(
      title: localized("assistant.test", "Review Example"), target: self,
      action: #selector(test(_:)))
    let buttons = NSStackView(views: [test, save])

    let stack = NSStackView(views: [explanation, enabled, fields, status, buttons])
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
    let field = NSTextField(labelWithString: text)
    field.textColor = VisualStyle.Color.secondary
    return field
  }

  /// What the fields currently say, whether or not it has been saved.
  var settings: AssistantSettings {
    AssistantSettings(
      isEnabled: enabled.state == .on,
      endpoint: URL(string: endpoint.stringValue.trimmingCharacters(in: .whitespaces))
        ?? AssistantSettings.defaultEndpoint,
      model: model.stringValue.trimmingCharacters(in: .whitespaces),
      apiKey: key.stringValue.trimmingCharacters(in: .whitespaces),
      effort: chosenEffort
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
      editor.suggestExpression(nil)
      status.stringValue = "Review the synthetic source scope. Send is a separate action."
    } catch { status.stringValue = "The synthetic example cannot be prepared." }
  }

  static func message(for error: any Error) -> String {
    switch error {
    case AssistantError.disallowedURL:
      return localized(
        "assistant.error.address",
        "The address must start with https://, or name this Mac for a model running on it.")
    case AssistantError.unexpectedStatus(let status):
      return String(
        format: localized("assistant.error.status", "The address answered with status %lld."),
        status)
    case AssistantError.payloadTooLarge, AssistantError.malformedPayload:
      return localized(
        "assistant.error.reply", "The address answered with something Ganit could not read.")
    case let urlError as URLError where urlError.code == .timedOut:
      return localized(
        "assistant.error.timeout",
        "The address is still working. Wait a moment and try again.")
    default:
      return error.localizedDescription
    }
  }
}

extension AssistantSettingsController: NSWindowDelegate {
  public func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === exampleWindow else { return }
    (window.contentViewController as? SheetEditorViewController)?.stopCalculation(nil)
    exampleWindow = nil
  }
}
