import Foundation
import Testing

@testable import GanitEngine

/// Deterministic identities and a small valid table for codec tests.
enum TableSample {
  static func id<Kind>(_ number: Int) -> TableIdentity<Kind> {
    TableIdentity(UUID(uuidString: String(format: "abcdef00-0000-4000-8000-%012x", number))!)
  }
  static let table: TableID = id(1)
  static let qty: ColumnID = id(0x11)
  static let price: ColumnID = id(0x12)
  static let total: ColumnID = id(0x13)
  static let note: ColumnID = id(0x14)
  static let first: RowID = id(0x21)
  static let second: RowID = id(0x22)
  static let rule = "=[@Qty] * [@Price]"

  /// Qty, Price (INR), Total (rule with a blank override) and Note (text).
  static var model: TableModel {
    TableModel(
      id: table, name: "Items",
      columns: [
        TableColumn(id: qty, header: "Qty", unit: "kg"),
        TableColumn(id: price, header: "Price", currency: "INR"),
        TableColumn(id: total, header: "Total", rule: rule, total: .sum),
        TableColumn(id: note, header: "Note", input: .text),
      ],
      rows: [first, second],
      cells: [
        TableCell(row: first, column: qty, source: "2"),
        TableCell(row: first, column: price, source: "10"),
        TableCell(row: second, column: qty, source: "3"),
        TableCell(row: second, column: price, source: "=B2 + 1"),
        TableCell(row: second, column: total, source: "", isOverride: true),
      ],
      ledger: [
        TableLedgerEntry(
          owner: .rule(column: total), fingerprint: rule,
          bindings: [
            TableBinding(id: id(0x31), operand: 1..<7, target: .currentRow(column: qty)),
            TableBinding(id: id(0x32), operand: 10..<18, target: .currentRow(column: price)),
          ]),
        TableLedgerEntry(
          owner: .cell(row: second, column: price), fingerprint: "=B2 + 1",
          bindings: [
            TableBinding(
              operand: 1..<3, target: .cell(table: table, row: first, column: price),
              locks: [false, false])
          ]),
      ])
  }

  static func block(_ model: TableModel = model, _ ending: LineTerminator = .lineFeed) throws
    -> String
  {
    try TableSourceDocument.canonicalBlock(for: model, lineEnding: ending)
  }

  static func code(_ model: TableModel) -> TableSourceDiagnostic.Code? {
    do {
      try model.validate()
      return nil
    } catch let error as TableBlockError {
      return error.code
    } catch {
      return nil
    }
  }

  static func codes(_ text: String) -> [TableSourceDiagnostic.Code] {
    TableSourceDocument(text).diagnostics.map(\.code)
  }
}

@Suite struct TableJSONTests {
  @Test func rejectsEverythingButStrictJSON() {
    let invalid = [
      "{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "[1,]", "{\"a\":1,}", "01", "-01", "1.",
      ".5", "+1", "NaN", "Infinity", "1 2", "\"\\q\"", "\"\\ud800\"", "\"\\udc00\"",
      "\"\\ud800\\u0041\"", "\"\\ud800x\"", "\"\\u12\"", "\"a\u{1}b\"", "\"a\nb\"", "tru", "nul",
      "{'a':1}", "{a:1}", "\"\\u\u{10}\u{10}\u{14}\u{11}\"", "\"\\u00g0\"", "\"\\u00G0\"", "", " ",
      "[", "\"open",
      String(repeating: "[", count: 33) + String(repeating: "]", count: 33),
    ]
    for json in invalid {
      #expect(throws: TableCodecError.invalidJSON, "\(json.debugDescription)") {
        try TableJSON.parse(json)
      }
    }
    let deepest = String(repeating: "[", count: 32) + String(repeating: "]", count: 32)
    #expect((try? TableJSON.parse(deepest)) != nil)
  }

  @Test func keepsExactLexemesSpansAndDecodedText() throws {
    let text =
      " {\"n\" : 12345678901234567890.50e-3, \"s\":\"\\ud83d\\ude00\\/\\u00e9\\n\", \"k\":[true,null]} "
    let tree = try TableJSON.parse(text)
    #expect(tree["n"]?.value == .number("12345678901234567890.50e-3"))
    #expect(tree["s"]?.string == "😀/é\n")
    #expect(tree["k"]?.array?.count == 2)
    let bytes = Array(text.utf8)
    let member = try #require(tree.members?[1])
    #expect(String(decoding: bytes[member.keyUTF8Range], as: UTF8.self) == "\"s\"")
    #expect(
      String(decoding: bytes[tree.utf8Range], as: UTF8.self)
        == text.trimmingCharacters(in: .whitespaces))
    #expect(tree["missing"] == nil)
  }

  @Test func indexAcceptsOnlyPlainNonNegativeIntegers() throws {
    let tree = try TableJSON.parse("[0, 7, -1, 1.0, 1e0, 99999999999999999999]")
    #expect(tree.array?.map(\.index) == [0, 7, nil, nil, nil, nil])
  }

  @Test func quotingIsCanonicalAndRoundTrips() throws {
    let text = "a\"b\\c\n\r\t\u{8}\u{C}\u{1}\u{7F}\u{80}\u{85}\u{9F}\u{A0}\u{2028}\u{2029}/é😀"
    let quoted = TableJSON.quoted(text)
    #expect(
      quoted
        == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u007f\\u0080\\u0085\\u009f\u{A0}\\u2028\\u2029/é😀\""
    )
    #expect(try TableJSON.parse(quoted).string?.utf8.elementsEqual(text.utf8) == true)
    let decomposed = "e\u{301}"
    #expect(TableJSON.quoted(decomposed).utf8.elementsEqual("\"e\u{301}\"".utf8))
  }
}

@Suite struct TableSegmentationTests {
  @Test func openerAndCloserAreExactPhysicalLines() throws {
    let block = try TableSample.block()
    for prose in [
      " @ganit-table 1", "x @ganit-table 1", "@ganit-tables 1", "@ganit-table1", "| A | B |",
      "@end-ganit-table", "@GANIT-TABLE 1",
    ] {
      #expect(TableSourceDocument(prose + "\n" + "@end-ganit-table").blocks.isEmpty, "\(prose)")
    }
    let body = block.split(separator: "\n")[1]
    let indentedCloser = "@ganit-table 1\n" + body + "\n @end-ganit-table\n2 + 3"
    #expect(TableSample.codes(indentedCloser) == [.unterminated])
    let trailingCloser = "@ganit-table 1\n" + body + "\n@end-ganit-table \n2 + 3"
    #expect(TableSample.codes(trailingCloser) == [.unterminated])
  }

