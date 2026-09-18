import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct SheetEditorViewControllerTests {
  @Test
  func mirrorsTypingAndReplacementsIntoTheSheet() throws {
    let editor = SheetEditorViewController(
      text: "rent = 2100\nfood = 500", context: try testContext())
    let ids = editor.sheet.lines.map(\.id)

    editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
    editor.textView.insertText(
      " // shared", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.textView.insertText("tax = 8%\n", replacementRange: NSRange(location: 22, length: 0))

    #expect(editor.sheet.text == editor.textView.string)
    #expect(editor.sheet.lines.map(\.text) == ["rent = 2100 // shared", "tax = 8%", "food = 500"])
    #expect(editor.sheet.lines[0].id == ids[0])
    #expect(editor.sheet.lines[2].id == ids[1])
  }

  @Test
  func lineReferencesFollowTheirLineAndOneUndoRestoresBoth() throws {
    let source = "rent = 5\nfood = 2\nsubtotal\nsavings = 10 - line 3"
    let editor = SheetEditorViewController(text: source, context: try testContext())
    let textView = editor.textView

    textView.setSelectedRange(NSRange(location: 8, length: 0))
    textView.insertText("\nphone = 1", replacementRange: textView.selectedRange())
    #expect(textView.string == "rent = 5\nphone = 1\nfood = 2\nsubtotal\nsavings = 10 - line 4")
    #expect(editor.sheet.text == textView.string)

    editor.documentUndoManager.undo()
    #expect(textView.string == source)

    // Deleting a line above moves the reference up.
    textView.setSelectedRange(NSRange(location: 0, length: 9))
    textView.insertText("", replacementRange: textView.selectedRange())
    #expect(textView.string == "food = 2\nsubtotal\nsavings = 10 - line 2")
  }

  @Test
  func returnAndReferenceRewritesUndoTogetherAfterTyping() async throws {
    let source = "# Heading\n10\n20\nline 2 + line 3\nprevious * 2"
    let editor = SheetEditorViewController(text: source, context: try testContext())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.makeFirstResponder(editor.textView)
    let textView = editor.textView
    let manager = editor.documentUndoManager
    textView.setSelectedRange(NSRange(location: 10, length: 0))
    textView.insertText("5", replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(30))
    textView.setSelectedRange(NSRange(location: 11, length: 0))
    let beforeReturn = textView.string
    textView.insertNewline(nil)
    try await Task.sleep(for: .milliseconds(30))
    let afterReturn = textView.string
    #expect(afterReturn == "# Heading\n5\n10\n20\nline 2 + line 4\nprevious * 2")
    manager.undo()
    #expect(textView.string == beforeReturn)
    #expect(editor.sheet.text == beforeReturn)
    manager.redo()
    #expect(textView.string == afterReturn)
    #expect(editor.sheet.text == afterReturn)
  }

  @Test(arguments: ["5\n", "5\n6\n"])
  func pastedLinesAndMultipleReferencesUndoAndRedoTogether(_ insertion: String) async throws {
    let source = "10\n20\nline 1 + line 2\nline 1 * line 2"
    let editor = SheetEditorViewController(text: source, context: try testContext())
    let textView = editor.textView
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertText(insertion, replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(30))
    let inserted = insertion.filter { $0 == "\n" }.count
    let updated =
      insertion + "10\n20\nline \(1 + inserted) + line \(2 + inserted)\n"
      + "line \(1 + inserted) * line \(2 + inserted)"
    #expect(textView.string == updated)
    editor.documentUndoManager.undo()
    #expect(textView.string == source)
    #expect(editor.sheet.text == source)
    editor.documentUndoManager.redo()
    #expect(textView.string == updated)
    #expect(editor.sheet.text == updated)
    textView.setSelectedRange(NSRange(location: 0, length: insertion.utf16.count))
    textView.insertText("", replacementRange: textView.selectedRange())
    try await Task.sleep(for: .milliseconds(30))
    #expect(textView.string == source)
    editor.documentUndoManager.undo()
    #expect(textView.string == updated)
    editor.documentUndoManager.redo()
    #expect(textView.string == source)
    #expect(editor.sheet.text == source)
  }

  @Test
  func mirrorsMarkedTextCompositionAndCommit() throws {
    let editor = SheetEditorViewController(text: "1 + ", context: try testContext())
    let textView = editor.textView
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    textView.setMarkedText(
      "に",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(textView.hasMarkedText())
    #expect(editor.sheet.text == "1 + に")

    textView.insertText("２", replacementRange: textView.markedRange())
    #expect(!textView.hasMarkedText())
    #expect(editor.sheet.text == "1 + ２")
    #expect(editor.sheet.text == textView.string)
  }

  @Test
  func keepsBidirectionalAndSupplementaryTextOffsetsExact() throws {
    let editor = SheetEditorViewController(text: "", context: try testContext())
    editor.textView.insertText(
      "إيجار = 2100\n👍🏽 = 3\nשכר + 1",
      replacementRange: NSRange(location: 0, length: 0)
    )
    let string = editor.textView.string as NSString
    let thumb = string.range(of: "👍🏽")
    editor.textView.insertText(
      "x", replacementRange: NSRange(location: thumb.upperBound, length: 0))

    #expect(editor.textView.baseWritingDirection == .natural)
    #expect(editor.sheet.text == editor.textView.string)
    #expect(editor.sheet.lines.map(\.text) == ["إيجار = 2100", "👍🏽x = 3", "שכר + 1"])
  }

  @Test
  func undoUsesTheDocumentUndoManagerAndStaysMirrored() throws {
    let editor = SheetEditorViewController(text: "12 km", context: try testContext())
    let undoManager = editor.documentUndoManager
    undoManager.groupsByEvent = false

    #expect(editor.textView.undoManager === undoManager)
    undoManager.beginUndoGrouping()
    editor.textView.insertText(" in miles", replacementRange: NSRange(location: 5, length: 0))
    undoManager.endUndoGrouping()
    #expect(editor.sheet.text == "12 km in miles")

    undoManager.undo()
    #expect(editor.textView.string == "12 km")
    #expect(editor.sheet.text == "12 km")

    undoManager.redo()
    #expect(editor.sheet.text == "12 km in miles")
  }

  @Test
  func disablesSubstitutionsThatWouldChangeSource() throws {
    let textView = SheetEditorViewController(context: try testContext()).textView

    #expect(!textView.isRichText)
    #expect(textView.allowsUndo)
    #expect(textView.usesFindBar)
    #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
    #expect(!textView.isAutomaticDashSubstitutionEnabled)
    #expect(!textView.isAutomaticTextReplacementEnabled)
    #expect(!textView.isAutomaticSpellingCorrectionEnabled)
    #expect(!textView.usesFontPanel)
    #expect(!textView.smartInsertDeleteEnabled)
  }

  @Test
  func standardActionsReachTheTextViewThroughTheResponderChain() throws {
    let editor = SheetEditorViewController(text: "1 + 2\n3", context: try testContext())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    #expect(window.makeFirstResponder(editor.textView))

    #expect(window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) == true)
    #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 7))
  }

  @Test
  func showsAnswersBesideSourceWithoutChangingIt() async throws {
    let source = "12 km in miles\n# Trip\n1 +\nrent = 2,100\n"
    let editor = SheetEditorViewController(text: source, context: try testContext())
    await editor.scheduler?.waitUntilIdle()

    let textView = try #require(editor.textView as? SheetTextView)
    let ids = editor.sheet.lines.map(\.id)
    #expect(textView.string == source)
    #expect(
      Dictionary(
        uniqueKeysWithValues: ids.compactMap { id in textView.answer(id).map { (id, $0.text) } })
        == [
          ids[0]: "7.45645430684801 mi",
          ids[2]: "Enter an expression here.",
          ids[3]: "2,100",
        ]
    )
  }

  @Test
  func evaluatesAfterCompositionCommitsAndShowsTheNewestGeneration() async throws {
    let editor = SheetEditorViewController(text: "1 + 1", context: try testContext())
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let firstGeneration = try #require(editor.latestEvaluation?.generation)

    textView.setMarkedText(
      "2",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 5, length: 0)
    )
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.generation == firstGeneration)

    textView.insertText("2", replacementRange: textView.markedRange())
    for digit in ["3", "4", "5"] {
      textView.insertText(
        digit, replacementRange: NSRange(location: textView.string.utf16.count, length: 0))
    }
    await editor.scheduler?.waitUntilIdle()

    #expect(editor.latestEvaluation?.lines.map(\.id) == editor.sheet.lines.map(\.id))
    #expect(textView.answer(editor.sheet.lines[0].id)?.text == "12,346")
  }

  @Test
  func alignsAnswersToTheirLinesInTheAnswerColumn() async throws {
    let editor = SheetEditorViewController(
      text: "1 + 1\n\n"
        + String(repeating: "123456789 + ", count: 12) + "0\n"
        + "3 * 3",
      context: try testContext()
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    await editor.scheduler?.waitUntilIdle()

    let textView = try #require(editor.textView as? SheetTextView)
    #expect(textView.bounds.width > 500)
    let layout = textView.answerLayout(in: textView.bounds)
    let ids = editor.sheet.lines.map(\.id)
    let sourceMaxX =
      textView.textContainerOrigin.x + (textView.textContainer?.size.width ?? 0)

    #expect(layout.map(\.line) == [ids[0], ids[2], ids[3]])
    #expect(
      layout.allSatisfy { $0.rect.maxX == textView.bounds.maxX - textView.textContainerInset.width }
    )
    #expect(layout.allSatisfy { $0.rect.minX >= sourceMaxX })
    #expect(zip(layout, layout.dropFirst()).allSatisfy { $0.rect.maxY <= $1.rect.minY })
    // The long expression wraps within the source column, so the next answer
    // sits below all of its rows.
    #expect(layout[2].rect.minY - layout[1].rect.minY > layout[1].rect.height * 1.5)
  }
}

private func testContext() throws -> EvaluationContext {
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
