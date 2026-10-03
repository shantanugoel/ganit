import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct SheetCommandTests {
  private static var windows: [NSWindow] = []

  @Test(arguments: ["\n", "\r", "\r\n"])
  func togglesReferencedLinesWithoutBreakingReferences(_ newline: String) async throws {
    let original = ["1", "2", "3", "@2 + @3"].joined(separator: newline)
    let (editor, textView) = try await makeEditor(original)
    let manager = editor.documentUndoManager
    manager.groupsByEvent = false
    let start = 1 + newline.utf16.count
    textView.setSelectedRange(NSRange(location: start, length: start + 1))
    perform(manager) { textView.toggleComment(nil) }
    let commented = ["1", "// 2", "// 3", "@2 + @3"].joined(separator: newline)
    #expect(textView.string == commented)
    #expect(editor.sheet.text == commented)
    perform(manager) { textView.toggleComment(nil) }
    #expect(textView.string == original)
    manager.undo()
    #expect(textView.string == commented)
    manager.undo()
    #expect(textView.string == original)
    manager.redo()
    #expect(textView.string == commented)
    manager.redo()
    #expect(textView.string == original)
    #expect(editor.sheet.text == original)
  }

  @Test(arguments: ["30", "30\n40", ""])
  func multipleRangeReplacementPreservesIntactReferences(_ replacement: String) async throws {
    let original = "1\n2\n@2\n3\n@2 + @4"
    let (editor, textView) = try await makeEditor(original)
    let manager = editor.documentUndoManager
    manager.groupsByEvent = false
    let ranges = [NSRange(location: 0, length: 1), NSRange(location: 7, length: 1)]
    perform(manager) {
      if textView.shouldChangeText(
        inRanges: ranges.map { NSValue(range: $0) },
        replacementStrings: ["10", replacement])
      {
        for (range, text) in zip(ranges, ["10", replacement]).reversed() {
          textView.textStorage?.replaceCharacters(in: range, with: text)
        }
        textView.didChangeText()
      }
    }
    let target = replacement.isEmpty ? "@deleted" : (replacement.contains("\n") ? "@split" : "@4")
    let changed = "10\n2\n@2\n" + replacement + "\n@2 + " + target
    #expect(textView.string == changed)
    #expect(editor.sheet.text == changed)
    manager.undo()
    #expect(textView.string == original)
    manager.redo()
    #expect(textView.string == changed)
    #expect(editor.sheet.text == changed)
  }

  @Test
  func togglesCommentsOnSelectedLinesAsOneUndoableEdit() async throws {
    let original = "rent = 2100\n\n  food = 500\n1 + 1"
    let (editor, textView) = try await makeEditor(original)
    let undoManager = editor.documentUndoManager
    undoManager.groupsByEvent = false
    let ids = editor.sheet.lines.map(\.id)
    textView.setSelectedRange(NSRange(location: 3, length: 12))

    perform(undoManager) { textView.toggleComment(nil) }
    #expect(textView.string == "// rent = 2100\n\n  // food = 500\n1 + 1")
    #expect(editor.sheet.lines.map(\.id) == ids)

    perform(undoManager) { textView.toggleComment(nil) }
    #expect(textView.string == original)

    perform(undoManager) { textView.toggleHeading(nil) }
    #expect(textView.string == "# rent = 2100\n\n  # food = 500\n1 + 1")

    undoManager.undo()
    #expect(textView.string == original)
    #expect(editor.sheet.text == textView.string)
  }

  @Test
  func insertsSubtotalsDividersAndReferencesToResultsAbove() async throws {
    let (editor, textView) = try await makeEditor("12\n// note\n1 +\n30")

    // The nearest result above skips comments and failures.
    textView.setSelectedRange(NSRange(location: 16, length: 0))
    textView.insertReference(nil)
    #expect(textView.string == "12\n// note\n1 +\n3line 10")

    // Nothing is above the first line.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertReference(nil)
    #expect(textView.string == "12\n// note\n1 +\n3line 10")

    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertSubtotal(nil)
    textView.insertDivider(nil)
    #expect(textView.string == "12\nsubtotal\n---\n// note\n1 +\n3line 10")
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.sheet.text == textView.string)
  }

  @Test
  func commandReturnCopiesTheCurrentResult() async throws {
    let (_, textView) = try await makeEditor("6 * 7")
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: textView.window?.windowNumber ?? 0,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
      )
    )

    textView.keyDown(with: event)

    #expect(textView.string == "6 * 7")
    #expect(textView.pasteboard.string(forType: .string) == "42")
  }

  @Test
  func evaluationCommandsReachTheControllerAndMenusValidate() async throws {
    let (editor, textView) = try await makeEditor("1 m + 1 s")
    let generation = try #require(editor.latestEvaluation?.generation)

    #expect(textView.tryToPerform(#selector(SheetCommands.recalculate(_:)), with: nil))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.generation == generation + 1)

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    for (action, enabled) in [
      (#selector(SheetCommands.copyFullPrecision(_:)), false),
      (#selector(SheetCommands.showInterpretation(_:)), true),
      (#selector(SheetCommands.insertReference(_:)), false),
      (#selector(SheetCommands.toggleComment(_:)), true),
    ] {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      #expect(textView.validateUserInterfaceItem(item) == enabled, "\(action)")
    }
  }

  private func perform(_ undoManager: UndoManager, _ edit: () -> Void) {
    undoManager.beginUndoGrouping()
    edit()
    undoManager.endUndoGrouping()
  }

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
    let textView = try #require(editor.textView as? SheetTextView)
    textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitTests-\(UUID().uuidString)"))
    window.makeFirstResponder(textView)
    await editor.scheduler?.waitUntilIdle()
    return (editor, textView)
  }
}
