import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct ScrubbingTests {
  /// Option-dragging sideways on a number steps it, every answer that depends
  /// on it follows, and the whole drag undoes as one change.
  @Test
  func optionDraggingANumberStepsItAndTheAnswersFollow() async throws {
    let (editor, textView) = try await makeEditor("rent = 2,100\nrent * 12")
    await editor.scheduler?.waitUntilIdle()
    #expect(try await answers(editor) == ["2,100", "25,200"])

    let start = try point(atOffset: 8, in: textView)
    textView.mouseDown(with: try event(.leftMouseDown, at: start, in: textView, option: true))
    textView.mouseDragged(
      with: try event(
        .leftMouseDragged,
        at: NSPoint(x: start.x + 3 * SheetTextView.pointsPerScrubStep, y: start.y),
        in: textView,
        option: true
      )
    )
    #expect(textView.string == "rent = 2,103\nrent * 12")
    await editor.scheduler?.waitUntilIdle()
    #expect(try await answers(editor) == ["2,103", "25,236"])

    // Dragging back the way it came returns the number it started from, rather
    // than compounding what each step of the drag wrote.
    textView.mouseDragged(
      with: try event(
        .leftMouseDragged,
        at: NSPoint(x: start.x - 4 * SheetTextView.pointsPerScrubStep, y: start.y),
        in: textView,
        option: true
      )
    )
    #expect(textView.string == "rent = 2,096\nrent * 12")
    textView.mouseUp(with: try event(.leftMouseUp, at: start, in: textView, option: true))

    textView.undoManager?.undo()
    #expect(textView.string == "rent = 2,100\nrent * 12")
  }

  /// Shift steps ten of the number's last place at a time, and Command a tenth.
  @Test
  func shiftAndCommandCoarsenAndRefineTheStep() async throws {
    let (_, textView) = try await makeEditor("0.50")
    let start = try point(atOffset: 2, in: textView)
    let moved = NSPoint(x: start.x + SheetTextView.pointsPerScrubStep, y: start.y)

    textView.mouseDown(with: try event(.leftMouseDown, at: start, in: textView, option: true))
    textView.mouseDragged(
      with: try event(.leftMouseDragged, at: moved, in: textView, option: true, shift: true))
    #expect(textView.string == "0.60")
    textView.mouseDragged(
      with: try event(.leftMouseDragged, at: moved, in: textView, option: true, command: true))
    #expect(textView.string == "0.501")
    textView.mouseUp(with: try event(.leftMouseUp, at: moved, in: textView, option: true))
  }

  /// The keyboard steps the number at the insertion point, so scrubbing is not
  /// a gesture only a mouse can make. The insertion point stays in the number,
  /// so it can be stepped again.
  @Test
  func theKeyboardStepsTheNumberAtTheInsertionPoint() async throws {
    let (_, textView) = try await makeEditor("rent = 2,100")
    textView.setSelectedRange(NSRange(location: 9, length: 0))

    #expect(textView.validateUserInterfaceItem(item(#selector(SheetTextView.stepNumberUp(_:)))))
    textView.stepNumberUp(nil)
    #expect(textView.string == "rent = 2,101")
    textView.stepNumberUp(nil)
    #expect(textView.string == "rent = 2,102")
    textView.stepNumberDown(nil)
    #expect(textView.string == "rent = 2,101")

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(!textView.validateUserInterfaceItem(item(#selector(SheetTextView.stepNumberUp(_:)))))
  }

  private func item(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "", action: action, keyEquivalent: "")
  }

  private func answers(_ editor: SheetEditorViewController) async throws -> [String] {
    await editor.exportedLines().compactMap(\.answer)
  }

  /// Where a character sits in the text view, so a drag can start on it.
  private func point(atOffset offset: Int, in textView: SheetTextView) throws -> NSPoint {
    let layoutManager = try #require(textView.layoutManager)
    let container = try #require(textView.textContainer)
    let glyph = layoutManager.glyphIndexForCharacter(at: offset)
    let rect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1),
      in: container
    )
    return NSPoint(
      x: rect.midX + textView.textContainerOrigin.x,
      y: rect.midY + textView.textContainerOrigin.y
    )
  }

  private func event(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    in view: NSView,
    option: Bool,
    shift: Bool = false,
    command: Bool = false
  ) throws -> NSEvent {
    var flags: NSEvent.ModifierFlags = []
    if option {
      flags.insert(.option)
    }
    if shift {
      flags.insert(.shift)
    }
    if command {
      flags.insert(.command)
    }
    return try #require(
      NSEvent.mouseEvent(
        with: type,
        location: view.convert(point, to: nil),
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )
    )
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
    window.makeFirstResponder(textView)
    await editor.scheduler?.waitUntilIdle()
    return (editor, textView)
  }
}
