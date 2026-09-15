import Testing

@testable import GanitEngine

@Suite
struct SheetSourceTests {
  @Test
  func segmentsEveryTerminatorAndRoundTripsSource() {
    let text = "a\nb\r\nc\rd\n"
    let source = SheetSource(text)

    #expect(source.lines.map(\.text) == ["a", "b", "c", "d", ""])
    #expect(
      source.lines.map(\.terminator) == [
        .lineFeed, .carriageReturnLineFeed, .carriageReturn, .lineFeed, nil,
      ]
    )
    #expect(source.text == text)
    #expect(Set(source.lines.map(\.id)).count == 5)
    expectConsistent(source, text: text)
  }

  @Test
  func emptySourceHasOneLine() {
    let source = SheetSource("")
    #expect(source.lines.map(\.text) == [""])
    #expect(source.lines[0].terminator == nil)
  }

  @Test
  func rangesUseSheetUTF8AndGraphemeOffsets() {
    let text = "e\u{301}👍🏽\r\nπ = 3"
    let source = SheetSource(text)

    #expect(source.lines[1].range.lowerBound == text.utf8.count - "π = 3".utf8.count)
    #expect(source.lines[1].range.graphemeLowerBound == 3)
    expectConsistent(source, text: text)
  }

  @Test
  func typingWithinALineKeepsItsID() {
    var source = SheetSource("12 km\n5 m")
    let ids = source.lines.map(\.id)

    source.replace(utf8Range: 5..<5, with: " in miles")

    #expect(source.lines.map(\.text) == ["12 km in miles", "5 m"])
    #expect(source.lines.map(\.id) == ids)
  }

  @Test
  func returnKeepsTheIDOfTheContentThatDoesNotMove() {
    let original = SheetSource("first\nsecond")
    let ids = original.lines.map(\.id)

    var atStart = original
    atStart.replace(utf8Range: 6..<6, with: "\n")
    #expect(atStart.lines.map(\.text) == ["first", "", "second"])
    #expect(atStart.lines[0].id == ids[0])
    #expect(atStart.lines[2].id == ids[1])
    #expect(!ids.contains(atStart.lines[1].id))

    var atEnd = original
    atEnd.replace(utf8Range: 5..<5, with: "\n")
    #expect(atEnd.lines.map(\.text) == ["first", "", "second"])
    #expect(atEnd.lines[0].id == ids[0])
    #expect(atEnd.lines[2].id == ids[1])

    var inMiddle = original
    inMiddle.replace(utf8Range: 2..<2, with: "\n")
    #expect(inMiddle.lines.map(\.text) == ["fi", "rst", "second"])
    #expect(inMiddle.lines[0].id == ids[0])
    #expect(inMiddle.lines[2].id == ids[1])
    #expect(!ids.contains(inMiddle.lines[1].id))
  }

  @Test
  func joiningLinesKeepsTheFirstID() {
    var source = SheetSource("a\nb\nc")
    let ids = source.lines.map(\.id)

    source.replace(utf8Range: 1..<2, with: " + ")

    #expect(source.lines.map(\.text) == ["a + b", "c"])
    #expect(source.lines.map(\.id) == [ids[0], ids[2]])
  }

  @Test
  func mergesCarriageReturnWithAnInsertedLineFeed() {
    var source = SheetSource("a\rb")
    let ids = source.lines.map(\.id)

    source.replace(utf8Range: 2..<2, with: "\n")

    #expect(source.lines.map(\.text) == ["a", "b"])
    #expect(source.lines.map(\.terminator) == [.carriageReturnLineFeed, nil])
    #expect(source.lines.map(\.id) == ids)
  }

  @Test
  func deletedIDsAreNeverReused() {
    var source = SheetSource("a\nb")
    let removed = source.lines[1].id

    source.replace(utf8Range: 1..<3, with: "")
    source.replace(utf8Range: 1..<1, with: "\nb")

    #expect(source.lines.map(\.text) == ["a", "b"])
    #expect(source.lines[1].id != removed)
  }

  @Test
  func randomEditsMatchStringSplicingAndKeepIDsUnique() {
    var generator = SeededGenerator(seed: 0x5348_4545_5401)
    let fragments = ["", "x", "12", "\n", "\r", "\r\n", "é", "\u{301}", "👍🏽", " + ", "\n\n"]
    var text = "a\nbb\r\nccc\rd"
    var source = SheetSource(text)
    var retired = Set<LineID>()

    for _ in 0..<2_000 {
      let bytes = Array(text.utf8)
      let boundaries = (0...bytes.count).filter {
        $0 == bytes.count || bytes[$0] & 0b1100_0000 != 0b1000_0000
      }
      var lower = boundaries[generator.next(below: boundaries.count)]
      var upper = boundaries[generator.next(below: boundaries.count)]
      if lower > upper {
        swap(&lower, &upper)
      }
      let replacement = fragments[generator.next(below: fragments.count)]
      let before = Set(source.lines.map(\.id))
      let untouched = source.lines.prefix {
        $0.range.upperBound + ($0.terminator?.rawValue.utf8.count ?? 0) < lower
      }.map(\.id)

      source.replace(utf8Range: lower..<upper, with: replacement)
      text = String(
        decoding: bytes[..<lower] + Array(replacement.utf8) + bytes[upper...],
        as: UTF8.self
      )

      #expect(source.text == text)
      #expect(source.lines.map(\.text) == SheetSource(text).lines.map(\.text))
      let after = source.lines.map(\.id)
      #expect(Array(after.prefix(untouched.count)) == untouched)
      #expect(Set(after).count == after.count)
      #expect(retired.isDisjoint(with: after))
      retired.formUnion(before.subtracting(after))
      expectConsistent(source, text: text)
    }
  }

  private func expectConsistent(_ source: SheetSource, text: String) {
    var utf8 = 0
    var grapheme = 0
    for line in source.lines {
      #expect(line.range.lowerBound == utf8)
      #expect(line.range.graphemeLowerBound == grapheme)
      #expect(line.range.text(in: text).map(String.init) == line.text)
      utf8 = line.range.upperBound + (line.terminator?.rawValue.utf8.count ?? 0)
      grapheme = line.range.graphemeUpperBound + (line.terminator == nil ? 0 : 1)
    }
    #expect(utf8 == text.utf8.count)
    #expect(grapheme == text.count)
  }
}
