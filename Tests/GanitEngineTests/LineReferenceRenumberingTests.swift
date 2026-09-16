import Foundation
import Testing

@testable import GanitEngine

@Suite
struct LineReferenceRenumberingTests {
  @Test
  func findsTheFirstLineAnEditMoves() throws {
    let old = "a\nbb\nc"
    // Return at the end of line 1 moves line 2 down.
    #expect(shift(old, NSRange(location: 1, length: 0), "\n") == [2, 1])
    // Return at the start of line 2 moves line 2 itself.
    #expect(shift(old, NSRange(location: 2, length: 0), "\n") == [2, 1])
    // Deleting line 2 whole moves line 3 up.
    #expect(shift(old, NSRange(location: 2, length: 3), "") == [3, -1])
    #expect(shift(old, NSRange(location: 2, length: 1), "x") == nil)
  }

  @Test
  func renumbersReferencesToMovedLinesOnly() throws {
    let source = "rent = 5\nphone = 1\nsubtotal\nx = line 3 + line 1 + line 9 // line 3\n# line 3"
    let edits = LineReferenceRenumbering.edits(
      in: source, firstMovedLine: 2, delta: 1, editedLines: 1...1,
      configuration: .englishUnitedStates)
    let text = NSMutableString(string: source)
    for edit in edits.reversed() {
      text.replaceCharacters(in: edit.range, with: edit.number)
    }
    #expect(
      text as String
        == "rent = 5\nphone = 1\nsubtotal\nx = line 4 + line 1 + line 9 // line 3\n# line 3")
  }

  private func shift(_ old: String, _ range: NSRange, _ replacement: String) -> [Int]? {
    LineReferenceRenumbering.shift(replacing: range, in: old, with: replacement).map {
      [$0.firstMovedLine, $0.delta]
    }
  }
}
