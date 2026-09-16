import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct LineDecorationTests {
  @Test
  func decoratesStructuralRangesInUTF16() throws {
    let label = "Café ☕: 3 // 👍🏽 note"
    #expect(
      try decoration(label).runs == [
        .init(range: (label as NSString).range(of: "Café ☕"), style: .secondary),
        .init(range: (label as NSString).range(of: "// 👍🏽 note"), style: .secondary),
      ]
    )
    #expect(
      try decoration("  ---").runs == [
        .init(range: NSRange(location: 0, length: 5), style: .tertiary)
      ])
    #expect(
      try decoration(" # Trip").runs == [
        .init(range: NSRange(location: 1, length: 1), style: .tertiary),
        .init(range: NSRange(location: 2, length: 5), style: .heading),
      ])
    #expect(try decoration("12 km").runs.isEmpty)
  }

  @Test
  func underlinesFailuresButWaitsForIncompleteInputToLeaveTheLine() throws {
    let mismatch = "é = 1 m + 1 s"
    #expect(
      try decoration(mismatch).runs == [
        .init(range: (mismatch as NSString).range(of: "+"), style: .error)
      ]
    )

    #expect(try decoration("1 +", isEditing: true).runs.isEmpty)
    #expect(
      try decoration("1 +", isEditing: false).runs == [
        .init(range: NSRange(location: 2, length: 1), style: .error)
      ]
    )
  }

  @Test
  func editorAppliesRenderingAttributesWithoutChangingSource() async throws {
    let source = "1 +\nRent: 2100 // monthly\n1 m + 1 s"
    let editor = SheetEditorViewController(text: source, context: try context())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    await editor.scheduler?.waitUntilIdle()
    let textView = try #require(editor.textView as? SheetTextView)
    let string = source as NSString
    let ids = editor.sheet.lines.map(\.id)

    #expect(textView.string == source)
    #expect(
      textView.textStorage?.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        != .secondaryLabelColor
    )
    #expect(runs(in: textView).contains { $0 == (string.range(of: "Rent"), "secondary") })
    #expect(runs(in: textView).contains { $0 == (string.range(of: "// monthly"), "secondary") })
    #expect(textView.underlines[ids[2]]?.map(\.range) == [NSRange(location: 4, length: 1)])
    #expect(textView.underlines[ids[2]]?.first?.color == .systemRed)
    // The insertion point starts on the incomplete first line.
    #expect(textView.underlines[ids[0]] == nil)

    textView.setSelectedRange(NSRange(location: 6, length: 0))
    #expect(textView.underlines[ids[0]]?.map(\.range) == [NSRange(location: 2, length: 1)])

    // Underlines sit just below the text they mark, within its line.
    let plus = try #require(textView.underlineLayout(in: textView.bounds).last?.rect)
    let answerRows = textView.answerLayout(in: textView.bounds)
    #expect(plus.width > 0)
    #expect(plus.maxX < textView.bounds.maxX - textView.answerColumnWidth)
    #expect(plus.minY > (answerRows.last?.rect.minY ?? 0))

    textView.insertText("2", replacementRange: NSRange(location: string.length, length: 0))
    #expect(textView.underlines[ids[2]] == nil)
  }

  @Test
  func redecoratesEditedLinesEvenWhenTheirTextReturns() async throws {
    let editor = SheetEditorViewController(text: "// note", context: try context())
    let undoManager = editor.documentUndoManager
    undoManager.groupsByEvent = false
    await editor.scheduler?.waitUntilIdle()
    let textView = editor.textView

    undoManager.beginUndoGrouping()
    textView.insertText("", replacementRange: NSRange(location: 3, length: 4))
    undoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    undoManager.undo()
    await editor.scheduler?.waitUntilIdle()

    #expect(textView.string == "// note")
    #expect(runs(in: textView).map(\.range) == [NSRange(location: 0, length: 7)])
  }

  private func decoration(_ text: String, isEditing: Bool = false) throws -> LineDecoration {
    let engine = CalculationEngine()
    var calculator = SheetCalculator(engine: engine)
    let line = try #require(
      try calculator.evaluate(SheetSource(text), context: try context()).lines.first
    )
    return LineDecoration(
      text: text, syntax: line.syntax, result: line.result, isEditing: isEditing)
  }

  /// Rendering-attribute runs as UTF-16 ranges named by their style.
  private func runs(in textView: NSTextView) -> [(range: NSRange, style: String)] {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else {
      return []
    }
    let origin = contentManager.documentRange.location
    var runs: [(range: NSRange, style: String)] = []
    layoutManager.enumerateRenderingAttributes(from: origin, reverse: false) {
      _, attributes, range in
      let style: String? =
        if attributes[.foregroundColor] as? NSColor == .secondaryLabelColor {
          "secondary"
        } else {
          nil
        }
      if let style {
        let location = contentManager.offset(from: origin, to: range.location)
        let length = contentManager.offset(from: range.location, to: range.endLocation)
        if let last = runs.last, last.style == style, NSMaxRange(last.range) == location {
          runs[runs.count - 1].range.length += length
        } else {
          runs.append((NSRange(location: location, length: length), style))
        }
      }
      return true
    }
    return runs
  }

  private func context() throws -> EvaluationContext {
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
}