  @Test(
    arguments: [
      ("@ganit-table", TableSourceDiagnostic.Code.malformed, nil),
      ("@ganit-table 1 ", .malformed, nil), ("@ganit-table  1", .malformed, nil),
      ("@ganit-table\t1", .malformed, nil), ("@ganit-table 01", .malformed, nil),
      ("@ganit-table x", .malformed, nil), ("@ganit-table 2", .unsupportedVersion, 2),
      ("@ganit-table 0", .unsupportedVersion, 0),
      ("@ganit-table 99999999999999999999999", .unsupportedVersion, nil),
    ] as [(String, TableSourceDiagnostic.Code, Int?)])
  func badOpenersQuarantineWithoutProjection(
    opener: String, code: TableSourceDiagnostic.Code, version: Int?
  ) throws {
    let body = try TableSample.block().split(separator: "\n")[1]
    let text = "a = 1\n" + opener + "\n" + body + "\n@end-ganit-table\nb = 2"
    let document = TableSourceDocument(text)
    let block = try #require(document.blocks.first)
    #expect(document.blocks.count == 1)
    #expect(block.diagnostics.map(\.code) == [code])
    #expect(block.version == version)
    #expect(block.table == nil && block.json == nil)
    #expect(block.physicalLines == 1..<4)
    #expect(block.rawSource == opener + "\n" + body + "\n@end-ganit-table\n")
  }

  @Test func unterminatedQuarantinesLaterOpenersThroughEOF() throws {
    let body = try TableSample.block().split(separator: "\n")[1]
    let text = "1\n@ganit-table 1\n3 + 4\n@ganit-table 1\n" + body + "\n@end-ganit-table \nx"
    let document = TableSourceDocument(text)
    #expect(document.blocks.count == 1)
    #expect(document.diagnostics.map(\.code) == [.unterminated])
    #expect(document.blocks[0].rawSource == String(text.dropFirst(2)))
    #expect(document.blocks[0].physicalLines == 1..<7)
    #expect(TableSample.codes("@ganit-table 1") == [.unterminated])
  }

  @Test func emptyAndNonObjectPayloadsAreMalformed() {
    for payload in ["", "[]", "null", "\"x\"", "{}"] {
      let text = "@ganit-table 1\n" + payload + (payload.isEmpty ? "" : "\n") + "@end-ganit-table"
      #expect(TableSample.codes(text) == [.malformed], "\(payload)")
    }
  }

  @Test func tableFreeSheetsDoNoTableWork() throws {
    let text = (0..<200).map { "line \($0) = \($0) // @ganit-table 1" }.joined(separator: "\n")
    let document = TableSourceDocument(SheetSource(text))
    #expect(document.blocks.isEmpty && document.diagnostics.isEmpty)
    #expect(document.work == TableSourceDocument.Work())
    var calculator = SheetCalculator()
    let first = try calculator.evaluate(SheetSource(text), context: try sheetContext())
    #expect(first.tableDiagnostics.isEmpty && first.tableWork == TableSourceDocument.Work())
    #expect(first.evaluatedLineIDs.count == 200)
    let second = try calculator.evaluate(SheetSource(text), context: try sheetContext())
    #expect(second.evaluatedLineIDs.isEmpty && second.parsedLineIDs.isEmpty)
  }

  @Test func unchangedBlocksAreReusedAtTheirNewPosition() throws {
    var sheet = SheetSource("a = 1\n" + (try TableSample.block()) + "b = 2")
    let before = TableSourceDocument(sheet)
    sheet.replace(utf8Range: 0..<0, with: "é\r\n")
    let after = TableSourceDocument(sheet, reusing: before.blocks)
    #expect(before.work == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    #expect(after.work == TableSourceDocument.Work(blocks: 1, decoded: 0, reused: 1))
    #expect(after.blocks == TableSourceDocument(sheet).blocks)
    let old = try #require(before.blocks.first)
    let new = try #require(after.blocks.first)
    #expect(new.table == old.table && new.json == old.json && new.table != nil)
    #expect(new.physicalLines == 2..<5)
    #expect(new.utf8Range == (old.utf8Range.lowerBound + 4)..<(old.utf8Range.upperBound + 4))
    #expect(after.source.utf8.elementsEqual(sheet.text.utf8))
    let reused = TableSourceDocument(sheet, reusing: after.blocks)
    #expect(reused.blocks == after.blocks && reused.work.reused == 1)
  }

  @Test(arguments: ["\n", "\r", "\r\n"])
  func sourceCoordinatesMapAcrossLineEndingsAndUnicode(ending: String) throws {
    let block = try TableSample.block(
      TableSample.model, LineTerminator(rawValue: ending) ?? .lineFeed)
    let text = "e\u{301}👍🏽\u{2028} हिंदी" + ending + block + "0.1 + 0.2"
    let document = TableSourceDocument(text)
    let found = try #require(document.blocks.first)
    #expect(found.diagnostics.isEmpty && found.table == TableSample.model)
    #expect(found.physicalLines == 1..<4)
    #expect(Array(text.utf8)[found.utf8Range].elementsEqual(found.rawSource.utf8))
    #expect(document.source.utf8.elementsEqual(text.utf8))
    let name = try #require(found.json?["n"])
    #expect(Array(text.utf8)[found.sheetRange(of: name)].elementsEqual("\"Items\"".utf8))
    let utf16 = try #require(document.utf16Range(forUTF8: found.utf8Range))
    #expect((text as NSString).substring(with: utf16) == found.rawSource)
    #expect(document.utf8Range(forUTF16: utf16) == found.utf8Range)
    #expect(document.utf16Range(forUTF8: 2..<3) == nil)
    #expect(document.utf8Range(forUTF16: NSRange(location: 4, length: 1)) == nil)
    #expect(document.utf16Range(forUTF8: 0..<(text.utf8.count + 1)) == nil)
  }
}

@Suite struct TableValidationTests {
  typealias Sample = TableSample

  @Test func sampleIsValidAndCountsPopulatedCells() {
    #expect(Sample.code(Sample.model) == nil)
    // Four non-empty records plus one inherited rule cell; the blank
    // override is not populated.
    #expect(Sample.model.populatedCellCount == 5)
  }

