import Foundation
import Testing

@testable import GanitEngine

@Suite
struct LineReferenceRenumberingTests {
  @Test
  func insertsAndRemovesLinesAroundIntactTargets() {
    #expect(
      edit("10\n20\n@1 + @2 + line 2 // @2\n# @2", 3, 0, "5\n")
        == "10\n5\n20\n@1 + @3 + line 3 // @2\n# @2")
    #expect(edit("10\n20\n30\n@3 + line 1", 3, 3, "") == "10\n30\n@2 + line 1")
    #expect(edit("10\n20\n@2", 3, 0, "\n") == "10\n\n20\n@3")
    #expect(edit("10\n20\n@2", 5, 0, "\n") == "10\n20\n\n@2")
  }

  @Test
  func deletionCannotSilentlyRetargetAndMarkersSurviveFurtherEdits() {
    let deleted = edit("10\n20\n30\n@2 + line 2 + @3", 3, 3, "")
    #expect(deleted == "10\n30\n@deleted + @deleted + @2")
    #expect(edit(deleted, 0, 0, "5\n") == "5\n10\n30\n@deleted + @deleted + @3")
    #expect(edit("10\n20\n@2", 3, 2, "") == "10\n\n@deleted")
    #expect(edit("10\n20\n@2", 3, 2, "50") == "10\n50\n@2")
  }

  @Test
  func splitsAndJoinsRequireAnExplicitChoice() {
    #expect(
      edit("10\n20 + 30\n@2 + line 2", 5, 0, "\n")
        == "10\n20\n + 30\n@split + @split")
    #expect(edit("10\n20\n@1 + @2", 2, 1, "") == "1020\n@split + @split")
    #expect(edit("10\n\n20\n@3", 3, 1, "") == "10\n20\n@2")
    // References in surviving suffixes still get repaired; pasted ones are literal.
    #expect(edit("10\n20\n30\n@2", 3, 3, "@1\n") == "10\n@1\n30\n@deleted")
    #expect(edit("10\n20 + @2", 5, 0, "\n") == "10\n20\n + @split")
  }

  @Test
  func preservesCommentsPromptsOutOfRangeReferencesAndUnicodeOffsets() {
    let source = "# 🧮\n10\n20\n@2 + line 3 + @99 // @3\nask_assistant(email @3 and {@3})"
    #expect(
      edit(source, 8, 0, "5\n")
        == "# 🧮\n10\n5\n20\n@2 + line 4 + @99 // @3\nask_assistant(email @3 and {@4})")
    #expect(edit("10\r\n20\r\n@2", 4, 0, "5\r\n") == "10\r\n5\r\n20\r\n@3")
    #expect(edit("10\r20\r@2", 3, 0, "5\r") == "10\r5\r20\r@3")
  }

  @Test
  func disjointReplacementsPreserveTargetsAndRespectExplicitReferences() {
    #expect(
      edit(
        "1\n2\n3\n@2 + @3", [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)],
        ["10", "30"]) == "10\n2\n30\n@2 + @3")
    #expect(
      edit(
        "1\n2\n3\n@2 + @3", [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)],
        ["", ""]) == "\n2\n\n@2 + @deleted")
    #expect(
      edit(
        "1\n2\n3\n@2 + @3", [NSRange(location: 0, length: 0), NSRange(location: 11, length: 2)],
        ["5\n", "@1"]) == "5\n1\n2\n3\n@3 + @1")
    #expect(
      edit(
        "1\n2\n3\n@2 + @3", [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)],
        ["", ""]) == "2\n@1 + @deleted")
  }

  @Test(arguments: ["\n", "\r", "\r\n"])
  func prefixEditsPreserveReferencedLines(_ newline: String) {
    let source = ["1", "2", "3", "@2 + @3"].joined(separator: newline)
    let second = 1 + newline.utf16.count
    let third = 2 * second
    let commented = edit(
      source,
      [NSRange(location: second, length: 0), NSRange(location: third, length: 0)],
      ["// ", "// "])
    #expect(commented == ["1", "// 2", "// 3", "@2 + @3"].joined(separator: newline))
    #expect(
      edit(
        commented,
        [NSRange(location: second, length: 3), NSRange(location: third + 3, length: 3)],
        ["", ""]) == source)
  }

  private func edit(_ source: String, _ ranges: [NSRange], _ replacements: [String]) -> String {
    let edits = LineReferenceRenumbering.edits(
      replacing: ranges, in: source, with: replacements, configuration: .englishUnitedStates)
    let text = NSMutableString(string: source)
    for (range, replacement) in zip(ranges, replacements).reversed() {
      text.replaceCharacters(in: range, with: replacement)
    }
    for edit in edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.number) }
    return text as String
  }

  private func edit(_ source: String, _ start: Int, _ length: Int, _ replacement: String) -> String
  {
    let range = NSRange(location: start, length: length)
    let edits = LineReferenceRenumbering.edits(
      replacing: range, in: source, with: replacement, configuration: .englishUnitedStates)
    let text = NSMutableString(string: source)
    text.replaceCharacters(in: range, with: replacement)
    for edit in edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.number) }
    return text as String
  }
}
