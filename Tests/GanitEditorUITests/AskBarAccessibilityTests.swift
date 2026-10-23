import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import Testing

@testable import GanitEditorUI

/// The bar's disclosures are the only Ask buttons that change the window
/// hierarchy, and opening one used to leave the card unshown for a whole run
/// loop pass - long enough for an accessibility press to give up on it.
@MainActor
struct AskBarAccessibilityTests {
  private static var windows: [NSWindow] = []

  private func context() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
  }

  private func editor(_ text: String) async throws -> SheetEditorViewController {
    let editor = SheetEditorViewController(text: text, context: try context())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    // A popover needs a window that is really on screen, or AppKit refuses to
    // show it and the test would pass for the wrong reason.
    window.setIsVisible(true)
    window.orderFrontRegardless()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return editor
  }

  private func settle() async {
    for _ in 0..<8 { await Task.yield() }
  }

  private func bar(_ source: String) async throws -> SheetEditorViewController {
    let editor = try await editor(source)
    var settings = AssistantSettings(
      isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "synthetic")
    settings.repairAttempts = 0
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(
        transport: OneShotTransport(Data("The answer is five.".utf8))),
      settings: settings)
    editor.suggestionSession.prepare(autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.rejectedInspection != nil)
    return editor
  }

  @Test func theDisclosureOpensAndClosesWithoutWaitingForAnAnimation() async throws {
    let editor = try await bar("Add two and three.")
    let controls = editor.askBarButtons
    for title in ["Context ▸", "Show what the model meant"] {
      guard let button = controls.first(where: { $0.title == title }) else {
        Issue.record("Expected a \(title) button")
        return
      }
      // The same entry point VoiceOver uses, not a stand-in click.
      #expect(button.accessibilityPerformPress(), "\(title) refused an accessibility press")
      await settle()
      let popover = try #require(editor.askBarPopover, "\(title) opened nothing")
      #expect(popover.isShown, "\(title) did not open its card")
      #expect(!popover.animates, "\(title) still animates while an assistive press waits")
      popover.close()
      await settle()
    }
  }
}

private actor OneShotTransport: SuggestionTransport {
  private var reply: Data?
  init(_ reply: Data) { self.reply = reply }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    if let reply {
      self.reply = nil
      return reply
    }
    return try await withCheckedThrowingContinuation { _ in }
  }
}