  @Test func namesAndHeaders() {
    for name in ["", " Items", "Items ", "sheet", "SHEET", "a\nb", "a\u{2028}b", "a\u{0}b"] {
      var model = Sample.model
      model.name = name
      #expect(Sample.code(model) == .invalidRecord, "\(name.debugDescription)")
    }
    var unicode = Sample.model
    unicode.name = "Café ☕ हिसाब | [x]"
    #expect(Sample.code(unicode) == nil)
    for header in ["", "qty", "QTY", "a\nb", " Note"] {
      var model = Sample.model
      model.columns[3].header = header
      #expect(Sample.code(model) == .invalidRecord, "\(header.debugDescription)")
    }
    var literal = Sample.model
    literal.columns[3].header = "Unit price USD kg | \"q\" [x] \\"
    #expect(Sample.code(literal) == nil)
    var empty = Sample.model
    empty.columns = []
    empty.cells = []
    empty.ledger = []
    #expect(Sample.code(empty) == .invalidRecord)
  }

  @Test func columnPolicies() {
    var textUnit = Sample.model
    textUnit.columns[3].unit = "kg"
    var both = Sample.model
    both.columns[0].currency = "USD"
    var lowercase = Sample.model
    lowercase.columns[1].currency = "inr"
    var bareRule = Sample.model
    bareRule.columns[2].rule = "[@Qty]"
    var spacedUnit = Sample.model
    spacedUnit.columns[0].unit = " kg"
    for model in [textUnit, both, lowercase, bareRule, spacedUnit] {
      #expect(Sample.code(model) == .invalidRecord)
    }
    var textFormula = Sample.model
    textFormula.cells.append(TableCell(row: Sample.first, column: Sample.note, source: "=A1"))
    #expect(Sample.code(textFormula) == nil)
  }

  @Test func cellRecords() {
    var overrideWithoutRule = Sample.model
    overrideWithoutRule.cells[0].isOverride = true
    var plainInRuleColumn = Sample.model
    plainInRuleColumn.cells[4].isOverride = false
    plainInRuleColumn.cells[4].source = "5"
    var emptyRecord = Sample.model
    emptyRecord.cells[0].source = ""
    for model in [overrideWithoutRule, plainInRuleColumn, emptyRecord] {
      #expect(Sample.code(model) == .invalidRecord)
    }
    var orphan = Sample.model
    orphan.cells[0].row = Sample.id(0x99)
    #expect(Sample.code(orphan) == .orphanTarget)
    var duplicate = Sample.model
    duplicate.cells.append(duplicate.cells[0])
    #expect(Sample.code(duplicate) == .duplicateIdentity)
    var valueOverride = Sample.model
    valueOverride.cells[4].source = "=1 + 1"
    valueOverride.ledger.append(
      TableLedgerEntry(
        owner: .cell(row: Sample.second, column: Sample.total), fingerprint: "=1 + 1",
        bindings: [
          TableBinding(
            operand: 1..<2, target: .cell(table: Sample.table, row: nil, column: Sample.qty),
            locks: [false, false])
        ]))
    #expect(Sample.code(valueOverride) == nil)
  }

  @Test func identitiesHaveOneRole() {
    var rowAsColumn = Sample.model
    rowAsColumn.rows[1] = RowID(Sample.qty.uuid)
    var bindingAsRow = Sample.model
    bindingAsRow.ledger[0].bindings[0].id = TableBindingID(Sample.first.uuid)
    var duplicateBinding = Sample.model
    duplicateBinding.ledger[0].bindings[1].id = duplicateBinding.ledger[0].bindings[0].id
    var targetRole = Sample.model
    targetRole.ledger[1].bindings[0] = TableBinding(
      operand: 1..<3, target: .cell(table: TableID(Sample.qty.uuid), row: nil, column: Sample.qty),
      locks: [false, false])
    for model in [rowAsColumn, bindingAsRow, duplicateBinding, targetRole] {
      #expect(Sample.code(model) == .duplicateIdentity)
    }
  }

  @Test func ledgerMustMatchItsOwnerSource() {
    var stale = Sample.model
    stale.cells[3].source = "=B2 + 2"
    var notFormula = Sample.model
    notFormula.ledger[1].owner = .cell(row: Sample.first, column: Sample.qty)
    var missingOwner = Sample.model
    missingOwner.ledger[1].owner = .cell(row: Sample.first, column: Sample.note)
    var twice = Sample.model
    twice.ledger.append(twice.ledger[1])
    var includesEquals = Sample.model
    includesEquals.ledger[1].bindings[0].operand = 0..<3
    var overlapping = Sample.model
    overlapping.ledger[0].bindings[1].operand = 5..<18
    var unordered = Sample.model
    unordered.ledger[0].bindings.reverse()
    var outside = Sample.model
    outside.ledger[1].bindings[0].operand = 1..<99
    var empty = Sample.model
    empty.ledger[1].bindings[0].operand = 2..<2
    for model in [
      stale, notFormula, missingOwner, twice, includesEquals, overlapping, unordered, outside,
      empty,
    ] {
      #expect(Sample.code(model) == .staleBinding)
    }
    var noBindings = Sample.model
    noBindings.ledger[1].bindings = []
    #expect(Sample.code(noBindings) == .invalidRecord)

    // Operand spans are UTF-8 offsets and never split a scalar.
    var unicode = Sample.model
    unicode.cells[3].source = "=é + B2"
    unicode.ledger[1].fingerprint = "=é + B2"
    unicode.ledger[1].bindings[0].operand = 6..<8
    #expect(Sample.code(unicode) == nil)
    unicode.ledger[1].bindings[0].operand = 2..<8
    #expect(Sample.code(unicode) == .staleBinding)
  }

