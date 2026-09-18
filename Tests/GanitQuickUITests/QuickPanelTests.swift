import AppKit
import Carbon.HIToolbox
import Foundation
import GanitDocuments
import GanitEngine
import Testing

@testable import GanitEditorUI
@testable import GanitQuickUI

@MainActor
@Suite
struct QuickPanelTests {
  @Test
  func isAStandardFocusableFloatingPanelThatKeepsTextWhenHidden() async throws {
    let controller = QuickPanelController(context: try context())
    let panel = try #require(controller.window as? NSPanel)
    defer { controller.hide() }

    #expect(panel.styleMask.contains(.titled) && panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.isFloatingPanel && panel.level == .floating && !panel.hidesOnDeactivate)
    #expect(panel.canBecomeKey)
    #expect(panel.collectionBehavior.isSuperset(of: [.moveToActiveSpace, .fullScreenAuxiliary]))

    controller.show()
    #expect(controller.isShown)
    #expect(panel.firstResponder === controller.editor.textView)
    let pointerScreen = NSScreen.screens.first {
      NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
    }
    if let pointerScreen {
      #expect(
        pointerScreen.visibleFrame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)))
    }
    controller.editor.textView.insertText(
      "6 * 7", replacementRange: NSRange(location: 0, length: 0))

    // Escape in the text reaches the panel, which hides without clearing.
    controller.editor.textView.complete(nil)
    #expect(!controller.isShown)
    controller.show()
    #expect(controller.editor.textView.string == "6 * 7")

    // Kept text is selected, so what comes next replaces it.
    #expect(controller.editor.textView.selectedRange() == NSRange(location: 0, length: 5))
    controller.editor.textView.insertText(
      "18% of 2499", replacementRange: controller.editor.textView.selectedRange())
    #expect(controller.editor.textView.string == "18% of 2499")
  }

  @Test
  func hidesWhenAnotherGanitWindowBecomesKey() async throws {
    let controller = QuickPanelController(context: try context())
    defer { controller.hide() }
    controller.show()
    #expect(controller.isShown)

    let workspace = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    workspace.isReleasedWhenClosed = false
    defer { workspace.orderOut(nil) }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: workspace)
    #expect(!controller.isShown)
  }

  @Test
  func formatsAndRecordsShortcutsWithModifiers() throws {
    let shortcut = KeyboardShortcut(
      keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .option, .shift], key: "K")
    #expect(shortcut.displayName == "⌥⇧⌘K")
    #expect(shortcut.carbonModifiers == UInt32(cmdKey | optionKey | shiftKey))
    #expect(KeyboardShortcut.suggested.displayName == "⌥Space")

    let decoded = try JSONDecoder().decode(
      KeyboardShortcut.self, from: JSONEncoder().encode(shortcut))
    #expect(decoded == shortcut)

    func event(_ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
        context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
        keyCode: UInt16(kVK_ANSI_K)
      )
    }
    #expect(KeyboardShortcut(event: try #require(event([]))) == nil)
    #expect(
      KeyboardShortcut(event: try #require(event([.control, .capsLock])))?.displayName == "⌃K")
  }

  @Test
  func reportsMenuAndSystemConflicts() {
    let menu = NSMenu()
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu()
    file.submenu?.addItem(withTitle: "New Sheet", action: nil, keyEquivalent: "n")
    menu.addItem(file)

    let newSheet = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command], key: "N")
    #expect(newSheet.conflicts(in: menu).contains(.menu(title: "New Sheet")))

    let unlikely = KeyboardShortcut(
      keyCode: UInt32(kVK_F19), modifiers: [.command, .option, .control, .shift], key: "F19")
    #expect(unlikely.conflicts(in: menu).isEmpty)

    if let system = KeyboardShortcut.enabledSystemShortcuts().first {
      let shortcut = KeyboardShortcut(
        keyCode: system.keyCode,
        modifiers: carbonFlags(system.modifiers),
        key: "?"
      )
      #expect(shortcut.conflicts(in: nil).contains(.system))
    }
  }

  @Test
  func registersAndUnregistersAGlobalShortcut() throws {
    var fired = 0
    let hotKey = GlobalHotKey { fired += 1 }
    let unlikely = KeyboardShortcut(
      keyCode: UInt32(kVK_F19), modifiers: [.command, .option, .control, .shift], key: "F19")

    try hotKey.register(unlikely)
    #expect(hotKey.shortcut == unlikely)
    // A second registration of the same combination is refused.
    let other = GlobalHotKey {}
    #expect(throws: ShortcutRegistrationError.self) {
      try other.register(unlikely)
    }
    hotKey.unregister()
    #expect(hotKey.shortcut == nil)
    try other.register(unlikely)
    other.unregister()
    #expect(fired == 0)
  }

  @Test
  func settingsShowConflictsAndSaveTheShortcut() throws {
    let hotKey = GlobalHotKey {}
    var saved: [KeyboardShortcut?] = []
    let menu = NSMenu()
    menu.addItem(withTitle: "Duplicate", action: nil, keyEquivalent: "d")
    let settings = ShortcutSettingsController(hotKey: hotKey, menu: menu) { saved.append($0) }
    _ = settings.view
    #expect(settings.candidate == .suggested)

    let duplicate = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: [.command], key: "D")
    settings.select(duplicate)
    let statusText = settings.view.subviews.first?.subviews.compactMap { $0 as? NSTextField }.map(
      \.stringValue)
    #expect(statusText?.contains { $0.contains("Duplicate") } == true)

    let unlikely = KeyboardShortcut(
      keyCode: UInt32(kVK_F18), modifiers: [.command, .option, .control, .shift], key: "F18")
    settings.select(unlikely)
    settings.save(nil)
    #expect(hotKey.shortcut == unlikely)
    #expect(saved == [unlikely])
    settings.remove(nil)
    #expect(hotKey.shortcut == nil)
    #expect(saved == [unlikely, nil])
  }

  private func carbonFlags(_ modifiers: UInt32) -> NSEvent.ModifierFlags {
    [
      (cmdKey, NSEvent.ModifierFlags.command), (optionKey, .option), (controlKey, .control),
      (shiftKey, .shift),
    ]
    .filter { modifiers & UInt32($0.0) != 0 }
    .reduce(into: []) { $0.insert($1.1) }
  }

  private func context() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0),
      calendar: Calendar(identifier: .gregorian),
      timeZone: try #require(TimeZone(identifier: "UTC"))
    )
  }
}

