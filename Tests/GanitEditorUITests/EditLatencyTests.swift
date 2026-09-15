import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct EditLatencyTests {
  @Test
  func reportsEditToAnswerOnceTheGenerationIsDrawn() async throws {
    let editor = SheetEditorViewController(
      text: "1 + 1",
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
      defer: false
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    var latencies: [Duration] = []
    editor.editToAnswerHandler = { latencies.append($0) }
    await editor.scheduler?.waitUntilIdle()
    window.displayIfNeeded()
    #expect(latencies.count == 1)

    // Superseded generations are not reported; the newest is, once drawn.
    for digit in ["2", "3", "4"] {
      editor.textView.insertText(digit, replacementRange: NSRange(location: 5, length: 0))
    }
    await editor.scheduler?.waitUntilIdle()
    window.displayIfNeeded()
    #expect(latencies.count == 2)
    #expect(latencies.allSatisfy { $0 > .zero })

    // Redrawing without a new generation reports nothing.
    editor.textView.needsDisplay = true
    window.displayIfNeeded()
    #expect(latencies.count == 2)
  }
}