  @Test func bindingShapesPerKind() {
    let rect = TableReferenceTarget.rectangle(
      table: Sample.table, rows: .interval(first: Sample.first, last: Sample.second),
      columns: .interval(first: Sample.qty, last: Sample.price))
    func with(_ binding: TableBinding) -> TableModel {
      var model = Sample.model
      model.cells[3].source = "=sum(XXXXX)"
      model.ledger[1] = TableLedgerEntry(
        owner: .cell(row: Sample.second, column: Sample.price), fingerprint: "=sum(XXXXX)",
        bindings: [binding])
      return model
    }
    let span = 5..<10
    #expect(
      Sample.code(
        with(
          TableBinding(
            id: Sample.id(0x40), operand: span, target: rect, locks: [false, false, true, true])))
        == nil)
    let invalid = [
      TableBinding(id: Sample.id(0x40), operand: span, target: rect, locks: [false, false]),
      TableBinding(operand: span, target: rect, locks: [false, false, false, false]),
      TableBinding(
        id: Sample.id(0x40), operand: span,
        target: .cell(table: Sample.table, row: Sample.first, column: Sample.qty),
        locks: [false, false]),
      TableBinding(
        id: Sample.id(0x40), operand: span,
        target: .namedColumn(table: Sample.table, column: Sample.qty),
        locks: [false]),
      TableBinding(
        id: Sample.id(0x40), operand: span,
        target: .columns(table: Sample.table, .interval(first: Sample.qty, last: Sample.qty)),
        locks: [false, false, false, false]),
    ]
    for binding in invalid {
      #expect(Sample.code(with(binding)) == .malformed, "\(binding.target.kind)")
    }
    let backwards = TableBinding(
      id: Sample.id(0x40), operand: span,
      target: .rectangle(
        table: Sample.table, rows: .interval(first: Sample.second, last: Sample.first),
        columns: .interval(first: Sample.qty, last: Sample.qty)),
      locks: [false, false, false, false])
    #expect(Sample.code(with(backwards)) == .invalidRecord)
    let missing = TableBinding(
      id: Sample.id(0x40), operand: span,
      target: .rows(table: Sample.table, .interval(first: Sample.first, last: Sample.id(0x99))),
      locks: [false, false])
    #expect(Sample.code(with(missing)) == .orphanTarget)
    let retainedLive = TableBinding(
      id: Sample.id(0x40), operand: span,
      target: .rows(table: Sample.table, .retained([Sample.first])),
      locks: [false, false])
    #expect(Sample.code(with(retainedLive)) == .malformed)
    var repeated = retainedLive
    repeated.target = .rows(table: Sample.table, .retained([Sample.id(0x29), Sample.id(0x29)]))
    repeated.isDeleted = true
    #expect(Sample.code(with(repeated)) == .duplicateIdentity)
    repeated.target = .rows(table: Sample.table, .retained([]))
    #expect(Sample.code(with(repeated)) == .malformed)
  }

  @Test func deletedBindingsSpellTheirMarkerAndStayDeleted() {
    let gone: RowID = Sample.id(0x29)
    let goneColumn: ColumnID = Sample.id(0x19)
    func deleted(_ target: TableReferenceTarget, id: TableBindingID? = nil, locks: [Bool])
      -> (TableModel, TableBinding)
    {
      var binding = TableBinding(
        id: id, operand: 1..<2, target: target, locks: locks, isDeleted: true)
      let marker = binding.brokenMarker
      binding.operand = 1..<(1 + marker.utf8.count)
      var model = Sample.model
      model.cells[3].source = "=" + marker + " + 1"
      model.ledger[1] = TableLedgerEntry(
        owner: .cell(row: Sample.second, column: Sample.price), fingerprint: model.cells[3].source,
        bindings: [binding])
      return (model, binding)
    }
    let scalar = deleted(
      .cell(table: Sample.table, row: gone, column: Sample.qty), locks: [true, false])
    #expect(
      scalar.1.brokenMarker == "#REF!{\(Sample.table.string)/\(gone.string)/\(Sample.qty.string)}")
    #expect(Sample.code(scalar.0) == nil)
    let header = deleted(
      .cell(table: Sample.table, row: nil, column: goneColumn), locks: [false, false])
    #expect(header.1.brokenMarker.contains("/header/"))
    #expect(Sample.code(header.0) == nil)
    let range = deleted(
      .rectangle(
        table: Sample.table, rows: .retained([gone]),
        columns: .retained([Sample.qty, Sample.price])),
      id: Sample.id(0x41), locks: [false, false, false, false])
    #expect(range.1.brokenMarker == "#REF!{range:abcdef00-0000-4000-8000-000000000041}")
    #expect(Sample.code(range.0) == nil)
    let named = deleted(
      .namedColumn(table: Sample.table, column: goneColumn), id: Sample.id(0x42), locks: [])
    #expect(Sample.code(named.0) == nil)

    // A target that still exists cannot carry a marker, including a range
    // with survivors on both axes and a reused live identity.
    let alive = deleted(
      .cell(table: Sample.table, row: Sample.first, column: Sample.qty), locks: [false, false])
    let survivors = deleted(
      .rectangle(
        table: Sample.table, rows: .retained([gone, Sample.first]), columns: .retained([Sample.qty])
      ),
      id: Sample.id(0x41), locks: [false, false, false, false])
    let current = deleted(.currentRow(column: Sample.qty), id: Sample.id(0x42), locks: [])
    for model in [alive.0, survivors.0, current.0] {
      #expect(Sample.code(model) == .staleBinding)
    }
    var wrongMarker = scalar.0
    wrongMarker.cells[3].source = wrongMarker.cells[3].source.uppercased()
    wrongMarker.ledger[1].fingerprint = wrongMarker.cells[3].source
    #expect(Sample.code(wrongMarker) == .staleBinding)
    var liveMarker = scalar.0
    liveMarker.ledger[1].bindings[0].isDeleted = false
    liveMarker.ledger[1].bindings[0].target = .cell(
      table: Sample.table, row: Sample.first, column: Sample.qty)
    #expect(Sample.code(liveMarker) == .staleBinding)
  }
}

@Suite struct TableWireTests {
  typealias Sample = TableSample