@MainActor
@Suite
struct QuickPanelGeometryTests {
  @Test
  func opensOnTheDisplayWithThePointerAndStaysOnIt() {
    // A main display and a smaller one to its left, below the menu bar line.
    let screens: [(frame: NSRect, visibleFrame: NSRect)] = [
      (
        NSRect(x: 0, y: 0, width: 1_512, height: 982), NSRect(x: 0, y: 0, width: 1_512, height: 944)
      ),
      (
        NSRect(x: -1_280, y: -200, width: 1_280, height: 800),
        NSRect(x: -1_280, y: -200, width: 1_280, height: 775)
      ),
    ]
    let left = QuickPanelController.visibleFrame(
      containing: NSPoint(x: -600, y: 100), screens: screens)
    #expect(left == screens[1].visibleFrame)
    #expect(
      QuickPanelController.visibleFrame(containing: NSPoint(x: 5_000, y: 0), screens: screens)
        == nil)

    let size = NSSize(width: 520, height: 220)
    let origin = QuickPanelController.origin(for: size, in: screens[1].visibleFrame)
    #expect(screens[1].visibleFrame.contains(NSRect(origin: origin, size: size)))
    #expect(origin.x == -900)

    // A panel resized taller than a small display keeps its title bar visible.
    let small = NSRect(x: 0, y: 0, width: 800, height: 500)
    let tall = QuickPanelController.origin(for: NSSize(width: 1_000, height: 600), in: small)
    #expect(tall == NSPoint(x: 0, y: 0))
    #expect(
      QuickPanelController.origin(for: NSSize(width: 400, height: 480), in: small)
        == NSPoint(x: 200, y: 20))
  }

  @Test
  func keepsSourceWiderThanAnswersAtItsMinimumSize() throws {
    let controller = QuickPanelController(context: try standardContext())
    let panel = try #require(controller.window)
    controller.show()
    defer { controller.hide() }
    panel.setContentSize(panel.contentMinSize)
    panel.layoutIfNeeded()

    let textView = try #require(controller.editor.textView as? SheetTextView)
    let answers = textView.answerColumnWidth
    #expect(answers >= SheetTextView.answerColumnWidthRange.lowerBound)
    #expect(textView.bounds.width - answers >= answers)
  }
}

@MainActor
@Suite
struct QuickPanelCommandTests {
  @Test
  func commandReturnCopiesTheCurrentOrLastResultAndDismisses() async throws {
    let controller = QuickPanelController(context: try standardContext())
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitQuickTests-\(UUID().uuidString)"))
    controller.editor.resultPasteboard = pasteboard
    let panel = try #require(controller.window)
    controller.show()
    defer { controller.hide() }
    controller.editor.textView.insertText(
      "6 * 7\n2 + 2\n", replacementRange: NSRange(location: 0, length: 0))
    try await waitForAnswers(controller)

    // The insertion point is on the empty last line, so the last result is copied.
    #expect(panel.performKeyEquivalent(with: try commandReturn(panel)))
    #expect(pasteboard.string(forType: .string) == "4")
    #expect(!controller.isShown)

    controller.show()
    controller.editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
    _ = panel.performKeyEquivalent(with: try commandReturn(panel))
    #expect(pasteboard.string(forType: .string) == "42")
  }

