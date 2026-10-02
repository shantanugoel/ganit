import CryptoKit
import Foundation
import Testing

@testable import GanitEngine

/// Frozen version 1 table block fixtures. They were generated independently
/// of the Swift writer from docs/storage/table-blocks.md. Changing any byte is
/// a format change: update the specification and these checksums deliberately.
@Suite struct TableBlockFixtureTests {
  static let checksums = [
    "valid-two-tables.txt": "37b299a232a989563473c45d12387e2193747f71bb429a68310d2009255f015a",
    "line-endings-lf.txt": "c36f7261afa85900358eb2fd9d3419723d922ed7acb7310a3af3dcebf6009a34",
    "line-endings-cr.txt": "573bee5eb4ec9f2695da0dd6abd4b88c19144a8d1b4cd4546e12b30e89341243",
    "line-endings-crlf.txt": "79be7a55640acfd175307e3759d51bfb16ec3174dcd3310667df9bfd8092f56a",
    "line-endings-mixed.txt": "f396848434d208409677dc478f8ecd406d69d892a88f408f7f7df04e3668b819",
    "unicode.txt": "e99af58ac75a98ef77fd569722322fe036495cceac58b5701ff18f3e252ad472",
    "malformed-json.txt": "6398242e3fbfb649f6b6c6ee1787437bd49ed2c081a85dfe6003dee2d24438f7",
    "malformed-opener.txt": "5a5301c5415ad995893b8f9472711bfcd9455458cc4cf9d42a78511d255f02f1",
    "unsupported-version.txt": "b064520b4e4e7a73f060abfd7b6ea0e8043660abc97558941f25a121edfba8c3",
    "unterminated.txt": "7d529450301d3196b0538d8843b15258dfa482dbad639ba6484cb604f1653503",
    "duplicate-id.txt": "ca6256f5c86dbb3f1250979acab6bb160e4159daaa6f76943ef1bbd9e52221af",
    "stale-fingerprint.txt": "8aedb9f42035845789445dbba7da516d927e2e8f502ebe4d1f0547b068ca5994",
    "orphan-target.txt": "18adeb1454767bd9fa4627fdf725fd81fb9062788a5db5164a6afb304a85cb30",
  ]

  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appending(
      path: "Fixtures/TableBlocks", directoryHint: .isDirectory)

