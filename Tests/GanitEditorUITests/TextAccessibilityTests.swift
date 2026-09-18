import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct TextAccessibilityTests {
  private static var windows: [NSWindow] = []

  @Test
  func scalesSourceAnswersAndColumnTogether() async throws {
    let (editor, textView) = try await makeEditor("6 * 7")
    let item = { (action: Selector) in NSMenuItem(title: "", action: action, keyEquivalent: "") }
    let standardColumn = textView.answerColumnWidth
    #expect(!textView.validateUserInterfaceItem(item(#selector(SheetCommands.resetTextSize(_:)))))

    textView.increaseTextSize(nil)
    textView.increaseTextSize(nil)
    #expect(textView.textScale == 1.5)
    #expect(textView.font?.pointSize == 21)
    let cell = try #require(textView.answer(editor.sheet.lines[0].id))
    #expect((textView.attributes(for: cell, selected: false)[.font] as? NSFont)?.pointSize == 21)
    #expect(textView.answerColumnWidth >= standardColumn)

    textView.resetTextSize(nil)
    for _ in 0..<5 {
      textView.decreaseTextSize(nil)
    }
    #expect(textView.textScale == SheetTextView.textScales[0])
    #expect(
      !textView.validateUserInterfaceItem(item(#selector(SheetCommands.decreaseTextSize(_:)))))
  }

  @Test
  func exposesAnswersAndFailuresToAccessibility() async throws {
    let (_, textView) = try await makeEditor("6 * 7\n1 m + 1 s")
    textView.setSelectedRange(NSRange(location: 0, length: 0))

    let elements = (textView.accessibilityChildren() ?? []).compactMap {
      $0 as? NSAccessibilityElement
    }
    #expect(elements.map { $0.accessibilityLabel() ?? "" } == ["Line 1 result", "Line 2 error"])
    #expect(elements.first?.accessibilityValue() as? String == "42")
    #expect(
      elements.allSatisfy {
        $0.accessibilityRole() == .staticText && $0.accessibilityFrame().width > 0
      })
  }

  @Test
  func movesBetweenProblemsWithCommandsAndRotors() async throws {
    let (_, textView) = try await makeEditor("1 m + 1 s\n6 * 7\nfoo\n2 + 2")
    textView.setSelectedRange(NSRange(location: 12, length: 0))
    let item = { (action: Selector) in NSMenuItem(title: "", action: action, keyEquivalent: "") }
    #expect(textView.validateUserInterfaceItem(item(#selector(SheetCommands.nextProblem(_:)))))

    textView.nextProblem(nil)
    #expect(textView.selectedRange().location == 16)
    // Next wraps around to the first problem.
    textView.nextProblem(nil)
    #expect(textView.selectedRange().location == 0)
    textView.previousProblem(nil)
    #expect(textView.selectedRange().location == 16)

    let rotors = textView.accessibilityCustomRotors()
    #expect(rotors.map(\.label) == ["Problems", "Results"])
    let search = NSAccessibilityCustomRotor.SearchParameters()
    search.searchDirection = .next
    let first = try #require(rotors[0].itemSearchDelegate?.rotor(rotors[0], resultFor: search))
    #expect(first.targetRange == NSRange(location: 0, length: 9))
    #expect(first.customLabel == "Line 1: These quantities have incompatible dimensions.")
    search.currentItem = first
    let second = try #require(rotors[0].itemSearchDelegate?.rotor(rotors[0], resultFor: search))
    #expect(second.targetRange.location == 16)
    search.currentItem = second
    #expect(rotors[0].itemSearchDelegate?.rotor(rotors[0], resultFor: search) == nil)
    search.searchDirection = .previous
    search.currentItem = nil
    let lastResult = try #require(rotors[1].itemSearchDelegate?.rotor(rotors[1], resultFor: search))
    #expect(lastResult.customLabel == "Line 4: 4")

    let (_, clean) = try await makeEditor("6 * 7")
    #expect(!clean.validateUserInterfaceItem(item(#selector(SheetCommands.nextProblem(_:)))))
  }

  @Test
  func offersCustomActionsForAnswerInteractions() async throws {
    let (_, textView) = try await makeEditor("6 * 7")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let actions = try #require(textView.accessibilityCustomActions())

    #expect(
      actions.map(\.name) == [
        "Copy Result", "Copy with Results", "Copy Full Precision", "Show Interpretation",
        "Ask Assistant", "Change Answer…", "Cancel Request", "Insert Reference",
      ]
    )
    #expect(actions[0].handler?() == true)
    #expect(textView.pasteboard.string(forType: .string) == "42")
    #expect(actions[1].handler?() == true)
    #expect(textView.pasteboard.string(forType: .string) == "6 * 7\t42")
    #expect(actions[4].handler?() == false)
    #expect(actions[5].handler?() == false)
    #expect(actions[6].handler?() == false)
    // Nothing is above the first line to reference.
    #expect(actions[7].handler?() == false)
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
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    let textView = try #require(editor.textView as? SheetTextView)
    textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitTests-\(UUID().uuidString)"))
    await editor.scheduler?.waitUntilIdle()
    return (editor, textView)
  }
}