  /// The panel shows Command-Return's action beside Keep as Sheet, and says
  /// so when there is nothing to copy.
  @Test
  func showsTheCopyAndCloseActionAndExplainsWhenNothingCanBeCopied() async throws {
    let controller = QuickPanelController(context: try standardContext())
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitQuickTests-\(UUID().uuidString)"))
    controller.editor.resultPasteboard = pasteboard
    controller.show()
    defer { controller.hide() }
    let button = controller.copyButton
    #expect(button.title == "⌘↩ Copy Result and Close")
    #expect(button.window === controller.window)
    #expect(button.toolTip?.contains("Keep as Sheet") == true)

    // `performClick` would spin a nested run loop between concurrent tests.
    NSApp.sendAction(try #require(button.action), to: button.target, from: button)
    #expect(controller.isShown)
    #expect(button.title == "No Result to Copy")

    controller.editor.textView.insertText(
      "6 * 7\n2 + 2", replacementRange: NSRange(location: 0, length: 0))
    try await waitForAnswers(controller)
    NSApp.sendAction(try #require(button.action), to: button.target, from: button)
    #expect(pasteboard.string(forType: .string) == "4")
    #expect(!controller.isShown)
  }

  @Test
  func keepsTheBufferAsASheetAndStartsEmpty() throws {
    let controller = QuickPanelController(context: try standardContext())
    var promoted: [String] = []
    controller.promote = { promoted.append($0) }
    controller.show()
    controller.editor.textView.insertText(
      "rent = 2100", replacementRange: NSRange(location: 0, length: 0))

    controller.keepAsSheet(nil)

    #expect(promoted == ["rent = 2100"])
    #expect(controller.editor.textView.string.isEmpty)
    #expect(!controller.isShown)
  }

  /// Waits for the answers themselves, not merely for an evaluation of the
  /// right shape, and waits long enough for a machine running every other
  /// suite beside this one.
  private func waitForAnswers(_ controller: QuickPanelController) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while await controller.editor.exportedLines().compactMap(\.answer).count < 2,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func commandReturn(_ window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)
      )
    )
  }
}

private func standardContext() throws -> EvaluationContext {
  try EvaluationContext(
    localeIdentifier: "en-US",
    lexingConfiguration: .englishUnitedStates,
    angleMode: .radians,
    precision: PrecisionContext(significantDecimalDigits: 15),
    now: Date(timeIntervalSince1970: 0),
    calendar: Calendar(identifier: .gregorian),
    timeZone: try #require(TimeZone(identifier: "UTC"))
  )
}

@MainActor
@Suite
struct QuickBufferTests {
  private let url = FileManager.default.temporaryDirectory
    .appending(path: "GanitQuickBuffer-\(UUID().uuidString)/QuickBuffer.txt")

  @Test
  func storesTextAtomicallyAndRemovesItWhenEmpty() throws {
    let store = TextDocumentStore(url: url)
    #expect(store.load().isEmpty)
    try store.save("6 * 7\r\n👍🏽")
    #expect(store.load() == "6 * 7\r\n👍🏽")
    try store.save("")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func restoresTheLastBufferInANewPanel() throws {
    let store = TextDocumentStore(url: url)
    let first = QuickPanelController(context: try standardContext(), store: store)
    first.show()
    first.editor.textView.insertText(
      "rent = 2100", replacementRange: NSRange(location: 0, length: 0))
    first.editor.textView.complete(nil)
    #expect(store.load() == "rent = 2100")

    let relaunched = QuickPanelController(context: try standardContext(), store: store)
    #expect(relaunched.editor.textView.string == "rent = 2100")
  }

  @Test
  func startingEmptyClearsStoredTextAndEachShowing() throws {
    let store = TextDocumentStore(url: url)
    try store.save("old")
    let controller = QuickPanelController(
      context: try standardContext(), store: store, startsEmpty: true)
    #expect(controller.editor.textView.string.isEmpty)

    controller.show()
    controller.editor.textView.insertText(
      "scratch", replacementRange: NSRange(location: 0, length: 0))
    controller.hide()
    #expect(store.load().isEmpty)
    controller.show()
    defer { controller.hide() }
    #expect(controller.editor.textView.string.isEmpty)

    controller.startsEmpty = false
    controller.editor.textView.insertText("kept", replacementRange: NSRange(location: 0, length: 0))
    controller.hide()
    #expect(store.load() == "kept")
    controller.startsEmpty = true
    #expect(store.load().isEmpty)
  }
}
