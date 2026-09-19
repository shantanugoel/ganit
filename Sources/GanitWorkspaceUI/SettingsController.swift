import AppKit
import GanitEditorUI

/// Whether windows follow the Mac's light or dark appearance or keep one.
public enum AppearanceChoice: String, CaseIterable, Sendable {
  case system, light, dark

  /// The appearance to give `NSApplication`, where `nil` follows the Mac.
  public var appearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  var title: String {
    switch self {
    case .system: localized("settings.appearance.system", "System")
    case .light: localized("settings.appearance.light", "Light")
    case .dark: localized("settings.appearance.dark", "Dark")
    }
  }
}

/// The app-level switches Settings shows, so a person can find them in one
/// place rather than scattered across menus.
public struct SettingsState: Equatable, Sendable {
  public var staysInMenuBar: Bool
  public var spotlightTitles: Bool
  public var quickGanitStartsEmpty: Bool
  public var automaticExchangeRates: Bool
  public var automaticUpdates: Bool
  public var completesWhileTyping: Bool
  public var appearance: AppearanceChoice
  public var opensAtLogin: Bool

  public init(
    staysInMenuBar: Bool,
    spotlightTitles: Bool,
    quickGanitStartsEmpty: Bool,
    automaticExchangeRates: Bool,
    automaticUpdates: Bool,
    completesWhileTyping: Bool,
    appearance: AppearanceChoice,
    opensAtLogin: Bool
  ) {
    self.staysInMenuBar = staysInMenuBar
    self.spotlightTitles = spotlightTitles
    self.quickGanitStartsEmpty = quickGanitStartsEmpty
    self.automaticExchangeRates = automaticExchangeRates
    self.automaticUpdates = automaticUpdates
    self.completesWhileTyping = completesWhileTyping
    self.appearance = appearance
    self.opensAtLogin = opensAtLogin
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
  private let login = NSButton(
    checkboxWithTitle: localized("settings.login", "Open Ganit at login"),
    target: nil, action: nil)
  private let appearance = NSPopUpButton()

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
    let boxes = [autocomplete, login, menuBar, spotlight, quickEmpty, rates, updates]
    for box in boxes {
      box.target = self
      box.action = #selector(changed(_:))
    }
    appearance.addItems(withTitles: AppearanceChoice.allCases.map(\.title))
    appearance.target = self
    appearance.action = #selector(changed(_:))
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

    let appearanceRow = NSStackView(views: [
      NSTextField(labelWithString: localized("settings.appearance", "Appearance:")), appearance,
    ])

    let stack = NSStackView(views: [explanation, appearanceRow] + boxes + [tour])
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
    login.state = state.opensAtLogin ? .on : .off
    menuBar.state = state.staysInMenuBar ? .on : .off
    spotlight.state = state.spotlightTitles ? .on : .off
    quickEmpty.state = state.quickGanitStartsEmpty ? .on : .off
    rates.state = state.automaticExchangeRates ? .on : .off
    updates.state = state.automaticUpdates ? .on : .off
    appearance.selectItem(at: AppearanceChoice.allCases.firstIndex(of: state.appearance) ?? 0)
  }

  @objc func changed(_ sender: NSControl) {
    state.completesWhileTyping = autocomplete.state == .on
    state.opensAtLogin = login.state == .on
    state.staysInMenuBar = menuBar.state == .on
    state.spotlightTitles = spotlight.state == .on
    state.quickGanitStartsEmpty = quickEmpty.state == .on
    state.automaticExchangeRates = rates.state == .on
    state.automaticUpdates = updates.state == .on
    state.appearance = AppearanceChoice.allCases[max(appearance.indexOfSelectedItem, 0)]
    didChange(state)
  }
}
