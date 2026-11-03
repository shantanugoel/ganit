import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@testable import GanitEditorUI

/// What the Ask bar says about the sharing level, and the help it opens.
@MainActor
struct AskContextSharingTests {
  private static var windows: [NSWindow] = []

  private func editor(_ text: String, sharing: AssistantContextSharing) async throws
    -> SheetEditorViewController
  {
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
    let editor = SheetEditorViewController(text: text, context: context)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!,
        model: "synthetic", contextSharing: sharing))
    editor.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    editor.suggestionSession.prepare(instruction: "add a tip")
    await editor.suggestionSession.waitUntilIdle()
    return editor
  }

  @Test func theHelpButtonOpensTheAskTopic() async throws {
    let editor = try await editor("bill = 10\nAdd a tip to bill.", sharing: .needed)
    var opened: [String] = []
    editor.openHelp = { opened.append($0) }
    let help = try #require(
      editor.askBarButtons.first { $0.accessibilityLabel() == "Ask Ganit Help" })
    help.performClick(nil)
    #expect(opened == ["grammar.ask"])
  }

  @Test func contextNamesTheIndexAndTheWholeSheet() async throws {
    let names = try await editor("secret = 5\nbill = 10\nAdd a tip to bill.", sharing: .names)
    let namesBody = try #require(names.suggestionSession.preparedBody)
    let indexText = try #require(AskBar.contextSummary(for: namesBody))
    #expect(indexText.contains("Other names shared, without values"))
    #expect(indexText.contains("secret"))
    let sheet = try await editor("secret = 5\nbill = 10\nAdd a tip to bill.", sharing: .sheet)
    let body = try #require(sheet.suggestionSession.preparedBody)
    #expect(SheetSuggestionSession.sharesWholeSheet(body))
    let sheetText = try #require(AskBar.contextSummary(for: body))
    #expect(sheetText.contains("The whole sheet"))
    #expect(!sheet.suggestionSession.message.contains("too large"))
  }

  @Test func aSheetTooLargeToShareWholeSaysSo() async throws {
    let note = "// " + String(repeating: "a", count: 1_000)
    let text = (Array(repeating: note, count: 70) + ["bill = 10", "Add a tip to bill."])
      .joined(separator: "\n")
    let editor = try await editor(text, sharing: .sheet)
    let body = try #require(editor.suggestionSession.preparedBody)
    #expect(!SheetSuggestionSession.sharesWholeSheet(body))
    #expect(editor.suggestionSession.message.contains("too large to share whole"))
  }
}
