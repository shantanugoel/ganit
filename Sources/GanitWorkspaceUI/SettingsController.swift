import AppKit
import GanitEditorUI

/// The app-level switches Settings shows, so a person can find them in one
/// place rather than scattered across menus.
public struct SettingsState: Equatable, Sendable {
  public var staysInMenuBar: Bool
  public var spotlightTitles: Bool
  public var quickGanitStartsEmpty: Bool
  public var automaticExchangeRates: Bool
  public var automaticUpdates: Bool
  public var completesWhileTyping: Bool

  public init(
    staysInMenuBar: Bool,
    spotlightTitles: Bool,
    quickGanitStartsEmpty: Bool,
    automaticExchangeRates: Bool,
    automaticUpdates: Bool,
    completesWhileTyping: Bool
  ) {
    self.staysInMenuBar = staysInMenuBar
    self.spotlightTitles = spotlightTitles
    self.quickGanitStartsEmpty = quickGanitStartsEmpty
    self.automaticExchangeRates = automaticExchangeRates
    self.automaticUpdates = automaticUpdates
    self.completesWhileTyping = completesWhileTyping
  }
}

/// A single Settings window of app-wide preferences. Changes take effect as
/// they are clicked, the same as the matching menu items.
@MainActor
public final class SettingsController: NSViewController {
  public private(set) var state: SettingsState
  private let didChange: (SettingsState) -> Void
  private let autocomplete = NSButton(
    checkboxWithTitle: localized("settings.autocomplete", "Autocomplete while typing"),
    target: nil, action: nil)
  private let menuBar = NSButton(
    checkboxWithTitle: localized("settings.menuBar", "Stay in the menu bar"),
    target: nil, action: nil)
  private let spotlight = NSButton(
    checkboxWithTitle: localized("settings.spotlight", "Show sheet titles in Spotlight"),
    target: nil, action: nil)
  private let quickEmpty = NSButton(
    checkboxWithTitle: localized("settings.quickEmpty", "Quick Ganit starts empty"),
    target: nil, action: nil)
  private let rates = NSButton(
    checkboxWithTitle: localized("settings.rates", "Update exchange rates automatically"),
    target: nil, action: nil)
  private let updates = NSButton(
    checkboxWithTitle: localized("settings.updates", "Check for updates automatically"),
    target: nil, action: nil)

  public init(state: SettingsState, didChange: @escaping (SettingsState) -> Void) {
    self.state = state
    self.didChange = didChange
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let boxes = [autocomplete, menuBar, spotlight, quickEmpty, rates, updates]
    for box in boxes {
      box.target = self
      box.action = #selector(changed(_:))
    }
    sync()

    let explanation = NSTextField(
      wrappingLabelWithString: localized(
        "settings.explanation",
        "These are the same choices as in the menus. Assistant… and Quick Ganit’s shortcut keep their own windows."
      )
    )
    explanation.textColor = VisualStyle.Color.secondary

    let tour = NSButton(
      title: localized("settings.showTour", "Show Tour"),
      target: nil,
      action: #selector(ApplicationCommands.showTour(_:))
    )
    tour.keyEquivalent = ""

    let stack = NSStackView(views: [explanation] + boxes + [tour])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.related
    let margin = VisualStyle.Spacing.window
    stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      explanation.widthAnchor.constraint(equalToConstant: 380),
    ])
    view = container
  }

  public func show(_ state: SettingsState) {
    self.state = state
    if isViewLoaded {
      sync()
    }
  }

  private func sync() {
    autocomplete.state = state.completesWhileTyping ? .on : .off
    menuBar.state = state.staysInMenuBar ? .on : .off
    spotlight.state = state.spotlightTitles ? .on : .off
    quickEmpty.state = state.quickGanitStartsEmpty ? .on : .off
    rates.state = state.automaticExchangeRates ? .on : .off
    updates.state = state.automaticUpdates ? .on : .off
  }

  @objc func changed(_ sender: NSButton) {
    state.completesWhileTyping = autocomplete.state == .on
    state.staysInMenuBar = menuBar.state == .on
    state.spotlightTitles = spotlight.state == .on
    state.quickGanitStartsEmpty = quickEmpty.state == .on
    state.automaticExchangeRates = rates.state == .on
    state.automaticUpdates = updates.state == .on
    didChange(state)
  }
}
