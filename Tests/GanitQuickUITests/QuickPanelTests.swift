import AppKit
import Carbon.HIToolbox
import Foundation
import GanitEngine
import Testing

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

    controller.show()
    #expect(controller.isShown)
    #expect(panel.firstResponder === controller.editor.textView)
    controller.editor.textView.insertText(
      "6 * 7", replacementRange: NSRange(location: 0, length: 0))

    // Escape in the text reaches the panel, which hides without clearing.
    controller.editor.textView.complete(nil)
    #expect(!controller.isShown)
    controller.show()
    #expect(controller.editor.textView.string == "6 * 7")
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

  private func waitForAnswers(_ controller: QuickPanelController) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.editor.latestEvaluation?.lines.count != 3, ContinuousClock.now < deadline {
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
