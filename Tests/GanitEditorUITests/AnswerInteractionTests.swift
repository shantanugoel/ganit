import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct AnswerInteractionTests {
  @Test
  func cellsCarryInterpretationDetailsAndVisibleFailureMessages() async throws {
    let (editor, textView) = try await makeEditor("sqrt(2)\n1 m + 1 s\n2 +")
    let ids = editor.sheet.lines.map(\.id)

    let value = try #require(textView.answer(ids[0]))
    #expect(value.text == "≈ 1.4142135623731")
    #expect(
      textView.interpretation(ids[0]).map(\.label) == [
        "Expression", "Result", "Full precision", "Kind", "Exactness",
      ]
    )
    #expect(textView.interpretation(ids[0]).last?.value == "Approximate")

    let failure = try #require(textView.answer(ids[1]))
    #expect(failure.isFailure)
    #expect(failure.text == "These quantities have incompatible dimensions.")
    #expect(textView.interpretation(ids[1]).last?.value == "evaluation.incompatibleDimensions")

    // Incomplete input shows its message only once editing leaves the line.
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    #expect(textView.answer(ids[2]) == nil)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(textView.answer(ids[2])?.text == "Enter an expression here.")
  }

  @Test
  func detailsShowResolvedZonesAndDaylightSavingSuggestions() async throws {
    let (editor, textView) = try await makeEditor(
      "2024-03-09T12:00 Asia/Kolkata\n2024-11-03T01:30 America/New_York")
    let ids = editor.sheet.lines.map(\.id)

    let instant = textView.interpretation(ids[0])
    #expect(instant.map(\.label).suffix(2) == ["Time zone", "UTC offset"])
    #expect(instant.map(\.value).suffix(2) == ["Asia/Kolkata", "+05:30"])

    let overlap = textView.interpretation(ids[1])
    #expect(
      overlap.filter { $0.label == "Suggestion" }.map(\.value) == [
        "2024-11-03T01:30:00-04:00 America/New_York", "2024-11-03T01:30:00-05:00 America/New_York",
      ]
    )
    #expect(overlap.last?.value == "evaluation.ambiguousLocalTime")
  }

  @Test
  func waitsForAClockBoundaryOnlyWhenAResultReadsTheClock() async throws {
    let (editor, textView) = try await makeEditor("1 + 1")
    #expect(editor.scheduler?.recalculation == nil)

    textView.insertText("\ntoday", replacementRange: NSRange(location: 5, length: 0))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.scheduler?.recalculation != nil)

    editor.stopCalculation(nil)
    #expect(editor.scheduler?.recalculation == nil)
  }

  @Test
  func recalculatesAnswersThatReadNowWhenTheSecondChanges() async throws {
    let (editor, textView) = try await makeEditor("now")
    let id = try #require(editor.sheet.lines.first?.id)
    let first = try #require(textView.answer(id)?.text)

    try await Task.sleep(for: .milliseconds(1_100))
    await editor.scheduler?.waitUntilIdle()

    #expect(textView.answer(id)?.text != first)
  }

  @Test
  func copiesDisplayedAndFullPrecisionResults() async throws {
    let (_, textView) = try await makeEditor("sqrt(2)\n1 m + 1 s")
    textView.setSelectedRange(NSRange(location: 0, length: 0))

    textView.copyResult(nil)
    #expect(textView.pasteboard.string(forType: .string) == "≈ 1.4142135623731")
    textView.copyFullPrecision(nil)
    #expect(textView.pasteboard.string(forType: .string) == "≈ 1.414213562373095")

    textView.setSelectedRange(NSRange(location: 9, length: 0))
    textView.pasteboard.clearContents()
    textView.copyResult(nil)
    #expect(textView.pasteboard.string(forType: .string) == nil)
  }

  @Test
  func clickingSelectsAnswersAndCopyUsesTheSelection() async throws {
    let (_, textView) = try await makeEditor("12 km in miles\n5 + 5")
    let answer = try #require(textView.answerLayout(in: textView.bounds).last)

    textView.mouseDown(with: try mouseEvent(at: answer.rect, in: textView, clicks: 1))
    #expect(textView.selectedAnswer == answer.line)

    textView.copy(nil)
    #expect(textView.pasteboard.string(forType: .string) == "10")

    textView.keyDown(with: try keyEvent("\u{1b}", in: textView))
    #expect(textView.selectedAnswer == nil)
  }

  @Test
  func doubleClickingAnAnswerAboveInsertsAReference() async throws {
    let (editor, textView) = try await makeEditor("12 km\n3 m\n")
    let layout = textView.answerLayout(in: textView.bounds)
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

    textView.mouseDown(with: try mouseEvent(at: layout[0].rect, in: textView, clicks: 2))
    #expect(textView.string == "12 km\n3 m\nline 1")
    #expect(editor.sheet.text == textView.string)

    // An answer on the insertion point's own line is not above it.
    textView.setSelectedRange(NSRange(location: 8, length: 0))
    textView.mouseDown(with: try mouseEvent(at: layout[1].rect, in: textView, clicks: 2))
    #expect(textView.string == "12 km\n3 m\nline 1")
  }

  @Test
  func spaceOnASelectedAnswerOpensInterpretationWithoutEditing() async throws {
    let (_, textView) = try await makeEditor("20% of 50")
    let answer = try #require(textView.answerLayout(in: textView.bounds).first)
    textView.mouseDown(with: try mouseEvent(at: answer.rect, in: textView, clicks: 1))

    textView.keyDown(with: try keyEvent(" ", in: textView))

    #expect(textView.string == "20% of 50")
    #expect(textView.interpretationPopover?.contentViewController is InterpretationViewController)
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
    let textView = try #require(editor.textView as? SheetTextView)
    textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitTests-\(UUID().uuidString)"))
    window.makeFirstResponder(textView)
    await editor.scheduler?.waitUntilIdle()
    return (editor, textView)
  }

  private func mouseEvent(at rect: NSRect, in view: NSView, clicks: Int) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: clicks,
        pressure: 1
      )
    )
  }

  private func keyEvent(_ characters: String, in view: NSView) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
      )
    )
  }
}