  @Test func writerIsCanonicalAndDeterministic() throws {
    let block = try Sample.block()
    var shuffled = Sample.model
    shuffled.cells.reverse()
    shuffled.ledger.reverse()
    #expect(try Sample.block(shuffled) == block)
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 4 && lines[0] == "@ganit-table 1" && lines[2] == "@end-ganit-table")
    #expect(lines[3].isEmpty)
    #expect(lines[1].hasPrefix("{\"ids\":[\"\(Sample.table.string)\",\"\(Sample.qty.string)\""))
    #expect(
      lines[1].contains(
        "\"t\":0,\"n\":\"Items\",\"c\":[{\"i\":1,\"h\":\"Qty\",\"p\":\"value\",\"u\":\"kg\"}"))
    #expect(
      lines[1].contains(
        "{\"o\":[null,3],\"f\":\"=[@Qty] * [@Price]\",\"e\":[{\"i\":7,\"k\":\"current\",\"a\":[1,7],\"t\":[1]}"
      ))
    #expect(lines[1].contains("{\"a\":[6,3],\"s\":\"\",\"o\":true}"))
    #expect(!lines[1].contains(" :") && !lines[1].contains(", "))
    let crlf = try Sample.block(Sample.model, .carriageReturnLineFeed)
    #expect(crlf == block.replacingOccurrences(of: "\n", with: "\r\n"))
    let parsed = try #require(TableSourceDocument(block).blocks.first?.table)
    #expect(parsed == Sample.model)
  }

  @Test func writerRejectsInvalidModelsAndNeverMints() throws {
    var invalid = Sample.model
    invalid.name = "sheet"
    #expect(throws: TableBlockError.self) { try Sample.block(invalid) }
    #expect(try Sample.block() == (try Sample.block()))
    let created = TableModel.creating(
      name: "New", headers: [("A", .text), ("B", .value)], rowCount: 3)
    let ids = [created.id.uuid] + created.columns.map(\.id.uuid) + created.rows.map(\.uuid)
    #expect(Set(ids).count == 6)
    let block = try Sample.block(created)
    #expect(TableSourceDocument(block).blocks.first?.table == created)
  }

  @Test func wireShapesAreStrict() throws {
    let block = try Sample.block()
    let replacements: [(String, String, TableSourceDiagnostic.Code)] = [
      ("\"o\":true}", "\"o\":false}", .malformed),
      ("\"l\":[0,0]", "\"l\":[0,2]", .malformed),
      ("\"l\":[0,0]", "\"l\":[false,false]", .malformed),
      ("\"l\":[0,0]", "\"l\":[0]", .malformed),
      (",\"l\":[0,0]", "", .malformed),
      ("\"t\":[1]}", "\"t\":[1],\"l\":[]}", .malformed),
      ("{\"i\":7,\"k\":\"current\",", "{\"k\":\"current\",", .malformed),
      ("{\"k\":\"cell\"", "{\"i\":0,\"k\":\"cell\"", .malformed),
      ("\"k\":\"cell\"", "\"k\":\"scalar\"", .malformed),
      ("\"p\":\"text\"", "\"p\":\"formula\"", .malformed),
      ("\"z\":\"sum\"", "\"z\":\"total\"", .malformed),
      ("\"t\":0,", "\"t\":99,", .malformed),
      ("\"t\":0,", "\"t\":1.0,", .malformed),
      ("\"t\":0,", "\"t\":\"0\",", .malformed),
      (",\"x\":[", ",\"y\":[", .malformed),
      ("\"r\":[5,6]", "\"r\":[5,5]", .duplicateIdentity),
      (Sample.table.string, Sample.table.string.uppercased(), .malformed),
      (Sample.table.string, "{\(Sample.table.string)}", .malformed),
      (Sample.qty.string, Sample.table.string, .duplicateIdentity),
      ("\"a\":[1,7]", "\"a\":[7,1]", .malformed),
      ("\"t\":[0,5,2]", "\"t\":[0,5]", .malformed),
      ("\"s\":\"2\"", "\"s\":2", .malformed),
    ]
    for (old, new, code) in replacements {
      #expect(block.contains(old), "\(old)")
      let text = block.replacingOccurrences(of: old, with: new)
      #expect(TableSample.codes(text) == [code], "\(old) -> \(new)")
      #expect(TableSourceDocument(text).source == text)
    }
    let deletedShape = block.replacingOccurrences(
      of: "\"l\":[0,0]}", with: "\"l\":[0,0],\"d\":false}")
    #expect(TableSample.codes(deletedShape) == [.malformed])
  }

  @Test func unknownKeysSurviveSpanPatchesAndFormulaEditsNeedTheirLedger() throws {
    let canonical = try Sample.block().replacingOccurrences(
      of: "{\"ids\":", with: "{\"future\" :  {\"n\":12345678901234567890.5},\n\"ids\":")
    let text = "before\r\n" + canonical.replacingOccurrences(of: "\n", with: "\r\n") + "after"
    let document = TableSourceDocument(text)
    let block = try #require(document.blocks.first)
    #expect(block.table == Sample.model)
    let json = try #require(block.json)
    let cell = try #require(json["x"]?.array?[3]["s"])
    let entry = try #require(json["b"]?.array?[1])
    let fingerprint = try #require(entry["f"])
    let span = try #require(entry["e"]?.array?.first?["a"])
    #expect(cell.string == "=B2 + 1")
    // A formula edit and its ledger change form one transaction.
    let edits = [
      try block.patch(replacing: cell, withJSON: TableJSON.quoted("=10 * B2")),
      try block.patch(replacing: fingerprint, withJSON: TableJSON.quoted("=10 * B2")),
      try block.patch(replacing: span, withJSON: "[6,8]"),
    ]
    let changed = try TableSourcePatch.applying(edits, to: text)
    let edited = try #require(TableSourceDocument(changed).blocks.first)
    #expect(edited.diagnostics.isEmpty)
    #expect(edited.table?.cells[3].source == "=10 * B2")
    #expect(changed.contains("\"future\" :  {\"n\":12345678901234567890.5},\r\n\"ids\":"))
    let firstEdit = edits.map(\.utf8Range.lowerBound).min()!
    #expect(Array(changed.utf8)[..<firstEdit].elementsEqual(Array(text.utf8)[..<firstEdit]))
    #expect(changed.hasSuffix("}\r\n@end-ganit-table\r\nafter"))

    // Without the ledger, the block is stale and has no projection at all.
    let stale = try TableSourcePatch.applying([edits[0]], to: text)
    let staleBlock = try #require(TableSourceDocument(stale).blocks.first)
    #expect(staleBlock.table == nil)
    #expect(staleBlock.diagnostics.map(\.code) == [.staleBinding])
    #expect(throws: TableCodecError.stalePatch) {
      try TableSourcePatch.applying(edits, to: changed)
    }
    #expect(throws: TableCodecError.overlappingPatches) {
      try TableSourcePatch.applying([edits[0], edits[0]], to: text)
    }
    #expect(throws: TableCodecError.invalidJSON) {
      try block.patch(replacing: cell, withJSON: "=10 * B2")
    }
  }

  @Test func appendPatchesAddARowWithoutReencoding() throws {
    let text = try Sample.block()
    let block = try #require(TableSourceDocument(text).blocks.first)
    let json = try #require(block.json)
    let row: RowID = Sample.id(0x23)
    let ids = try #require(json["ids"])
    let count = try #require(ids.array?.count)
    let patches = [
      try block.patch(appending: TableJSON.quoted(row.string), to: ids),
      try block.patch(appending: String(count), to: try #require(json["r"])),
    ]
    let changed = try TableSourcePatch.applying(patches, to: text)
    let table = try #require(TableSourceDocument(changed).blocks.first?.table)
    #expect(table.rows == [Sample.first, Sample.second, row])
    #expect(table.populatedCellCount == 6)
    #expect(throws: TableCodecError.stalePatch) {
      try block.patch(appending: "1", to: try #require(json["n"]))
    }
  }
}