  static func bytes(_ name: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: directory.appending(path: name)))
  }

  /// The fixture as text, after checking it is valid UTF-8.
  static func text(_ name: String) throws -> String {
    let bytes = try bytes(name)
    return try #require(String(data: Data(bytes), encoding: .utf8))
  }

  static func id<Kind>(_ prefix: String, _ number: Int) -> TableIdentity<Kind> {
    TableIdentity(canonical: String(format: "\(prefix)-0000-4000-8000-%012x", number))!
  }

  @Test func fixturesAreFrozen() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
      .filter { !$0.hasPrefix(".") }
    #expect(Set(names) == Set(Self.checksums.keys))
    for (name, checksum) in Self.checksums {
      let digest = SHA256.hash(data: try Self.bytes(name))
      #expect(digest.map { String(format: "%02x", $0) }.joined() == checksum, "\(name) changed")
    }
  }

  @Test(arguments: checksums.keys.sorted())
  func parsingNeverChangesBytes(name: String) throws {
    let bytes = try Self.bytes(name)
    let text = try Self.text(name)
    let document = TableSourceDocument(text)
    #expect(document.source.utf8.elementsEqual(bytes))
    #expect(!document.blocks.isEmpty)
    var calculator = SheetCalculator()
    let result = try calculator.evaluate(SheetSource(text), context: try sheetContext())
    for block in document.blocks {
      #expect(bytes[block.utf8Range].elementsEqual(block.rawSource.utf8))
      #expect(block.utf8Range.lowerBound < block.payloadUTF8Range.lowerBound)
      #expect(block.payloadUTF8Range.upperBound <= block.utf8Range.upperBound)
      // Every block, valid or not, is quarantined: none of its lines answer.
      #expect(result.lines[block.physicalLines].allSatisfy { $0.result == nil })
    }
  }

  @Test func validTablesProjectEveryFrozenField() throws {
    let text = try Self.text("valid-two-tables.txt")
    let document = TableSourceDocument(text)
    #expect(document.diagnostics.isEmpty)
    #expect(document.blocks.map(\.physicalLines) == [2..<5, 6..<9])
    let rates = try #require(document.blocks[0].table)
    let items = try #require(document.blocks[1].table)
    #expect(rates.name == "Rates" && rates.rows.count == 2 && rates.cells.count == 4)

    let table: TableID = Self.id("20000000", 1)
    let column: (Int) -> ColumnID = { Self.id("20000000", 0x11 + $0) }
    let row: (Int) -> RowID = { Self.id("20000000", 0x21 + $0) }
    let binding: (Int) -> TableBindingID = { Self.id("20000000", 0x31 + $0) }
    #expect(items.id == table && items.name == "Items")
    #expect(items.rows == [row(0), row(1), row(2)])
    #expect(
      items.columns.map(\.header) == ["Item", "Qty", "Unit ] price", "Amount", "Notes", "Check"])
    #expect(items.columns.map(\.input) == [.text, .value, .value, .value, .text, .value])
    #expect(items.columns[1].unit == "kg" && items.columns[1].total == .average)
    #expect(items.columns[2].currency == "INR" && items.columns[2].unit == nil)
    #expect(items.columns[3].rule == "=[@Qty] * [@[Unit \\] price]]")
    #expect(items.columns[3].total == .sum && items.columns[4].total == .count)

    func cell(_ r: Int, _ c: Int) -> TableCell? {
      items.cells.first { $0.row == row(r) && $0.column == column(c) }
    }
    #expect(cell(0, 0)?.source == "Rice \"basmati\" [5|kg] \\ back")
    #expect(cell(1, 0)?.source == "दाल 🫘 豆腐")
    #expect(cell(2, 0)?.source == "Line one\nLine two")
    #expect(cell(2, 4)?.source == "1,5 kg ~ approx")
    #expect(cell(1, 3) == TableCell(row: row(1), column: column(3), source: "0", isOverride: true))
    #expect(cell(2, 3) == TableCell(row: row(2), column: column(3), source: "", isOverride: true))
    #expect(cell(0, 3) == nil)  // inherits the rule
    #expect(cell(0, 5)?.isFormula == true && cell(0, 1)?.isFormula == false)
    #expect(items.populatedCellCount == 16)

    let ledger = Dictionary(uniqueKeysWithValues: items.ledger.map { ($0.owner, $0) })
    let rule = try #require(ledger[.rule(column: column(3))])
    #expect(
      rule.bindings.map(\.target) == [
        .currentRow(column: column(1)), .currentRow(column: column(2)),
      ])
    #expect(rule.bindings.map(\.id) == [binding(0), binding(1)])
    let header = try #require(ledger[.cell(row: row(0), column: column(4))]?.bindings.first)
    #expect(header.target == .cell(table: table, row: nil, column: column(0)))
    let scalars = try #require(ledger[.cell(row: row(0), column: column(5))]?.bindings)
    #expect(scalars.map(\.locks) == [[false, false], [true, true]])
    #expect(scalars.map(\.operand) == [1..<3, 6..<10])
    let external = try #require(ledger[.cell(row: row(1), column: column(2))]?.bindings.first)
    #expect(
      external.target
        == .cell(
          table: Self.id("10000000", 1), row: Self.id("10000000", 0x22),
          column: Self.id("10000000", 0x12)))
    let ranges = try #require(ledger[.cell(row: row(1), column: column(5))]?.bindings)
    #expect(ranges.map(\.target.kind) == ["rect", "cols", "rows"])
    #expect(
      ranges[0].target
        == .rectangle(
          table: table, rows: .interval(first: row(0), last: row(2)),
          columns: .interval(first: column(1), last: column(2))))
    #expect(ranges[0].locks.count == 4 && ranges[2].locks == [true, false])
    let broken = try #require(ledger[.cell(row: row(2), column: column(5))]?.bindings)
    #expect(broken.map(\.isDeleted) == [false, true, true])
    #expect(broken[0].target == .namedColumn(table: table, column: column(3)))
    #expect(
      broken[1].target == .cell(table: table, row: Self.id("20000000", 0x29), column: column(1)))
    #expect(
      broken[2].target
        == .rectangle(
          table: table, rows: .retained([Self.id("20000000", 0x29)]),
          columns: .retained([column(1), column(2)])))
    #expect(broken[2].brokenMarker == "#REF!{range:\(binding(6).string)}")
    let source = Array(try #require(cell(2, 5)).source.utf8)
    for deleted in broken.dropFirst() {
      #expect(source[deleted.operand].elementsEqual(deleted.brokenMarker.utf8))
    }

    // The independently generated blocks are exactly the writer's output.
    for block in document.blocks {
      #expect(
        try TableSourceDocument.canonicalBlock(for: try #require(block.table)) == block.rawSource)
    }
    #expect(text.hasSuffix("| plain | pipe |\n| --- | --- |\ntotal\n"))
  }

  @Test func lineEndingsAndPrettyPayloadsProjectTheSameTable() throws {
    let names = ["lf", "cr", "crlf", "mixed"].map { "line-endings-\($0).txt" }
    let documents = try names.map { TableSourceDocument(try Self.text($0)) }
    let tables = documents.map { $0.blocks.first?.table }
    #expect(documents.allSatisfy { $0.blocks.count == 1 && $0.diagnostics.isEmpty })
    #expect(tables.allSatisfy { $0 != nil && $0 == tables[0] })
    #expect(documents.allSatisfy { $0.blocks[0].physicalLines == 2..<20 })
    let trip = try #require(tables[0])
    #expect(trip.name == "Trip" && trip.columns[1].currency == "USD")
    #expect(trip.cells.map(\.source) == ["Taxi", "30", "Hotel\r\nnight", "120"])
    #expect(trip.ledger.first?.owner == .rule(column: Self.id("30000000", 0x13)))
    for document in documents {
      let json = try #require(document.blocks[0].json)
      #expect(json["future"]?["n"]?.value == .number("12345678901234567890.123456789e-3"))
      #expect(json["c"]?.array?[0]["w"]?.value == .number("120"))
      #expect(document.blocks[0].rawSource.contains("\"w\": 120"))
    }
    var calculator = SheetCalculator()
    let result = try calculator.evaluate(
      SheetSource(try Self.text("line-endings-mixed.txt")), context: try sheetContext())
    #expect(result.lines.last?.result == .value(.number(.integer(IntegerValue(6)))))
  }

  @Test func unicodeIsNeverNormalized() throws {
    let text = try Self.text("unicode.txt")
    let document = TableSourceDocument(text)
    let block = try #require(document.blocks.first)
    #expect(block.physicalLines == 1..<4)
    let table = try #require(block.table)
    #expect(table.name.unicodeScalars.map(\.value).prefix(4) == [0x43, 0x61, 0x66, 0xE9])
    #expect(table.columns.map(\.header) == ["नाम", "表 | \"x\""])
    let sources = table.cells.map(\.source)
    #expect(sources[0].utf8.elementsEqual("Caf\u{E9}".utf8))
    #expect(sources[1].utf8.elementsEqual("Cafe\u{301}".utf8))
    #expect(sources[0] == sources[1])  // canonically equivalent, stored distinctly
    #expect(sources[2].utf8.elementsEqual("raw\u{2028}sep\u{2029}end".utf8))
    #expect(sources[3].utf8.dropFirst(3).elementsEqual(sources[2].utf8.dropFirst(3)))
    #expect(sources[4] == "😀 / 👍🏽")
    #expect(sources[5] == "१२३ 一二三 \t tab")
    let utf16 = try #require(document.utf16Range(forUTF8: block.utf8Range))
    #expect((text as NSString).substring(with: utf16) == block.rawSource)
  }

  @Test func invalidFixturesKeepSourceAndDiagnose() throws {
    func codes(_ name: String) throws -> [TableSourceDiagnostic.Code] {
      let document = TableSourceDocument(try Self.text(name))
      #expect(document.blocks.allSatisfy { $0.table == nil })
      return document.diagnostics.map(\.code)
    }
    #expect(try codes("malformed-json.txt") == [.malformed])
    #expect(try codes("malformed-opener.txt") == [.malformed, .malformed, .malformed])
    #expect(try codes("unsupported-version.txt") == [.unsupportedVersion])
    #expect(try codes("unterminated.txt") == [.unterminated])
    #expect(try codes("duplicate-id.txt") == [.duplicateIdentity, .duplicateIdentity])
    #expect(try codes("stale-fingerprint.txt") == [.staleBinding])
    #expect(try codes("orphan-target.txt") == [.orphanTarget])

    let opener = TableSourceDocument(try Self.text("malformed-opener.txt"))
    #expect(opener.blocks.map(\.physicalLines) == [0..<3, 3..<6, 6..<9])
    #expect(opener.blocks.allSatisfy { $0.version == nil })
    let unterminated = TableSourceDocument(try Self.text("unterminated.txt"))
    #expect(unterminated.blocks.map(\.physicalLines) == [1..<7])
    #expect(
      try sheetOutcomes(try Self.text("malformed-json.txt")) == ["1", nil, nil, nil, "2", nil])
    #expect(
      try sheetOutcomes(try Self.text("unsupported-version.txt"))[7...9] == ["10", "2", "12"])
  }

  @Test func specificationExampleIsCanonical() throws {
    let spec = try String(
      contentsOf: Self.directory.appending(path: "../../../../docs/storage/table-blocks.md"),
      encoding: .utf8)
    let example = try #require(
      spec.components(separatedBy: "## Example\n").last?
        .components(separatedBy: "```text\n").dropFirst().first?
        .components(separatedBy: "```").first)
    let block = try #require(TableSourceDocument(example).blocks.first)
    #expect(block.diagnostics.isEmpty)
    #expect(try TableSourceDocument.canonicalBlock(for: try #require(block.table)) == example)
  }

  @Test func addingTheMissingTableRepairsTheOrphan() throws {
    let text = try Self.text("orphan-target.txt")
    let gone = TableModel(
      id: Self.id("70000000", 0x91), name: "Gone",
      columns: [
        TableColumn(id: Self.id("70000000", 0x94), header: "A"),
        TableColumn(id: Self.id("70000000", 0x93), header: "B"),
      ],
      rows: [Self.id("70000000", 0x92)])
    let repaired = try TableSourceDocument.canonicalBlock(for: gone) + text
    let document = TableSourceDocument(repaired)
    #expect(document.diagnostics.isEmpty && document.blocks.allSatisfy { $0.table != nil })
  }
}
