import AppKit
import Foundation
import GanitEngine
import GanitFormatting
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct AnswerPlacementTests {
  @Test
  func theColumnRightAlignsAnswersBehindARuleAndProseWritesThemAfterEachLine() async throws {
    let (editor, textView) = try await makeEditor("2 + 2\n10 * 10")

    let column = textView.answerLayout(in: textView.bounds)
    #expect(column.map(\.cell.text) == ["4", "100"])
    // A column ends where the sheet does, whatever each answer is worth.
    #expect(column[0].rect.maxX == column[1].rect.maxX)
    let rule = try #require(textView.answerSeparatorX)
    #expect(rule < column[0].rect.minX)
    let narrowedSource = try #require(textView.textContainer?.size.width)
    #expect(narrowedSource < textView.bounds.width - textView.answerColumnWidth)

    editor.writeAnswers(DisplayOptions(writesAnswersInline: true))

    let prose = textView.answerLayout(in: textView.bounds)
    #expect(prose.map(\.cell.text) == ["4", "100"])
    // Each answer follows its own line, so the longer line pushes its own
    // answer further right and nothing is aligned with anything.
    #expect(prose[0].rect.minX < prose[1].rect.minX)
    #expect(prose[0].rect.maxX < column[0].rect.minX)
    // Prose has the whole width to be written in, and no column to mark.
    #expect(try #require(textView.textContainer?.size.width) > narrowedSource)
    #expect(textView.answerSeparatorX == nil)
  }

  @Test
  func theRuleIsDrawnUntilASheetAsksForItToBeHidden() async throws {
    let (editor, textView) = try await makeEditor("2 + 2")

    #expect(textView.answerSeparatorX != nil)

    editor.writeAnswers(DisplayOptions(showsAnswerSeparator: false))
    #expect(textView.answerSeparatorX == nil)

    editor.writeAnswers(DisplayOptions(showsAnswerSeparator: true))
    #expect(textView.answerSeparatorX != nil)
  }

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
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    return (editor, textView)
  }
}
