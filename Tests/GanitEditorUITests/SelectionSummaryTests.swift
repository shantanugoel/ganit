import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct SelectionSummaryTests {
  @Test
  func addsUpTheAnswersASelectionCovers() async throws {
    let editor = try await editor("10\n20\n30")

    editor.textView.setSelectedRange(NSRange(location: 0, length: 8))
    #expect(editor.summaryBar.summary == SelectionSummary(count: 3, total: "60", average: "20"))

    // A selection that only reaches into a line still counts its answer.
    editor.textView.setSelectedRange(NSRange(location: 1, length: 3))
    #expect(editor.summaryBar.summary == SelectionSummary(count: 2, total: "30", average: "15"))
  }

  @Test
  func staysHiddenUntilASelectionCoversMoreThanOneAnswer() async throws {
    let editor = try await editor("10\n20\n30")

    #expect(editor.summaryBar.summary == nil)
    #expect(editor.summaryBar.isHidden)

    editor.textView.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(editor.summaryBar.summary == nil)

    editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
    #expect(editor.summaryBar.summary?.count == 2)
    #expect(!editor.summaryBar.isHidden)
    #expect(editor.summaryBar.fittingHeight > 0)

    // The bar is text, which accessibility reads with a label of its own.
    let text = try #require(editor.summaryBar.subviews.first as? NSTextField)
    #expect(text.stringValue == "Count 2   Total 30   Average 15")
    #expect(text.accessibilityLabel() == "Selection summary")
  }

  @Test
  func countsAnswersItCannotAddWithoutATotal() async throws {
    let editor = try await editor("5 USD\n2 m\n// a comment\n2 +")

    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.textView.string.count))

    // A comment and a failure have no answer, and money and metres cannot be
    // added, so only the count is left to show.
    #expect(editor.summaryBar.summary == SelectionSummary(count: 2, total: nil, average: nil))
  }

  @Test
  func addsUpMoneyAndFollowsAnEdit() async throws {
    let editor = try await editor("5 USD\n10 USD")

    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.textView.string.count))
    #expect(editor.summaryBar.summary?.total == "$15.00")

    editor.textView.insertText("2", replacementRange: NSRange(location: 0, length: 1))
    await editor.scheduler?.waitUntilIdle()
    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.textView.string.count))

    #expect(editor.summaryBar.summary?.total == "$12.00")
  }

  private func editor(_ text: String) async throws -> SheetEditorViewController {
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
    window.makeFirstResponder(editor.textView)
    await editor.scheduler?.waitUntilIdle()
    return editor
  }

  /// Windows outlive each test so their text views are not deallocated
  /// while AppKit still holds them.
  private static var windows: [NSWindow] = []
}
