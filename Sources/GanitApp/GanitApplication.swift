import AppIntents
import AppKit
import GanitData
import GanitDiagnostics
import GanitDocuments
import GanitEditorUI
import GanitQuickUI
import GanitSystemIntegration
import GanitWorkspaceUI
import Sparkle

#if !arch(arm64)
  #error("Ganit supports Apple silicon only.")
#endif

@main
@MainActor
final class GanitApplication: NSObject, NSApplicationDelegate, ApplicationCommands,
  NSMenuItemValidation, SheetOpening
{
  private static let shortcutDefaultsKey = "QuickGanitShortcut"
  private static let startsEmptyDefaultsKey = "QuickGanitStartsEmpty"
  private static let manualExchangeRatesDefaultsKey = "ExchangeRatesUpdateManually"
  private static var retainedDelegate: GanitApplication?
  private var workspace: Workspace?
  private var quickPanel: QuickPanelController?
  private var quickBufferStore: TextDocumentStore?
  private var rateRefresher: RateRefresher?
  private var serviceProvider: ExpressionServiceProvider?
  private let spotlight = SpotlightTitleIndex()
  private static let spotlightDefaultsKey = "SpotlightIndexesSheetTitles"
  private static let menuBarDefaultsKey = "GanitStaysInMenuBar"
  private var statusItem: NSStatusItem?
  private var shortcutWindow: NSWindow?
  private var assistantWindow: NSWindow?
  private var help: HelpWindowController?
  private var releaseNotes: ReleaseNotesWindowController?
  private var settingsWindow: NSWindow?
  private var tourSheet: NSWindow?
  /// The assistant's settings, read once so that asking about a line does not
  /// go to the keychain every time.
  private var assistantSettings = AssistantSettings.load()
  private lazy var hotKey = GlobalHotKey { [weak self] in
    self?.toggleQuickGanit()
  }

  static func main() {
    let application = NSApplication.shared
    let delegate = GanitApplication()

    retainedDelegate = delegate
    application.delegate = delegate
    MainMenu.install(in: application)
    application.setActivationPolicy(.regular)
    application.run()
    retainedDelegate = nil
  }

  /// Opens the library before AppKit restores windows that need it.
  func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      let root = try SheetLibrary.applicationSupportRoot()
      let workspace = try Workspace(
        library: try SheetLibrary(root: root),
        definitions: TextDocumentStore(url: root.appending(path: "Definitions.txt"))
      )
      self.workspace = workspace
      quickBufferStore = TextDocumentStore(url: root.appending(path: "QuickBuffer.txt"))
      let refresher = RateRefresher(
        store: try RateSnapshotStore.applicationSupport(),
        isAutomatic: !UserDefaults.standard.bool(forKey: Self.manualExchangeRatesDefaultsKey)
      )
      workspace.currencyRates = refresher.rates
      refresher.ratesDidChange = { [weak self] rates in
        self?.workspace?.currencyRates = rates
        self?.quickPanel?.editor.setCurrencyRates(rates)
      }
      workspace.definitionsDidChange = { [weak self] definitions in
        self?.quickPanel?.editor.setDefinitions(definitions)
      }
      workspace.askAssistant = { [weak self] line in
        await self?.assistantAnswer(to: line) ?? nil
      }
      workspace.openHelp = { [weak self] id in
        self?.showHelp(topicID: id)
      }
      rateRefresher = refresher
      workspace.library.sheetsDidChange = { [weak self] in
        self?.updateSpotlight()
      }
      updateSpotlight()
    } catch {
      NSApplication.shared.presentError(error)
      NSApplication.shared.terminate(nil)
    }
  }

  /// Opens the most recent sheet when no window was restored.
  func applicationDidFinishLaunching(_ notification: Notification) {
    let serviceProvider = ExpressionServiceProvider { [weak self] in
      ExpressionCalculation(rates: self?.rateRefresher?.rates ?? .none)
    }
    self.serviceProvider = serviceProvider
    NSApplication.shared.servicesProvider = serviceProvider
    updateMenuBarItem()
    if let data = UserDefaults.standard.data(forKey: Self.shortcutDefaultsKey),
      let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    {
      try? hotKey.register(shortcut)
    }
    // `--quick-ganit` opens Quick Ganit instead of a sheet, as when launched
    // from a script with `open -a Ganit --args --quick-ganit`.
    if CommandLine.arguments.contains("--quick-ganit") {
      showQuickGanit(nil)
      return
    }
    if workspace?.windows.isEmpty == true {
      openMostRecentSheet()
    }
    NSApplication.shared.activate()
    if !GanitPreferences.hasCompletedTour {
      showTour(nil)
    }
  }

  /// Ganit keeps running without windows so Quick Ganit's shortcut works.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Clicking the Dock icon without workspace windows opens the most recent
  /// sheet.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if workspace?.windows.isEmpty == true {
      openMostRecentSheet()
    }
    return true
  }

  private func openMostRecentSheet() {
    do {
      try workspace?.openMostRecentSheet()
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  /// Opens a window with a new sheet when no workspace window handles the
  /// command.
  @objc func newSheet(_ sender: Any?) {
    do {
      try workspace?.openNewSheet(source: "")
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  /// Answers `ganit://` callback URLs, and imports sheets opened from Finder
  /// and shows each in a window.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == CalculationCallback.scheme {
      let calculation = ExpressionCalculation(rates: rateRefresher?.rates ?? .none)
      if let response = (try? CalculationCallback(url: url))?.response(using: calculation) {
        NSWorkspace.shared.open(response)
      }
    }
    guard let workspace else {
      return
    }
    for url in urls where url.isFileURL {
      do {
        workspace.openWindow(showing: try workspace.importSheet(from: url))
      } catch {
        application.presentError(error)
      }
    }
  }

  /// Opens the definitions sheet, whose variables and units every sheet
  /// reads.
  @objc func showDefinitions(_ sender: Any?) {
    do {
      try workspace?.openDefinitions()
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  /// Opens the scratch sheet, the one sheet every library has.
  @objc func showScratch(_ sender: Any?) {
    do {
      try workspace?.openScratch()
      NSApplication.shared.activate()
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  /// Brings the current workspace window forward, or opens the most recent
  /// sheet when none is open.
  @objc func showWorkspaceWindow(_ sender: Any?) {
    do {
      try workspace?.showCurrentWindow()
      NSApplication.shared.activate()
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  // MARK: The menu bar

  /// Puts Ganit in the menu bar, or takes it out.
  @objc func toggleMenuBarItem(_ sender: Any?) {
    UserDefaults.standard.set(
      !UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey), forKey: Self.menuBarDefaultsKey)
    updateMenuBarItem()
  }

  /// A short menu of the things worth reaching for without a window: the
  /// current window, the scratch sheet, Quick Ganit, and a new sheet.
  private func updateMenuBarItem() {
    guard UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey) else {
      statusItem.map(NSStatusBar.system.removeStatusItem)
      statusItem = nil
      return
    }
    guard statusItem == nil else {
      return
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(
      systemSymbolName: VisualStyle.Symbol.menuBar, accessibilityDescription: "Ganit")
    let menu = NSMenu()
    for (title, action) in [
      (menuBarTitle("menu.showWindow", "Show Window"), #selector(showWorkspaceWindow(_:))),
      (menuBarTitle("menu.scratch", "Scratch"), #selector(showScratch(_:))),
      (menuBarTitle("menu.quickGanit", "Quick Ganit"), #selector(showQuickGanit(_:))),
      (menuBarTitle("menu.newSheet", "New Sheet"), #selector(newSheet(_:))),
    ] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    menu.addItem(
      withTitle: menuBarTitle("menu.quit", "Quit Ganit"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: ""
    )
    item.menu = menu
    statusItem = item
  }

  private func menuBarTitle(
    _ key: StaticString,
    _ defaultValue: String.LocalizationValue
  ) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: .main)
  }

  // MARK: Quick Ganit

  @objc func showQuickGanit(_ sender: Any?) {
    quickGanit()?.show()
  }

  @objc func showQuickGanitShortcut(_ sender: Any?) {
    if let shortcutWindow {
      shortcutWindow.makeKeyAndOrderFront(nil)
      return
    }
    let settings = ShortcutSettingsController(hotKey: hotKey, menu: NSApplication.shared.mainMenu) {
      shortcut in
      let defaults = UserDefaults.standard
      if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
        defaults.set(data, forKey: Self.shortcutDefaultsKey)
      } else {
        defaults.removeObject(forKey: Self.shortcutDefaultsKey)
      }
    }
    let window = NSWindow(contentViewController: settings)
    window.title = String(
      localized: "menu.quickGanitShortcut", defaultValue: "Quick Ganit Shortcut…", bundle: .main)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    shortcutWindow = window
  }

  // MARK: About

  /// The standard About panel, with who made Ganit and where to find it.
  @objc func showAbout(_ sender: Any?) {
    NSApplication.shared.orderFrontStandardAboutPanel(
      options: [.credits: AboutCredits.attributedString()]
    )
  }

  /// One window for the app-wide switches that also live in the menus.
  @objc func showSettings(_ sender: Any?) {
    if let settingsWindow {
      (settingsWindow.contentViewController as? SettingsController)?.show(currentSettings())
      settingsWindow.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SettingsController(state: currentSettings()) { [weak self] state in
      self?.apply(state)
    }
    let window = NSWindow(contentViewController: controller)
    window.title = String(localized: "menu.settings", defaultValue: "Settings", bundle: .main)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    settingsWindow = window
  }

  private func currentSettings() -> SettingsState {
    SettingsState(
      staysInMenuBar: UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey),
      spotlightTitles: UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey),
      quickGanitStartsEmpty: UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey),
      automaticExchangeRates: rateRefresher?.isAutomatic == true,
      automaticUpdates: checksForUpdatesAutomatically,
      completesWhileTyping: GanitPreferences.completesWhileTyping
    )
  }

  private func apply(_ settings: SettingsState) {
    if UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey) != settings.staysInMenuBar {
      toggleMenuBarItem(nil)
    }
    if UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey) != settings.spotlightTitles {
      toggleSpotlightTitles(nil)
    }
    if UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)
      != settings.quickGanitStartsEmpty
    {
      toggleQuickGanitStartsEmpty(nil)
    }
    if (rateRefresher?.isAutomatic == true) != settings.automaticExchangeRates {
      toggleAutomaticExchangeRateUpdates(nil)
    }
    if checksForUpdatesAutomatically != settings.automaticUpdates {
      toggleAutomaticUpdateChecks(nil)
    }
    GanitPreferences.completesWhileTyping = settings.completesWhileTyping
  }

  /// The first-run walkthrough, or the same steps from Settings or Help.
  @objc func showTour(_ sender: Any?) {
    if tourSheet != nil {
      return
    }
    guard
      let parent =
        workspace?.windows.first(where: { $0.window?.isVisible == true })?.window
        ?? workspace?.windows.first?.window
    else {
      return
    }
    let tour = TourController { [weak self] in
      GanitPreferences.hasCompletedTour = true
      self?.tourSheet = nil
    }
    let sheet = NSWindow(contentViewController: tour)
    sheet.styleMask = [.titled]
    sheet.title = String(
      localized: "tour.title", defaultValue: "Welcome to Ganit", bundle: .main)
    parent.beginSheet(sheet)
    tourSheet = sheet
  }

  // MARK: Help

  /// Opens the searchable grammar and function reference.
  @objc func showHelp(_ sender: Any?) {
    showHelp(topicID: nil)
  }

  func showHelp(topicID: String?) {
    if help == nil {
      help = HelpWindowController()
    }
    help?.show(topicID: topicID)
  }

  /// Opens the changelog that shipped with this copy of Ganit.
  @objc func showReleaseNotes(_ sender: Any?) {
    if releaseNotes == nil {
      let text =
        ReleaseNotesWindowController.text(in: .main)
        ?? String(
          localized: "releaseNotes.missing",
          defaultValue: "Release notes were not included in this copy of Ganit.",
          bundle: .main
        )
      releaseNotes = ReleaseNotesWindowController(text: text)
    }
    releaseNotes?.window?.makeKeyAndOrderFront(nil)
  }

  // MARK: The assistant

  /// Sets up where Ganit asks about the lines it cannot work out.
  @objc func showAssistantSettings(_ sender: Any?) {
    if let assistantWindow {
      assistantWindow.makeKeyAndOrderFront(nil)
      return
    }
    let settings = AssistantSettingsController(settings: assistantSettings) { [weak self] saved in
      saved.save()
      self?.assistantSettings = saved
    }
    let window = NSWindow(contentViewController: settings)
    window.title = String(
      localized: "menu.assistant", defaultValue: "Assistant…", bundle: .main)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    assistantWindow = window
  }

  /// Asks the configured model about a line, or answers nothing when no
  /// assistant is set up or the request fails. A line Ganit cannot work out is
  /// already shown as one, so a failed request needs no second complaint.
  private func assistantAnswer(to line: String) async -> String? {
    let settings = assistantSettings
    guard settings.isReady else {
      return nil
    }
    return try? await Assistant(settings: settings).answer(to: line)
  }

  /// Completes function and keyword names while typing, or not.
  @objc func toggleAutocomplete(_ sender: Any?) {
    GanitPreferences.completesWhileTyping.toggle()
  }

  /// Chooses whether Quick Ganit restores its last text or starts empty.
  @objc func toggleQuickGanitStartsEmpty(_ sender: Any?) {
    let startsEmpty = !UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)
    UserDefaults.standard.set(startsEmpty, forKey: Self.startsEmptyDefaultsKey)
    if let quickPanel {
      quickPanel.startsEmpty = startsEmpty
    } else if startsEmpty {
      try? quickBufferStore?.clear()
    }
  }

  // MARK: Exchange rates

  /// Requests exchange rates now, at most once a minute.
  @objc func updateExchangeRates(_ sender: Any?) {
    rateRefresher?.refreshNow()
  }

  /// Turns automatic daily exchange-rate updates on or off.
  @objc func toggleAutomaticExchangeRateUpdates(_ sender: Any?) {
    guard let rateRefresher else {
      return
    }
    rateRefresher.isAutomatic.toggle()
    UserDefaults.standard.set(
      !rateRefresher.isAutomatic, forKey: Self.manualExchangeRatesDefaultsKey)
  }

  // MARK: Updates

  /// Asks about updates, and installs the one it is told to; see ADR 0013.
  /// Nothing is asked until the reader asks, either by choosing Check for
  /// Updates… or by turning the automatic check on, because an app that
  /// phones home on its own is the thing Ganit says it is not.
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  /// Whether Ganit looks for a new version once a day on its own.
  private var checksForUpdatesAutomatically: Bool {
    get { updaterController.updater.automaticallyChecksForUpdates }
    set { updaterController.updater.automaticallyChecksForUpdates = newValue }
  }

  @objc func checkForUpdates(_ sender: Any?) {
    updaterController.checkForUpdates(sender)
  }

  /// Turns the daily check on or off. It is off in a fresh copy of Ganit.
  @objc func toggleAutomaticUpdateChecks(_ sender: Any?) {
    checksForUpdatesAutomatically.toggle()
  }

  // MARK: Problem reports

  /// Saves a problem report describing the app and system. The frontmost
  /// sheet's text is included only when the user ticks the box.
  @objc func reportProblem(_ sender: Any?) {
    let sheetText =
      (NSApplication.shared.orderedWindows.lazy.compactMap {
        $0.windowController as? WorkspaceWindowController
      }.first?.editor?.textView.string)
    let include = NSButton(
      checkboxWithTitle: String(
        localized: "report.includeSheet", defaultValue: "Include the current sheet's text",
        bundle: .main),
      target: nil, action: nil)
    include.isEnabled = sheetText?.isEmpty == false
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Ganit Problem Report.txt"
    panel.allowedContentTypes = [.plainText]
    panel.accessoryView = include
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    let bundle = Bundle.main.infoDictionary ?? [:]
    let onOff = { (isOn: Bool) in isOn ? "On" : "Off" }
    let report = ProblemReport(
      appVersion:
        "\(bundle["CFBundleShortVersionString"] ?? "?") (\(bundle["CFBundleVersion"] ?? "?"))",
      systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      hardwareModel: ProblemReport.hardwareModelIdentifier,
      settings: [
        "Update exchange rates automatically": onOff(rateRefresher?.isAutomatic == true),
        "Show sheet titles in Spotlight": onOff(
          UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey)),
        "Quick Ganit starts empty": onOff(
          UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)),
        "Stay in the menu bar": onOff(
          UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey)),
        "Assistant": assistantSettings.isReady
          ? assistantSettings.endpoint.host() ?? "on" : onOff(false),
        "Exchange rates published": rateRefresher?.rates.observationDate ?? "none",
      ],
      sheetCount: (try? workspace?.library.index.summaries().count) ?? 0,
      reproduction: include.state == .on ? sheetText : nil
    )
    do {
      try Data(report.text.utf8).write(to: url, options: .atomic)
    } catch {
      NSApplication.shared.presentError(error)
    }
  }

  // MARK: Spotlight

  /// Turns the title-only Spotlight index on or off.
  @objc func toggleSpotlightTitles(_ sender: Any?) {
    let isOn = !UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey)
    UserDefaults.standard.set(isOn, forKey: Self.spotlightDefaultsKey)
    if isOn {
      updateSpotlight()
    } else {
      spotlight.removeAll()
    }
  }

  private func updateSpotlight() {
    guard UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey),
      let summaries = try? workspace?.library.index.summaries()
    else {
      return
    }
    spotlight.update(summaries)
  }

  /// Opens the sheet a Spotlight result names.
  func application(
    _ application: NSApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
  ) -> Bool {
    guard let id = SpotlightTitleIndex.sheetID(from: userActivity), let workspace else {
      return false
    }
    workspace.reveal(id)
    return true
  }

  /// Shows the sheet the Open Sheet intent names, answering whether the
  /// library has one.
  func revealSheet(titled title: String) -> Bool {
    guard let workspace, let id = try? workspace.library.index.sheet(titled: title) else {
      return false
    }
    workspace.reveal(id)
    NSApplication.shared.activate()
    return true
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(toggleSpotlightTitles(_:)):
      menuItem.state = UserDefaults.standard.bool(forKey: Self.spotlightDefaultsKey) ? .on : .off
    case #selector(toggleMenuBarItem(_:)):
      menuItem.state = UserDefaults.standard.bool(forKey: Self.menuBarDefaultsKey) ? .on : .off
    case #selector(toggleAutomaticUpdateChecks(_:)):
      menuItem.state = checksForUpdatesAutomatically ? .on : .off
    case #selector(toggleQuickGanitStartsEmpty(_:)):
      menuItem.state = UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey) ? .on : .off
    case #selector(toggleAutocomplete(_:)):
      menuItem.state = GanitPreferences.completesWhileTyping ? .on : .off
    case #selector(toggleAutomaticExchangeRateUpdates(_:)):
      menuItem.state = rateRefresher?.isAutomatic == true ? .on : .off
    case #selector(updateExchangeRates(_:)):
      return rateRefresher?.isRequesting == false
    default:
      break
    }
    return true
  }

  private func toggleQuickGanit() {
    quickGanit()?.toggle()
  }

  /// The Quick Ganit panel, created on first use.
  private func quickGanit() -> QuickPanelController? {
    if quickPanel == nil {
      quickPanel = try? QuickPanelController(
        context: SheetPreferences.standard.evaluationContext(
          currencyRates: rateRefresher?.rates ?? .none),
        store: quickBufferStore,
        startsEmpty: UserDefaults.standard.bool(forKey: Self.startsEmptyDefaultsKey)
      )
      quickPanel?.promote = { [weak self] source in
        try self?.workspace?.openNewSheet(source: source)
        NSApplication.shared.activate()
      }
      // A quick calculation reads the definitions sheet, and asks the
      // assistant, like any other.
      if let definitions = workspace?.definitions {
        quickPanel?.editor.setDefinitions(definitions)
      }
      quickPanel?.editor.askAssistant = { [weak self] line in
        await self?.assistantAnswer(to: line) ?? nil
      }
      quickPanel?.editor.openHelp = { [weak self] id in
        self?.showHelp(topicID: id)
      }
    }
    return quickPanel
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }
}