@Suite struct TableDocumentTests {
  typealias Sample = TableSample

  static func table(_ base: Int, name: String, rows: Int = 1, rule: Bool = false) -> TableModel {
    TableModel(
      id: Sample.id(base), name: name,
      columns: [TableColumn(id: Sample.id(base + 1), header: "A", rule: rule ? "=1" : nil)],
      rows: (0..<rows).map { Sample.id(base + 0x100 + $0) },
      cells: rule
        ? []
        : (0..<rows).map {
          TableCell(row: Sample.id(base + 0x100 + $0), column: Sample.id(base + 1), source: "1")
        })
  }

  /// A one-cell table whose only formula reads `target` in another table.
  static func reader(_ base: Int, name: String, target: TableReferenceTarget, deleted: Bool = false)
    -> TableModel
  {
    var model = table(base, name: name)
    var binding = TableBinding(
      id: target.hasBindingID ? Sample.id(base + 2) : nil, operand: 1..<5, target: target,
      locks: Array(repeating: false, count: target.lockCount), isDeleted: deleted)
    let operand = deleted ? binding.brokenMarker : "Rates!B2"
    binding.operand = 1..<(1 + operand.utf8.count)
    let source = "=" + operand
    model.cells[0].source = source
    model.ledger = [
      TableLedgerEntry(
        owner: .cell(row: model.rows[0], column: model.columns[0].id), fingerprint: source,
        bindings: [binding])
    ]
    return model
  }

  @Test func namesAndIdentitiesAreUniqueSheetWide() throws {
    let names =
      try Sample.block(Self.table(0x1000, name: "Items")) + "---\n"
      + Sample.block(Self.table(0x2000, name: "ITEMS"))
    let document = TableSourceDocument(names)
    #expect(document.blocks.allSatisfy { $0.table == nil })
    #expect(document.diagnostics.map(\.code) == [.duplicateName, .duplicateName])
    let same = try Sample.block() + Sample.block()
    let duplicate = TableSourceDocument(same)
    #expect(duplicate.blocks.allSatisfy { $0.table == nil })
    #expect(duplicate.diagnostics.contains { $0.code == .duplicateIdentity })
  }

  @Test func crossTableTargetsAreCheckedAgainstValidTables() throws {
    let rates = Self.table(0x1000, name: "Rates", rows: 2)
    let target = TableReferenceTarget.cell(
      table: rates.id, row: rates.rows[1], column: rates.columns[0].id)
    let reader = try Sample.block(Self.reader(0x2000, name: "Items", target: target))
    #expect(TableSample.codes(try Sample.block(rates) + reader).isEmpty)
    #expect(TableSample.codes(reader) == [.orphanTarget])

    // Readers of a rejected table are orphaned too, without changing source.
    let twin = try Sample.block(Self.table(0x3000, name: "rates"))
    let cascade = TableSourceDocument(try Sample.block(rates) + twin + reader)
    #expect(cascade.diagnostics.map(\.code) == [.duplicateName, .duplicateName, .orphanTarget])
    #expect(cascade.blocks.allSatisfy { $0.table == nil })

    var shorter = rates
    shorter.rows.removeLast()
    shorter.cells.removeLast()
    #expect(TableSample.codes(try Sample.block(shorter) + reader) == [.orphanTarget])

    let range = TableReferenceTarget.rows(
      table: rates.id, .interval(first: rates.rows[1], last: rates.rows[0]))
    let backwards = try Sample.block(Self.reader(0x2000, name: "Items", target: range))
    #expect(TableSample.codes(try Sample.block(rates) + backwards) == [.invalidRecord])

    // A deleted external target stays broken whether or not its table exists,
    // but never while the target itself still exists.
    let goneRow = TableReferenceTarget.cell(
      table: rates.id, row: Sample.id(0x1999), column: rates.columns[0].id)
    let deleted = try Sample.block(
      Self.reader(0x2000, name: "Items", target: goneRow, deleted: true))
    #expect(TableSample.codes(deleted).isEmpty)
    #expect(TableSample.codes(try Sample.block(rates) + deleted).isEmpty)
    var revived = rates
    revived.rows.append(Sample.id(0x1999))
    #expect(TableSample.codes(try Sample.block(revived) + deleted) == [.staleBinding])
  }

  @Test func populatedCellCeilingIsPerSheetWithoutTruncation() throws {
    let half = try Sample.block(Self.table(0x10000, name: "A", rows: 2_000))
    let other = try Sample.block(Self.table(0x20000, name: "B", rows: 2_000))
    let atCeiling = TableSourceDocument(half + other)
    #expect(atCeiling.diagnostics.isEmpty)
    let one = try Sample.block(Self.table(0x30000, name: "C", rows: 1))
    let over = half + other + one
    // The two large blocks are reused; the ceiling is still a sheet-wide check.
    let document = TableSourceDocument(SheetSource(over), reusing: atCeiling.blocks)
    #expect(document.work == TableSourceDocument.Work(blocks: 3, decoded: 1, reused: 2))
    #expect(document.diagnostics.map(\.code) == [.cellLimit, .cellLimit, .cellLimit])
    #expect(document.blocks.allSatisfy { $0.table == nil })
    #expect(document.source == over)
    let rules = try Sample.block(Self.table(0x40000, name: "D", rows: 4_001, rule: true))
    #expect(TableSample.codes(rules) == [.cellLimit])
  }

  @Test func sourceLimitIsNotBypassed() throws {
    let line = "// padding line for the source limit\n"
    let text = String(repeating: line, count: 30_000) + (try Sample.block())
    #expect(text.utf8.count > 1_048_576)
    #expect(TableSample.codes(text) == [.sourceLimit])
    // Oversized source decodes no payload, even for a block it could reuse.
    let fitting = TableSourceDocument(try Sample.block())
    let oversized = TableSourceDocument(SheetSource(text), reusing: fitting.blocks)
    #expect(oversized.blocks.allSatisfy { $0.json == nil && $0.candidate == nil })
    #expect(oversized.work.reused == 0)
    let fits = String(repeating: line, count: 25_000) + (try Sample.block())
    #expect(TableSample.codes(fits).isEmpty)
  }
}

