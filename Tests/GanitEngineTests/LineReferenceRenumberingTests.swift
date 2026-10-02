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
  func tableBlockLinesAreNeverRenumbered() throws {
    var model = TableSample.model
    model.cells.append(
      TableCell(row: TableSample.first, column: TableSample.note, source: "see @1 and line 2"))
    let valid = try TableSample.block(model)
    let quarantined = "@ganit-table 9\nx = @2 + line 1\n@end-ganit-table\n"
    let blocks = valid + quarantined
    let source = "10\n20\n" + blocks + "30\n@1 + @2 + @9 + line 9"
    #expect(edit(source, 3, 0, "5\n") == "10\n5\n20\n" + blocks + "30\n@1 + @3 + @10 + line 10")
    #expect(edit(source, 0, 3, "") == "20\n" + blocks + "30\n@deleted + @1 + @8 + line 8")
    // An edit below the blocks leaves them alone too.
    let below = edit(source, (source as NSString).length - 21, 0, "1\n")
    #expect(below.hasPrefix("10\n20\n" + blocks + "30\n1\n"))
    // Lines entering a block are not rewritten, and lines leaving one keep
    // the numbers they had while quarantined.
    #expect(
      edit("10\n20\n@2 + @1\n", 0, 0, "@ganit-table 1\n") == "@ganit-table 1\n10\n20\n@2 + @1\n")
    #expect(edit("@ganit-table 1\n10\n20\n@3 + @2\n", 0, 15, "") == "10\n20\n@3 + @2\n")
    #expect(edit("10\n20\n@2 + @1", 0, 0, "5\n") == "5\n10\n20\n@3 + @2")
    // Unterminated blocks run to the end, and nothing in them is rewritten.
    #expect(
      edit("10\n20\n@2\n@ganit-table 1\n@2 + line 2", 3, 0, "5\n")
        == "10\n5\n20\n@3\n@ganit-table 1\n@2 + line 2")
  }

  /// Every recognized block, valid or not and in any line ending, keeps its
  /// exact bytes while prose references around it are renumbered or marked.
  @Test(arguments: [
    "valid-two-tables.txt", "line-endings-crlf.txt", "line-endings-cr.txt",
    "line-endings-mixed.txt", "malformed-json.txt", "malformed-opener.txt",
    "unsupported-version.txt", "duplicate-id.txt", "stale-fingerprint.txt", "orphan-target.txt",
  ])
  func blocksKeepTheirBytesWhileProseAroundThemIsRenumbered(fixture: String) throws {
    let blocks = try TableBlockFixtureTests.text(fixture)
    let head = "10\n20\n@2 + line 1\n"
    let source = head + blocks + "\n30\n@1 + @2 + line 3 + @99"
    let original = TableSourceDocument(blocks).blocks.map { Array($0.rawSource.utf8) }
    #expect(!original.isEmpty)
    let length = (source as NSString).length
    for (start, removed, inserted) in [
      (0, 0, "5\n"), (0, 3, ""), (4, 0, "\n"), (5, 1, ""), (3, 3, ""),
      (length, 0, "\n@3"), (length - 26, 0, "4\n"), (length - 27, 1, ""),
    ] {
      let changed = edit(source, start, removed, inserted)
      let after = TableSourceDocument(changed).blocks.map { Array($0.rawSource.utf8) }
      #expect(after == original, "\(start) \(removed) \(inserted.debugDescription)")
    }
    // The surrounding prose itself is still renumbered.
    #expect(edit(source, 0, 0, "5\n").hasPrefix("5\n10\n20\n@3 + line 2\n"))
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
