import AppKit
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct SheetEditorViewControllerTests {
  @Test
  func mirrorsTypingAndReplacementsIntoTheSheet() {
    let editor = SheetEditorViewController(text: "rent = 2100\nfood = 500")
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
  func mirrorsMarkedTextCompositionAndCommit() {
    let editor = SheetEditorViewController(text: "1 + ")
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
  func keepsBidirectionalAndSupplementaryTextOffsetsExact() {
    let editor = SheetEditorViewController(text: "")
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
    let editor = SheetEditorViewController(text: "12 km")
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
  func disablesSubstitutionsThatWouldChangeSource() {
    let textView = SheetEditorViewController().textView

    #expect(!textView.isRichText)
    #expect(textView.allowsUndo)
    #expect(textView.usesFindBar)
    #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
    #expect(!textView.isAutomaticDashSubstitutionEnabled)
    #expect(!textView.isAutomaticTextReplacementEnabled)
    #expect(!textView.isAutomaticSpellingCorrectionEnabled)
    #expect(!textView.smartInsertDeleteEnabled)
  }

  @Test
  func standardActionsReachTheTextViewThroughTheResponderChain() throws {
    let editor = SheetEditorViewController(text: "1 + 2\n3")
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
}