@Suite struct TableSheetCalculatorTests {
  @Test(arguments: [false, true])
  func blocksNeverCalculateDeclareAskOrJoinAggregates(markdown: Bool) throws {
    let valid = try TableSample.block()
    for block in [
      "@ganit-table 77\nx = 999\nask_assistant(hello)\n1 + 2\n@end-ganit-table\n",
      "@ganit-table 1\n{bad\nx = 999\nask_assistant(hello)\n@end-ganit-table\n",
      valid.replacingOccurrences(of: "\n@end", with: "\nx = 999\nask_assistant(hello)\n@end"),
    ] {
      let text = "x = 10 =>\n5 =>\n" + block + "x =>\n2 =>\ntotal =>"
      var calculator = SheetCalculator()
      let result = try calculator.evaluate(
        SheetSource(text), context: try sheetContext(isMarkdownMode: markdown))
      let blockLines = 2..<(result.lines.count - 3)
      #expect(
        result.lines[blockLines].allSatisfy {
          $0.result == nil && $0.assistantPrompts.isEmpty && $0.declaredVariableName == nil
        })
      #expect(result.definitions.variables["x"] == .number(.integer(IntegerValue(10))))
      #expect(result.tableDiagnostics.count == 1)
      // Markdown classifies bare words as prose, so totals are checked in
      // regular sheets: the block ends the aggregate block above it.
      guard !markdown else { continue }
      #expect(
        result.lines[result.lines.count - 3].result == .value(.number(.integer(IntegerValue(10)))))
      #expect(result.lines.last?.result == .value(.number(.integer(IntegerValue(12)))))
    }
  }

  @Test func aggregateAboveATableEndsAtItsOpener() throws {
    let text = "1\n2\ntotal\n" + (try TableSample.block()) + "total"
    let outcomes = try sheetOutcomes(text)
    #expect(outcomes[2] == "3")
    #expect(outcomes[3...5].allSatisfy { $0 == nil })
    #expect(outcomes.last == "0")
  }

  @Test func repairedBlockLinesEvaluateAndUseTheCache() throws {
    var sheet = SheetSource("@ganit-table 88\n1 + 2\n@end-ganit-table")
    var calculator = SheetCalculator()
    let initial = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(initial.lines[1].result == nil)
    #expect(initial.evaluatedLineIDs.isEmpty)
    #expect(initial.tableDiagnostics.map(\.code) == [.unsupportedVersion])
    let unchanged = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(unchanged.evaluatedLineIDs.isEmpty)
    sheet.replace(utf8Range: 0..<15, with: "// repaired")
    let repaired = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(repaired.lines[1].result == .value(.number(.integer(IntegerValue(3)))))
    #expect(repaired.evaluatedLineIDs.contains(sheet.lines[1].id))
    #expect(repaired.tableDiagnostics.isEmpty)
    // Opening a block again quarantines the same line without reusing its answer.
    sheet.replace(utf8Range: 0..<11, with: "@ganit-table 88")
    let reopened = try calculator.evaluate(sheet, context: try sheetContext())
    #expect(reopened.lines[1].result == nil)
  }
}

@Suite struct TableRegressionTests {
  typealias Sample = TableSample

  /// A table whose formula `=é + B2` contains a precomposed é.
  static func accented() throws -> (model: TableModel, text: String) {
    var model = Sample.model
    model.cells[3].source = "=\u{E9} + B2"
    model.ledger[1].fingerprint = "=\u{E9} + B2"
    model.ledger[1].bindings[0].operand = 6..<8
    return (model, "a = 1\n" + (try Sample.block(model)) + "b = 2")
  }

  @Test func canonicallyEquivalentBytesAreNeverReused() throws {
    let (_, text) = try Self.accented()
    var sheet = SheetSource(text)
    let before = TableSourceDocument(sheet)
    #expect(before.blocks.first?.table != nil)
    // Decompose é in the cell source only; its ledger fingerprint keeps é.
    let offset = try #require(text.utf8.firstRange(of: "\"s\":\"=\u{E9}".utf8)).upperBound
    let start = text.utf8.distance(from: text.utf8.startIndex, to: offset) - 2
    sheet.replace(utf8Range: start..<(start + 2), with: "e\u{301}")
    let after = TableSourceDocument(sheet, reusing: before.blocks)
    #expect(after.work == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    let block = try #require(after.blocks.first)
    #expect(block.table == nil && block.diagnostics.map(\.code) == [.staleBinding])
    #expect(block.rawSource.utf8.elementsEqual(Array(sheet.text.utf8)[block.utf8Range]))
    #expect(after.blocks == TableSourceDocument(sheet).blocks)
  }

  @Test func incrementalSegmentationMatchesFreshSegmentation() throws {
    let (_, text) = try Self.accented()
    var sheet = SheetSource(text)
    var document = TableSourceDocument(sheet)
    func step(_ edit: (inout SheetSource) throws -> Void) throws {
      try edit(&sheet)
      let incremental = TableSourceDocument(sheet, reusing: document.blocks)
      let fresh = TableSourceDocument(sheet)
      #expect(incremental.blocks == fresh.blocks)
      #expect(incremental.source.utf8.elementsEqual(sheet.text.utf8))
      document = incremental
    }
    try step { $0.replace(utf8Range: 0..<0, with: "x = 2\r\n") }
    try step { $0.replace(utf8Range: 0..<0, with: "\u{E9}\n") }
    try step { sheet in
      let block = try #require(TableSourceDocument(sheet).blocks.first)
      let name = try #require(block.json?["n"])
      let patch = try block.patch(replacing: name, withJSON: TableJSON.quoted("Cafe\u{301}"))
      sheet = SheetSource(try TableSourcePatch.applying([patch], to: sheet.text))
    }
    try step { sheet in
      let range = try #require(TableSourceDocument(sheet).blocks.first).utf8Range
      sheet.replace(utf8Range: range.upperBound..<range.upperBound, with: try Sample.block())
    }
    #expect(document.blocks.count == 2)
  }

  @Test func calculatorDoesNotReuseCanonicallyEquivalentTableLines() throws {
    let (_, text) = try Self.accented()
    var sheet = SheetSource(text)
    var calculator = SheetCalculator()
    _ = try calculator.evaluate(sheet, context: try sheetContext())
    let line = sheet.lines[2]
    let offset = try #require(line.text.utf8.firstRange(of: "\u{E9}".utf8)).lowerBound
    let start =
      line.range.lowerBound + line.text.utf8.distance(from: line.text.utf8.startIndex, to: offset)
    sheet.replace(utf8Range: start..<(start + 2), with: "e\u{301}")
    let result = try calculator.evaluate(sheet, context: try sheetContext())
    guard case .comment(let range) = result.lines[2].syntax else {
      Issue.record("A table line is quarantined as a comment")
      return
    }
    #expect(range.upperBound == sheet.lines[2].text.utf8.count)
    #expect(result.tableWork.decoded == 1)
  }

