import Foundation
import Testing

@testable import GanitEngine

@Suite struct TableTransformTests {
  func document(_ formula: String = "=A2", rows: Int = 3) throws -> TableSourceDocument {
    var table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: rows)
    if rows > 0 {
      table.cells.append(
        TableCell(row: table.rows[rows - 1], column: table.columns[1].id, source: formula))
    }
    return TableSourceDocument(try TableSourceDocument.canonicalBlock(for: table))
  }
  func apply(_ edit: TableSourceEdit, _ document: TableSourceDocument) throws -> TableSourceDocument
  {
    let result = TableSourceDocument(try edit.applying(to: document.source))
    #expect(result.diagnostics.isEmpty)
    return result
  }
  @Test func insertDeleteAndReloadPreservesTarget() throws {
    let doc = try document("=$A$2")
    let id = doc.blocks[0].table!.id
    let inserted = try apply(doc.insertRows(table: id, at: 0), doc)
    #expect(inserted.blocks[0].table!.cells[0].source == "=$A$3")
    let deleted = try apply(inserted.deleteRows(table: id, in: 1..<2), inserted)
    let marker = deleted.blocks[0].table!.cells[0].source
    #expect(marker.hasPrefix("=#REF!{"))
    let restoredCoordinate = try apply(deleted.insertRows(table: id, at: 1), deleted)
    #expect(restoredCoordinate.blocks[0].table!.cells[0].source == marker)
  }
  @Test func rangeDeletionShrinksWithoutOutsideMembers() throws {
    let doc = try document("=sum(A2:A3)", rows: 4)
    let id = doc.blocks[0].table!.id
    let deleted = try apply(doc.deleteRows(table: id, in: 0..<1), doc)
    #expect(deleted.blocks[0].table!.cells[0].source == "=sum(A2:A2)")
    let broken = try apply(deleted.deleteRows(table: id, in: 0..<1), deleted)
    #expect(broken.blocks[0].table!.cells[0].source.hasPrefix("=sum(#REF!{range:"))
  }
  @Test func insertionInsideRangeAndOutsideAppend() throws {
    let doc = try document("=sum(A2:A3)", rows: 4)
    let id = doc.blocks[0].table!.id
    let inside = try apply(doc.insertRows(table: id, at: 1), doc)
    #expect(inside.blocks[0].table!.cells[0].source == "=sum(A2:A4)")
    let outside = try apply(inside.insertRows(table: id, at: 3), inside)
    #expect(outside.blocks[0].table!.cells[0].source == "=sum(A2:A4)")
  }
  @Test func copyLocksAndMove() throws {
    let doc = try document("=$A2+A$2+$A$2")
    let id = doc.blocks[0].table!.id
    let copied = try apply(
      doc.copyCell(table: id, from: .init(row: 2, column: 1), to: .init(row: 1, column: 1)), doc)
    #expect(
      copied.blocks[0].table!.cells.first { $0.row == copied.blocks[0].table!.rows[1] }!.source
        == "=$A1+A$2+$A$2")
    let moved = try apply(
      doc.move(
        table: id, rectangle: .init(rows: 2..<3, columns: 1..<2), to: .init(row: 1, column: 0)), doc
    )
    #expect(moved.blocks[0].table!.cells[0].source == "=$A2+A$2+$A$2")
  }
  @Test func copyOutOfBoundsPersistsBroken() throws {
    let doc = try document("=A2")
    let id = doc.blocks[0].table!.id
    let copied = try apply(
      doc.copyCell(table: id, from: .init(row: 2, column: 1), to: .init(row: 0, column: 1)), doc)
    #expect(
      copied.blocks[0].table!.cells.first { $0.row == copied.blocks[0].table!.rows[0] }!.source
        .hasPrefix("=#REF!{"))
  }
  @Test func renameRewritesProseNotComments() throws {
    let base = try document("=Items[Qty]")
    let doc = TableSourceDocument(
      base.source + "x = sum(Items[Qty]) // Items[Qty]\n// Items[Qty]\n# Items[Qty]\n")
    let id = doc.blocks[0].table!.id
    let renamed = try apply(doc.renameTable(id, to: "Travel costs"), doc)
    #expect(renamed.source.contains("x = sum(`Travel costs`[Qty]) // Items[Qty]"))
    #expect(renamed.source.contains("// Items[Qty]\n# Items[Qty]"))
    let column = renamed.blocks[0].table!.columns[0].id
    let header = try apply(renamed.renameColumn(table: id, column: column, to: "A]B\\C"), renamed)
    #expect(header.source.contains("Travel costs`[A\\\\]B\\\\\\\\C]"))
  }
  @Test func relativeRuleAndBlankOverride() throws {
    let base = try document()
    let id = base.blocks[0].table!.id
    let column = base.blocks[0].table!.columns[1].id
    let rule = try apply(base.setColumnRule(table: id, column: column, source: "=A2"), base)
    let inserted = try apply(rule.insertRows(table: id, at: 0), rule)
    #expect(inserted.blocks[0].table!.columns[1].rule == "=A2")
    let blank = try apply(
      inserted.setCell(table: id, at: .init(row: 0, column: 1), source: ""), inserted)
    #expect(blank.blocks[0].table!.cells.contains { $0.isOverride && $0.source.isEmpty })
    let cleared = try apply(
      blank.setCell(table: id, at: .init(row: 0, column: 1), source: nil), blank)
    #expect(
      !cleared.blocks[0].table!.cells.contains {
        $0.row == cleared.blocks[0].table!.rows[0] && $0.column == column
      })
    let empty = try apply(cleared.deleteRows(table: id, in: 0..<4), cleared)
    #expect(empty.blocks[0].table!.columns[1].rule == "=A2")
    let added = try apply(empty.insertRows(table: id, at: 0), empty)
    #expect(added.blocks[0].table!.ledger.contains { $0.owner == .rule(column: column) })
  }
  @Test func duplicationMintsInternalIdentities() throws {
    let doc = try document("=A2")
    let original = doc.blocks[0].table!
    let duplicated = try apply(
      doc.duplicateTable(original.id, named: "Copy", atUTF8: doc.source.utf8.count), doc)
    let copy = duplicated.blocks[1].table!
    #expect(copy.id != original.id)
    #expect(Set(copy.rows).isDisjoint(with: original.rows))
    #expect(copy.ledger[0].bindings[0].target.table == copy.id)
    let sheet = try apply(doc.duplicateSheet(), doc)
    #expect(sheet.blocks[0].table!.id != original.id)
    #expect(sheet.blocks[0].table!.cells[0].source == "=A2")
  }
  @Test func losslessUnknownFieldsAndUnsortedRecords() throws {
    var model = try document().blocks[0].table!
    model.cells.append(TableCell(row: model.rows[0], column: model.columns[0].id, source: "17"))
    let canonical = try TableSourceDocument.canonicalBlock(for: model)
    let parsed = TableSourceDocument(canonical)
    let block = parsed.blocks[0]
    let cells = block.json!["x"]!.array!
    func raw(_ node: TableJSON) -> String {
      String(
        decoding: canonical.utf8.dropFirst(
          block.payloadUTF8Range.lowerBound + node.utf8Range.lowerBound
        ).prefix(node.utf8Range.count), as: UTF8.self)
    }
    let swapped =
      "["
      + cells.reversed().enumerated().map { index, node in
        String(raw(node).dropLast()) + ",\"future\": { \"value\" : \(index).00 }}"
      }.joined(separator: ", ") + "]"
    let patch = try block.patch(replacing: block.json!["x"]!, withJSON: swapped)
    let doc = TableSourceDocument(try TableSourcePatch.applying([patch], to: canonical))
    let edited = try apply(doc.renameTable(model.id, to: "Renamed"), doc)
    #expect(edited.source.contains(swapped))
    let changed = try apply(
      doc.setCell(table: model.id, at: .init(row: 0, column: 0), source: "19"), doc)
    #expect(changed.source.contains("\"future\": { \"value\" : 1.00 }"))
    #expect(changed.blocks[0].table!.cells.first { $0.row == model.rows[0] }!.source == "19")
  }
  @Test func freshUnresolvedFormulaAndInvalidOperations() throws {
    let doc = try document()
    let id = doc.blocks[0].table!.id
    let edited = try apply(
      doc.setCell(table: id, at: .init(row: 0, column: 0), source: "=Missing[Qty]"), doc)
    #expect(edited.blocks[0].table!.cells.contains { $0.source == "=Missing[Qty]" })
    #expect(throws: TableTransformError.invalidPosition) { try doc.insertRows(table: id, at: -1) }
    #expect(throws: TableTransformError.invalidPosition) {
      try doc.createTable(name: "Bad", headers: [("A", .value)], rowCount: -1, atUTF8: 0)
    }
  }
  @Test func mixedVirtualRulePreservesLockedBrokenIdentity() throws {
    let base = try document(rows: 1)
    let id = base.blocks[0].table!.id
    let column = base.blocks[0].table!.columns[1].id
    let rule = try apply(base.setColumnRule(table: id, column: column, source: "=A2+$B$2"), base)
    let empty = try apply(rule.deleteRows(table: id, in: 0..<1), rule)
    let emptyRule = empty.blocks[0].table!.columns[1].rule!
    #expect(emptyRule.hasPrefix("=A2+#REF!{"))
    #expect(empty.blocks[0].table!.ledger[0].bindings.count == 1)
    let appended = try apply(empty.insertRows(table: id, at: 0), empty)
    #expect(appended.blocks[0].table!.columns[1].rule == emptyRule)
    #expect(appended.blocks[0].table!.ledger[0].bindings.count == 2)
    #expect(appended.blocks[0].table!.ledger[0].bindings[1].isDeleted)
  }
  @Test func qualifiedCopyTranslatesAgainstEarlierTarget() throws {
    let earlier = TableModel.creating(
      name: "Rates", headers: [("A", .value), ("B", .value)], rowCount: 4)
    var later = TableModel.creating(
      name: "Items", headers: [("A", .value), ("B", .value)], rowCount: 3)
    later.cells = [TableCell(row: later.rows[0], column: later.columns[0].id, source: "=Rates!A2")]
    let doc = TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: earlier)
        + TableSourceDocument.canonicalBlock(for: later))
    let copy = try apply(
      doc.copyCell(table: later.id, from: .init(row: 0, column: 0), to: .init(row: 1, column: 1)),
      doc)
    #expect(copy.blocks[1].table!.cells.first { $0.row == later.rows[1] }!.source == "=Rates!B3")
  }
  @Test func rowAndColumnRulesRebaseAndStructuralColumnReferencesFollow() throws {
    let doc = try document("=sum(A2:A3)", rows: 4)
    let id = doc.blocks[0].table!.id
    let inserted = try apply(doc.insertColumn(table: id, at: 0, header: "New"), doc)
    #expect(inserted.blocks[0].table!.cells[0].source == "=sum(B2:B3)")
    let col = inserted.blocks[0].table!.columns[2].id
    let rule = try apply(
      inserted.setColumnRule(table: id, column: col, source: "=sum(B2:B3)"), inserted)
    let deleted = try apply(rule.deleteRows(table: id, in: 0..<1), rule)
    #expect(deleted.blocks[0].table!.columns[2].rule == "=sum(B2:B3)")
  }

  @Test func duplicateBeforeExternalTargetStaysBrokenAfterCoordinateReuse() throws {
    let earlier = TableModel.creating(name: "Rates", headers: [("Rate", .value)], rowCount: 1)
    var later = TableModel.creating(name: "Items", headers: [("Price", .value)], rowCount: 1)
    later.cells = [TableCell(row: later.rows[0], column: later.columns[0].id, source: "=Rates!A2")]
    let doc = TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: earlier)
        + TableSourceDocument.canonicalBlock(for: later))
    let duplicated = try apply(doc.duplicateTable(later.id, named: "Early copy", atUTF8: 0), doc)
    let copied = duplicated.blocks[0].table!
    let marker = copied.cells[0].source
    #expect(marker.hasPrefix("=#REF!{"))
    let appended = try apply(duplicated.insertRows(table: earlier.id, at: 0), duplicated)
    #expect(appended.blocks[0].table!.cells[0].source == marker)
    #expect(appended.blocks[0].table!.ledger[0].bindings[0].isDeleted)
    #expect(TableSourceDocument(appended.source).blocks[0].table!.id == copied.id)
  }
  @Test func malformedNeighborBytesAndUnchangedOperandSpellingSurvive() throws {
    let base = try document("=a2")
    let invalid = "@ganit-table 99\r\n{ \"future\": 1 }\r\n@end-ganit-table\r\n"
    let doc = TableSourceDocument(invalid + base.source)
    let id = doc.blocks[1].table!.id
    let edited = try doc.renameTable(id, to: "New name").applying(to: doc.source)
    #expect(edited.hasPrefix(invalid))
    #expect(TableSourceDocument(edited).blocks[1].table!.cells[0].source == "=a2")
  }

  @Test func duplicationRejectsMidlineAndSplitScalarInsertion() throws {
    let base = try document()
    let doc = TableSourceDocument("α prose\r\n" + base.source)
    let id = doc.blocks[0].table!.id
    for offset in [1, 2, 4, "α prose\r".utf8.count] {
      #expect(throws: TableTransformError.invalidPosition) {
        try doc.duplicateTable(id, named: "Copy", atUTF8: offset)
      }
    }
    let edit = try doc.duplicateTable(id, named: "Copy", atUTF8: "α prose\r\n".utf8.count)
    let result = try apply(edit, doc)
    #expect(result.blocks.contains { $0.table?.id == edit.createdTable })
  }
  @Test func copyingAbsentBlankToRuleColumnCreatesBlankOverride() throws {
    let base = try document(rows: 1)
    let id = base.blocks[0].table!.id
    let column = base.blocks[0].table!.columns[1].id
    let ruled = try apply(base.setColumnRule(table: id, column: column, source: "=A2"), base)
    let copied = try apply(
      ruled.copyCell(table: id, from: .init(row: 0, column: 0), to: .init(row: 0, column: 1)), ruled
    )
    let cell = copied.blocks[0].table!.cells.first { $0.column == column }!
    #expect(cell.source.isEmpty && cell.isOverride)
  }
  @Test func movingBlankOverrideToPlainColumnStoresAbsence() throws {
    let base = try document(rows: 1)
    let id = base.blocks[0].table!.id
    let column = base.blocks[0].table!.columns[1].id
    let ruled = try apply(base.setColumnRule(table: id, column: column, source: "=A2"), base)
    let blank = try apply(ruled.setCell(table: id, at: .init(row: 0, column: 1), source: ""), ruled)
    let moved = try apply(
      blank.move(
        table: id, rectangle: .init(rows: 0..<1, columns: 1..<2), to: .init(row: 0, column: 0)),
      blank)
    #expect(moved.blocks[0].table!.cells.isEmpty)
  }

  // MARK: - Review regressions

  func rule(_ doc: TableSourceDocument) -> (String?, TableBinding?) {
    let table = doc.blocks[0].table!
    let entry = table.ledger.first { $0.owner == .rule(column: table.columns[1].id) }
    return (table.columns[1].rule, entry?.bindings.first)
  }
  func row(_ binding: TableBinding?) -> RowID? {
    if case .cell(_, let row, _) = binding?.target { return row }
    return nil
  }
  func ruled(_ formula: String, rows: Int = 5) throws -> TableSourceDocument {
    let base = try document("7", rows: rows)
    let table = base.blocks[0].table!
    return try apply(
      base.setColumnRule(table: table.id, column: table.columns[1].id, source: formula), base)
  }
  func rawNode(_ doc: TableSourceDocument, _ node: TableJSON, block: Int = 0) -> String {
    let start = doc.blocks[block].payloadUTF8Range.lowerBound + node.utf8Range.lowerBound
    return String(
      decoding: doc.source.utf8.dropFirst(start).prefix(node.utf8Range.count), as: UTF8.self)
  }

  @Test func firstRowDeletionKeepsRuleOperandsToSurvivingRows() throws {
    // A relative offset that no longer fits keeps its surviving target rather
    // than becoming a persistent #REF!; a range end clamps to the last row.
    for (formula, expected) in [
      ("=A6", "=A5"), ("=sum(A2:A6)", "=sum(A2:A5)"), ("=sum(Items!2:6)", "=sum(Items!2:5)"),
    ] {
      let doc = try ruled(formula)
      let table = doc.blocks[0].table!
      let deleted = try apply(doc.deleteRows(table: table.id, in: 0..<1), doc)
      let (text, binding) = rule(deleted)
      #expect(text == expected)
      #expect(binding?.isDeleted == false)
      switch binding?.target {
      case .cell(_, let row, _): #expect(row == table.rows[4])
      case .rectangle(_, .interval(let first, let last), _),
        .rows(_, .interval(let first, let last)):
        #expect([first, last] == [table.rows[1], table.rows[4]])
      default: Issue.record("unexpected target for \(formula)")
      }
    }
  }
  @Test func ruleOffsetsFollowTheAnchorOnlyOnFirstRowEdits() throws {
    // First-row edits preserve a fitting relative offset (the template moves
    // with its anchor); middle edits leave operands bound to their targets.
    let scalar = try ruled("=A3")
    let id = scalar.blocks[0].table!.id
    let first = try apply(scalar.deleteRows(table: id, in: 0..<1), scalar)
    #expect(rule(first).0 == "=A3")
    #expect(row(rule(first).1) == first.blocks[0].table!.rows[1])
    let inserted = try apply(scalar.insertRows(table: id, at: 0), scalar)
    #expect(rule(inserted).0 == "=A3")
    #expect(row(rule(inserted).1) == inserted.blocks[0].table!.rows[1])
    for formula in ["=A6", "=sum(A2:A6)"] {
      let doc = try ruled(formula)
      let id = doc.blocks[0].table!.id
      let middle = try apply(doc.deleteRows(table: id, in: 2..<3), doc)
      #expect(rule(middle).0 == formula.replacingOccurrences(of: "6", with: "5"))
      #expect(rule(middle).1?.isDeleted == false)
      let grown = try apply(doc.insertRows(table: id, at: 0), doc)
      #expect(rule(grown).0 == formula)
    }
  }
  @Test func duplicateSheetRejectsAnInvalidResult() throws {
    // The copy replaces every block, so it cannot double populated cells; it
    // can grow the source, because duplication binds formulas whose ledger
    // under-covers them. A sheet at the byte limit must throw, not silently
    // lose every projection.
    let block = try document().source
    let line = "// " + String(repeating: "x", count: 996) + "\n"
    let room = SyntaxLimits.default.maximumSourceUTF8Length - block.utf8.count - 8
    let filler =
      String(repeating: line, count: room / line.utf8.count)
      + String(repeating: "\n", count: room % line.utf8.count)
    let doc = TableSourceDocument(block + filler)
    #expect(doc.blocks[0].table != nil)
    #expect(throws: TableBlockError.self) { try doc.duplicateSheet() }
    do {
      _ = try doc.duplicateSheet()
    } catch let error as TableBlockError {
      #expect(error.code == .sourceLimit)
    }
  }
  @Test func moveKeepsUnknownMembersOfRelocatedRecords() throws {
    let base = try document("7")
    let id = base.blocks[0].table!.id
    let bound = try apply(
      base.setCell(table: id, at: .init(row: 0, column: 1), source: "=A2"), base)
    let block = bound.blocks[0]
    let record = block.json!["x"]!.array!.first { $0["s"]?.string == "=A2" }!
    let entry = block.json!["b"]!.array![0]
    let patches = try [(record, "\"custom\": [1, 2]"), (entry, "\"custom2\":true")].map {
      node, member in
      try block.patch(
        replacing: node, withJSON: String(rawNode(bound, node).dropLast()) + "," + member + "}")
    }
    let doc = TableSourceDocument(try TableSourcePatch.applying(patches, to: bound.source))
    let moved = try apply(
      doc.move(
        table: id, rectangle: .init(rows: 0..<1, columns: 1..<2), to: .init(row: 1, column: 1)),
      doc)
    #expect(moved.source.components(separatedBy: "\"custom\": [1, 2]").count == 2)
    #expect(moved.source.components(separatedBy: "\"custom2\":true").count == 2)
    let table = moved.blocks[0].table!
    #expect(table.cells.contains { $0.row == table.rows[1] && $0.source == "=A2" })
    #expect(
      table.ledger.contains { $0.owner == .cell(row: table.rows[1], column: table.columns[1].id) })
    #expect(!table.cells.contains { $0.row == table.rows[0] && $0.column == table.columns[1].id })
  }
  @Test func appendAndRemovalKeepSeparatorsAndSourceOrder() throws {
    var model = try document("7").blocks[0].table!
    model.cells.append(TableCell(row: model.rows[0], column: model.columns[0].id, source: "1"))
    let canonical = TableSourceDocument(try TableSourceDocument.canonicalBlock(for: model))
    let block = canonical.blocks[0]
    let cells = block.json!["x"]!.array!.map { rawNode(canonical, $0) }
    let ids = block.json!["ids"]!.array!.map { rawNode(canonical, $0) }
    // Unsorted records and hand-spaced separators are valid spellings.
    let spacedCells = "[ " + cells.reversed().joined(separator: " ,  ") + " ]"
    let spacedIDs = "[" + ids.joined(separator: ", ") + "]"
    let doc = TableSourceDocument(
      try TableSourcePatch.applying(
        [
          block.patch(replacing: block.json!["x"]!, withJSON: spacedCells),
          block.patch(replacing: block.json!["ids"]!, withJSON: spacedIDs),
        ], to: canonical.source))
    let id = model.id
    let appended = try apply(doc.setCell(table: id, at: .init(row: 2, column: 0), source: "5"), doc)
    #expect(appended.source.contains(String(spacedCells.dropLast(2)) + " ,  {"))
    #expect(appended.source.contains(spacedIDs))
    let grown = try apply(doc.insertRows(table: id, at: 3), doc)
    #expect(grown.source.contains(String(spacedIDs.dropLast()) + ", \""))
    let removed = try apply(doc.setCell(table: id, at: .init(row: 0, column: 0), source: nil), doc)
    #expect(removed.source.contains("\"x\":[ " + cells[1] + " ]"))
    let both = try apply(
      appended.setCell(table: id, at: .init(row: 0, column: 0), source: nil), appended)
    #expect(both.source.contains("\"x\":[ " + cells[1] + " ,  {"))
  }
  @Test func addedColumnKeyTakesItsCanonicalPosition() throws {
    var model = try document("7").blocks[0].table!
    model.columns[1].total = .sum
    let doc = TableSourceDocument(try TableSourceDocument.canonicalBlock(for: model))
    let edited = try apply(
      doc.setColumnRule(table: model.id, column: model.columns[1].id, source: "=A2"), doc)
    #expect(edited.source.contains("\"p\":\"value\",\"f\":\"=A2\",\"z\":\"sum\"}"))
  }
  @Test func untouchedTableWithUnderCoveredLedgerStaysByteIdentical() throws {
    // A projecting block may carry formulas without ledger entries. Editing
    // another table must not mint bindings or ledger entries into it.
    let items = try document("7").blocks[0].table!
    var other = TableModel.creating(name: "Other", headers: [("A", .value)], rowCount: 2)
    other.cells = [
      TableCell(row: other.rows[0], column: other.columns[0].id, source: "=A3"),
      TableCell(row: other.rows[1], column: other.columns[0].id, source: "=Items!A2"),
    ]
    let doc = TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: items)
        + TableSourceDocument.canonicalBlock(for: other))
    #expect(doc.blocks[1].table!.ledger.isEmpty)
    for edit in [
      try doc.setCell(table: items.id, at: .init(row: 0, column: 0), source: "3"),
      try doc.insertRows(table: items.id, at: 3),
    ] {
      let edited = try apply(edit, doc)
      #expect(edited.blocks[1].rawSource == doc.blocks[1].rawSource)
    }
  }
  @Test func moveAppliesThePasteInputPolicy() throws {
    var model = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Note", .text)], rowCount: 2)
    model.cells = [
      TableCell(row: model.rows[0], column: model.columns[0].id, source: "4"),
      TableCell(row: model.rows[1], column: model.columns[0].id, source: "=A2"),
    ]
    let doc = TableSourceDocument(try TableSourceDocument.canonicalBlock(for: model))
    #expect(throws: TableTransformError.inputPolicyMismatch) {
      try doc.move(
        table: model.id, rectangle: .init(rows: 0..<1, columns: 0..<1), to: .init(row: 0, column: 1)
      )
    }
    let formula = try apply(
      doc.move(
        table: model.id, rectangle: .init(rows: 1..<2, columns: 0..<1), to: .init(row: 1, column: 1)
      ),
      doc)
    #expect(formula.blocks[0].table!.cells.contains { $0.column == model.columns[1].id })
  }
}
