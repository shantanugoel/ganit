import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct DefinitionsTests {
  @Test
  func answersWithVariablesAndUnitsDefinedElsewhere() async throws {
    let definitions = try definitions(of: "hourly rate = 90\n1 bag = 25 kg")
    let editor = try editor("hourly rate * 4\n3 bags in kg")
    let ids = editor.sheet.lines.map(\.id)
    #expect(answer(editor, ids[0]) == nil)

    editor.setDefinitions(definitions)
    await editor.scheduler?.waitUntilIdle()

    #expect(answer(editor, ids[0]) == "360")
    #expect(answer(editor, ids[1]) == "75 kg")
  }

  @Test
  func usesAUnitTheSheetItselfDefines() async throws {
    let editor = try editor("1 bag = 25 kg\n3 bags in kg")
    let ids = editor.sheet.lines.map(\.id)
    await editor.scheduler?.waitUntilIdle()

    #expect(answer(editor, ids[0]) == "25 kg")
    #expect(answer(editor, ids[1]) == "75 kg")
  }

  @Test
  func reportsTheDefinitionsItsOwnLinesDefine() async throws {
    let editor = try editor("rate = 2")
    var reported: [SheetDefinitions] = []
    editor.definitionsDidChange = { reported.append($0) }

    editor.textView.insertText(
      "\n1 bag = 25 kg", replacementRange: NSRange(location: 8, length: 0))
    await editor.scheduler?.waitUntilIdle()

    #expect(reported.last?.variables.keys.sorted() == ["rate"])
    #expect(reported.last?.units.map(\.name) == ["bag"])
    // Editing that leaves the definitions alone reports nothing new.
    let count = reported.count
    editor.textView.insertText(" ", replacementRange: NSRange(location: 8, length: 0))
    await editor.scheduler?.waitUntilIdle()
    #expect(reported.count == count)
  }

  private func definitions(of source: String) throws -> SheetDefinitions {
    try SheetDefinitions(source: source, context: try context())
  }

  private func answer(_ editor: SheetEditorViewController, _ id: LineID) -> String? {
    (editor.textView as? SheetTextView)?.answer(id).map(\.text)
  }

  private func editor(_ text: String) throws -> SheetEditorViewController {
    let editor = SheetEditorViewController(text: text, context: try context())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    return editor
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

  /// Windows outlive each test so their text views are not deallocated
  /// while AppKit still holds them.
  private static var windows: [NSWindow] = []
}