  /// Hang seed: duplicate-key detection must stay linear in key count. The
  /// check compares the parse's thread CPU time for n and 4n keys (best of
  /// three each) rather than wall time, so parallel tests and sanitizers do
  /// not skew it: linear work scales by about 4, quadratic by 16.
  @Test func manyKeysDecodeInLinearTime() throws {
    func object(_ count: Int) -> [UInt8] {
      Array(("{" + (0..<count).map { "\"k\($0)\":0" }.joined(separator: ",") + "}").utf8)
    }
    func best(_ bytes: [UInt8]) throws -> Double {
      var fastest = UInt64.max
      for _ in 0..<3 {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = try TableJSON.parse(bytes)
        fastest = min(fastest, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
      }
      return Double(max(fastest, 1))
    }
    let small = object(2_000)
    let large = object(8_000)
    _ = try TableJSON.parse(small)  // warm up
    let ratio = try best(large) / best(small)
    #expect(ratio < 8, "4x the keys took \(ratio)x as long")
    var duplicate = large
    duplicate.removeLast()
    duplicate += Array(",\"k7999\":1}".utf8)
    #expect(throws: TableCodecError.invalidJSON) { try TableJSON.parse(duplicate) }
  }

  @Test func patchesRejectSplitScalarsAndOutOfRangeSpans() throws {
    let source = "a\u{E9}b"
    for range in [2..<3, 1..<2, 3..<9, -1..<1] {
      #expect(throws: TableCodecError.stalePatch, "\(range)") {
        try TableSourcePatch.applying(
          [TableSourcePatch(utf8Range: range, expected: "", replacement: "x")], to: source)
      }
    }
    #expect(
      try TableSourcePatch.applying(
        [TableSourcePatch(utf8Range: 1..<3, expected: "\u{E9}", replacement: "e")], to: source)
        == "aeb")
    let block = try #require(TableSourceDocument(try Sample.block()).blocks.first)
    let outside = TableJSON(value: .null, utf8Range: 0..<(block.payloadUTF8Range.count + 1))
    #expect(throws: TableCodecError.stalePatch) {
      try block.patch(replacing: outside, withJSON: "1")
    }
  }

  /// A sheet over the byte limit skips payloads; those blocks must decode
  /// again, not be reused unparsed, when the sheet fits once more.
  @Test(arguments: [true, false])
  func blocksFromOversizedSheetsDecodeAgainWhenTheSheetFits(valid: Bool) throws {
    let block = valid ? try Sample.block() : "@ganit-table 1\n{bad\n@end-ganit-table\n"
    let small = "x = 1\n" + block + "y = x + 1\n"
    // The padding is itself a quarantined block of one long line, so neither
    // the payload decoder nor ordinary line parsing has to read it. A final
    // empty line adds the one byte over the limit.
    let filler = String(repeating: "p", count: 1_048_576 - small.utf8.count - 33)
    let limit = small + "@ganit-table 7\n" + filler + "\n@end-ganit-table\n"
    #expect(limit.utf8.count == 1_048_576)
    func padded(to length: Int) -> SheetSource {
      SheetSource(length > 1_048_576 ? limit + "\n" : limit)
    }
    let expected: [TableSourceDiagnostic.Code] = valid ? [] : [.malformed]
    let fresh = TableSourceDocument(small)
    #expect(fresh.diagnostics.map(\.code) == expected)
    #expect((fresh.blocks.first?.table != nil) == valid)

    let large = padded(to: 1_048_577)
    let over = TableSourceDocument(large, reusing: fresh.blocks)
    #expect(over.diagnostics.map(\.code) == [.sourceLimit, .unsupportedVersion, .sourceLimit])
    #expect(over.work == TableSourceDocument.Work(blocks: 2, decoded: 2, reused: 0))
    let back = TableSourceDocument(SheetSource(small), reusing: over.blocks)
    #expect(back.work == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    #expect(back.blocks == fresh.blocks)

    // At exactly the limit the skipped block decodes; the padding is reused.
    let atLimit = TableSourceDocument(padded(to: 1_048_576), reusing: over.blocks)
    #expect(atLimit.work == TableSourceDocument.Work(blocks: 2, decoded: 1, reused: 1))
    #expect(atLimit.diagnostics.map(\.code) == expected + [.unsupportedVersion])
    #expect(atLimit.blocks.first == fresh.blocks.first)

    var calculator = SheetCalculator()
    let context = try sheetContext()
    let first = try calculator.evaluate(SheetSource(small), context: context)
    #expect(first.tableDiagnostics.map(\.code) == expected)
    let oversized = try calculator.evaluate(large, context: context)
    #expect(
      oversized.tableDiagnostics.map(\.code) == [.sourceLimit, .unsupportedVersion, .sourceLimit])
    let shrunk = try calculator.evaluate(SheetSource(small), context: context)
    #expect(shrunk.tableDiagnostics.map(\.code) == expected)
    #expect(shrunk.tableWork == TableSourceDocument.Work(blocks: 1, decoded: 1, reused: 0))
    #expect(shrunk.lines.last?.result == first.lines.last?.result)
  }

  /// The construction behind the size stated in docs/storage/table-blocks.md.
  @Test func documentedCeilingSizeIsReproducible() throws {
    let table: TableID = Sample.id(1)
    let column: ColumnID = Sample.id(2)
    let rows: [RowID] = (0..<4_000).map { Sample.id(0x1000 + $0) }
    var cells: [TableCell] = []
    var ledger: [TableLedgerEntry] = []
    for (index, row) in rows.enumerated() {
      guard index + 1 < rows.count else {
        cells.append(TableCell(row: row, column: column, source: "=1"))
        break
      }
      let address = "A\(index + 3)"
      let formula = "=" + address + " + 1"
      cells.append(TableCell(row: row, column: column, source: formula))
      ledger.append(
        TableLedgerEntry(
          owner: .cell(row: row, column: column), fingerprint: formula,
          bindings: [
            TableBinding(
              operand: 1..<(1 + address.utf8.count),
              target: .cell(table: table, row: rows[index + 1], column: column),
              locks: [false, false])
          ]))
    }
    let model = TableModel(
      id: table, name: "Big", columns: [TableColumn(id: column, header: "A")], rows: rows,
      cells: cells, ledger: ledger)
    let block = try TableSourceDocument.canonicalBlock(for: model)
    #expect(block.utf8.count == 641_479)
    // The writer validated the model; reparsing would add nothing here.
    #expect(model.populatedCellCount == 4_000)
  }
}
