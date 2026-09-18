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
  func aWideWindowKeepsAnswersBesideTheirLines() async throws {
    let (_, textView) = try await makeEditor("2 + 2")
    let window = try #require(textView.window)

    window.setContentSize(NSSize(width: 2_400, height: 400))
    window.layoutIfNeeded()

    // The sheet stops growing, so the answer does not run off to the far edge.
    #expect(textView.contentWidth <= SheetTextView.maximumContentWidth)
    let answer = try #require(textView.answerLayout(in: textView.bounds).first)
    #expect(answer.rect.maxX < SheetTextView.maximumContentWidth + 40)
    #expect(try #require(textView.answerSeparatorX) < SheetTextView.maximumContentWidth)
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

  /// A compact window keeps a value's unit by writing fewer digits, marked
  /// `≈`, and truncates values in the middle and messages at the end.
  @Test
  func aNarrowColumnKeepsUnitsAndMarksRounding() async throws {
    let (_, textView) = try await makeEditor("1000 mA / 7\n2 + 2\n1 m + 1 s")
    let window = try #require(textView.window)
    let wide = textView.answerLayout(in: textView.bounds)
    #expect(wide[0].cell.text == "≈ 142.857142857143 mA")
    #expect(textView.drawnText(for: wide[0].cell, within: wide[0].rect.width) == wide[0].cell.text)

    window.setContentSize(NSSize(width: 320, height: 400))
    window.layoutIfNeeded()
    let narrow = textView.answerLayout(in: textView.bounds)
    #expect(textView.drawnText(for: narrow[0].cell, within: narrow[0].rect.width) == "≈ 142.857 mA")
    #expect(narrow[0].rect.width <= textView.answerColumnWidth)
    // Short answers need no shorter form, and failures have none.
    #expect(narrow[1].cell.compactText == nil)
    #expect(narrow[2].cell.compactText == nil)
    let style = { (cell: AnswerCell) in
      textView.attributes(for: cell, selected: false)[.paragraphStyle] as? NSParagraphStyle
    }
    #expect(style(narrow[0].cell)?.lineBreakMode == .byTruncatingMiddle)
    #expect(style(narrow[2].cell)?.lineBreakMode == .byTruncatingTail)
    // The full answer stays available on hover.
    let hover = NSPoint(x: narrow[0].rect.midX, y: narrow[0].rect.midY)
    #expect(textView.tooltip(at: hover) == "≈ 142.857142857143 mA")
  }

  /// Line numbers count physical lines, as `line N` does, in a gutter the
  /// source moves over for; Go to Line reaches one by that number.
  @Test
  func lineNumbersCountPhysicalLinesAndGoToLineReachesThem() async throws {
    let wrapped = "rent = 2100 // " + String(repeating: "a comment that wraps ", count: 8)
    let (editor, textView) = try await makeEditor("# Budget\n\(wrapped)\n\nline 2 + 1")
    let plainOrigin = textView.textContainerOrigin.x
    let plainColumn = try #require(textView.answerLayout(in: textView.bounds).first?.rect.maxX)
    #expect(textView.lineNumberLayout(in: textView.bounds).isEmpty)

    editor.writeAnswers(DisplayOptions(showsLineNumbers: true))
    #expect(textView.gutterWidth > 0)
    #expect(textView.textContainerOrigin.x == plainOrigin + textView.gutterWidth)
    let numbers = textView.lineNumberLayout(in: textView.bounds)
    #expect(numbers.map(\.number) == [1, 2, 3, 4])
    #expect(numbers.allSatisfy { $0.rect.maxX < textView.textContainerOrigin.x })
    // The answer column keeps its right edge; only the source moves over.
    #expect(textView.answerLayout(in: textView.bounds).first?.rect.maxX == plainColumn)
    #expect(textView.goToLine(4))
    #expect(
      textView.selectedRange().location
        == (textView.string as NSString).range(of: "line 2").location)
    #expect(!textView.goToLine(5))
    #expect(!textView.goToLine(0))
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
