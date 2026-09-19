import AppKit
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct CompletionsTests {
  @Test
  func typingAPrefixOffersAFunctionAndTabInsertsIt() async throws {
    let (editor, textView) = try await makeEditor("")
    _ = editor
    textView.completesWhileTyping = true
    textView.insertText("sq", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.offeredCompletions.contains("sqrt(x)"))
    textView.insertTab(nil)
    #expect(textView.string == "sqrt(x)")
    #expect(textView.selectedRange() == NSRange(location: 5, length: 1))
  }

  @Test
  func returnEndsALineUnlessAnArrowPickedACompletion() async throws {
    let (_, textView) = try await makeEditor("")
    textView.completesWhileTyping = true
    textView.insertText("5 min", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.offeredCompletions.contains("min(x, y)"))
    textView.insertNewline(nil)
    #expect(textView.string == "5 min\n")
    #expect(textView.offeredCompletions.isEmpty)

    textView.insertText("sq", replacementRange: textView.selectedRange())
    textView.moveDown(nil)
    textView.insertNewline(nil)
    #expect(textView.string == "5 min\nsqrt(x)")
  }

  @Test
  func aPromptPlaceholderOffersVariablesAndTabClosesIt() async throws {
    let source = "Monthly rent = 2100\nweight = 12\n"
    let (editor, textView) = try await makeEditor(source)
    await editor.scheduler?.waitUntilIdle()
    textView.completesWhileTyping = true
    let end = source.utf16.count
    textView.setSelectedRange(NSRange(location: end, length: 0))
    textView.insertText("ask_assistant(cost of {", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["Monthly rent", "weight"])
    textView.insertText("mo", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["Monthly rent"])
    textView.insertTab(nil)
    #expect(textView.string == source + "ask_assistant(cost of {Monthly rent}")
    #expect(textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0))
    #expect(textView.offeredCompletions.isEmpty)
  }

  @Test
  func escapeDismissesTheListWithoutInserting() async throws {
    let (_, textView) = try await makeEditor("")
    textView.completesWhileTyping = true
    textView.insertText("sq", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.offeredCompletions.contains("sqrt(x)"))
    textView.complete(nil)
    #expect(textView.offeredCompletions.isEmpty)
    #expect(textView.string == "sq")
  }

  @Test
  func tabMovesFromOneCompletedArgumentToTheNext() async throws {
    let (_, textView) = try await makeEditor("")
    textView.completesWhileTyping = true
    textView.insertText("round", replacementRange: NSRange(location: 0, length: 0))
    textView.insertTab(nil)
    #expect(textView.string == "round(x, places)")
    #expect(textView.selectedRange() == NSRange(location: 6, length: 1))
    textView.insertTab(nil)
    #expect(textView.selectedRange() == NSRange(location: 9, length: 6))
  }

  @Test
  func turningAutocompleteOffOffersNothing() async throws {
    let (_, textView) = try await makeEditor("")
    textView.completesWhileTyping = false
    textView.insertText("sq", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.offeredCompletions.isEmpty)
  }

  /// Keeps the window, and with it the editor, alive for the test.
  private static var windows: [NSWindow] = []

  private func makeEditor(_ text: String) async throws -> (SheetEditorViewController, SheetTextView)
  {
    let editor = SheetEditorViewController(
      text: text,
      context: try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 0),
        calendar: Calendar(identifier: .gregorian),
        timeZone: try #require(TimeZone(identifier: "UTC"))
      )
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return (editor, try #require(editor.textView as? SheetTextView))
  }
}
