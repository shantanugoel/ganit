import AppKit
import GanitData
import GanitEditorUI

/// Sets up the assistant: whether Ganit asks a model about the lines it cannot
/// work out, and where it asks.
///
/// The window says plainly what leaves the Mac, because that is the whole of
/// what someone is agreeing to here.
@MainActor
public final class AssistantSettingsController: NSViewController {
  /// The line the “Try It” button asks about, which is the kind of line the
  /// assistant is for.
  static let example = "10 kg of water in ml"

  private let didSave: (AssistantSettings) -> Void
  private let enabled = NSButton(
    checkboxWithTitle: localized(
      "assistant.enabled", "Ask a model about lines Ganit cannot work out"),
    target: nil,
    action: nil
  )
  private let endpoint = NSTextField(string: "")
  private let model = NSTextField(string: "")
  private let key = NSSecureTextField(string: "")
  private let status = NSTextField(wrappingLabelWithString: "")

  public init(settings: AssistantSettings, didSave: @escaping (AssistantSettings) -> Void) {
    self.didSave = didSave
    super.init(nibName: nil, bundle: nil)
    enabled.state = settings.isEnabled ? .on : .off
    endpoint.stringValue = settings.endpoint.absoluteString
    model.stringValue = settings.model
    key.stringValue = settings.apiKey
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let explanation = NSTextField(
      wrappingLabelWithString: localized(
        "assistant.explanation",
        "The address is any OpenAI-compatible base, such as https://api.openai.com/v1, http://localhost:11434/v1, or https://host/v1. Ganit POSTs that base's chat/completions with the one line it could not work out, and nothing else: not the rest of the sheet, its title, or anything about this Mac. Answers can take a while; the sheet stays editable and shows Asking… until a value arrives, drawn in purple because a model's answer is not a calculation."
      )
    )
    status.textColor = VisualStyle.Color.secondary
    endpoint.setAccessibilityLabel(localized("assistant.address", "Address"))
    model.setAccessibilityLabel(localized("assistant.model", "Model"))
    key.setAccessibilityLabel(localized("assistant.key", "API Key"))
    endpoint.placeholderString = AssistantSettings.defaultEndpoint.absoluteString
    model.placeholderString = AssistantSettings.defaultModel
    key.placeholderString = localized("assistant.keyPlaceholder", "Not needed for a local model")

    let fields = NSGridView(views: [
      [label(localized("assistant.address", "Address")), endpoint],
      [label(localized("assistant.model", "Model")), model],
      [label(localized("assistant.key", "API Key")), key],
    ])
    fields.rowSpacing = VisualStyle.Spacing.related
    fields.columnSpacing = VisualStyle.Spacing.related
    fields.column(at: 0).xPlacement = .trailing
    // Spare height belongs to the wrapping explanation, not between rows.
    fields.setContentHuggingPriority(.defaultHigh, for: .vertical)

    let save = NSButton(
      title: localized("assistant.save", "Save"), target: self, action: #selector(save(_:)))
    save.keyEquivalent = "\r"
    let test = NSButton(
      title: localized("assistant.test", "Try It"), target: self, action: #selector(test(_:)))
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
    view = container
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
      apiKey: key.stringValue.trimmingCharacters(in: .whitespaces)
    )
  }

  @objc func save(_ sender: Any?) {
    didSave(settings)
    view.window?.close()
  }

  /// Asks the example line and shows what comes back, so a wrong address or
  /// key is found here rather than in the middle of a sheet.
  @objc func test(_ sender: Any?) {
    let settings = settings
    status.stringValue = localized("assistant.testing", "Asking…")
    Task { [weak self] in
      let outcome: String
      do {
        let answer = try await Assistant(settings: settings).answer(to: Self.example)
        outcome =
          answer.map { "\(Self.example) → \($0)" }
          ?? localized("assistant.noAnswer", "The model had no answer for that line.")
      } catch {
        outcome = Self.message(for: error)
      }
      self?.status.stringValue = outcome
    }
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
