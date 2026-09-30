import AppKit
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct CompletionsTests {
  @Test
  func atOffersVariablesAndEarlierAnswersWithPreviews() async throws {
    let source = "# Budget\nMonthly rent = 2100\n12\n// note\n1/0\n\n"
    let (editor, textView) = try await makeEditor(source)
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.insertText("@", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["Monthly rent", "@2", "@3"])
    #expect(textView.referenceCompletions(source.utf16.count).first?.detail == "2,100")
    #expect(textView.referenceCompletions(source.utf16.count).last?.detail == "12 → 12")
    textView.insertText("mo", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["Monthly rent"])
    textView.insertNewline(nil)
    #expect(textView.string == source + "Monthly rent")
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.lines.last?.result == editor.latestEvaluation?.lines[1].result)
  }

  @Test
  func atDigitsChooseACompactReference() async throws {
    let source = "10\n20\n"
    let (editor, textView) = try await makeEditor(source)
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.insertText("@2", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["@2"])
    textView.insertTab(nil)
    #expect(textView.string == source + "@2")
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.lines.last?.result == editor.latestEvaluation?.lines[1].result)
    #expect(textView.offeredCompletions.isEmpty)
  }

  @Test
  func ordinaryTypingCompletesMultiwordVariablesWithoutAt() async throws {
    let source = "Monthly rent = 2100\n"
    let (_, textView) = try await makeEditor(source)
    textView.completesWhileTyping = true
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.insertText("monthly re", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["Monthly rent"])
    textView.insertTab(nil)
    #expect(textView.string == source + "Monthly rent")
  }

  @Test
  func pickerRespectsScopeRedefinitionsAndSharedDefinitions() async throws {
    let source = "local = 2\n---\nshared = 8\nbroken = 1/0\n\nfuture = 10"
    let (editor, textView) = try await makeEditor(source)
    editor.setDefinitions(
      SheetDefinitions(variables: [
        "shared": .number(.integer(IntegerValue(5))),
        "broken": .number(.integer(IntegerValue(5))),
      ]))
    await editor.scheduler?.waitUntilIdle()
    let end = (source as NSString).range(of: "\nfuture").location
    textView.setSelectedRange(NSRange(location: end, length: 0))
    textView.insertText("@", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["shared", "@1", "@3"])
    #expect(textView.referenceCompletions(end).first?.detail == "8")
  }

  @Test
  func explicitPickerWorksWithAutomaticSuggestionsOffAndEscapeDismissesIt() async throws {
    let source = "rent = 5\n"
    let (_, textView) = try await makeEditor(source)
    textView.completesWhileTyping = false
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.insertText("@", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["rent", "@1"])
    textView.complete(nil)
    #expect(textView.offeredCompletions.isEmpty)
    textView.insertNewline(nil)
    #expect(textView.string == source + "@\n")
  }

  @Test
  func pickerDoesNotOfferSuggestionsInHeadingsCommentsDeclarationsOrPromptProse() async throws {
    for suffix in ["# @", "// @", "label: // @", "@ = 1", "ask_assistant(email @"] {
      let source = "rent = 5\n"
      let (_, textView) = try await makeEditor(source)
      textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
      textView.insertText(suffix, replacementRange: textView.selectedRange())
      #expect(textView.offeredCompletions.isEmpty, "\(suffix)")
    }
  }

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
  func atInsideAPromptPlaceholderAlsoClosesThePlaceholder() async throws {
    let source = "rent = 5\n"
    let (_, textView) = try await makeEditor(source)
    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.insertText("ask_assistant(cost {@re", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions == ["rent"])
    textView.insertTab(nil)
    #expect(textView.string == source + "ask_assistant(cost {rent}")
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
