import Foundation
import Testing

@testable import GanitEngine

/// Independent contract coverage for the half of M3 task 1 that the first
/// contract suite does not reach: value/rule edits, overrides, rule rebasing,
/// rename spelling, prose operands, duplication and byte fidelity.
///
/// Every expectation cites the normative sentence it comes from; none of them
/// is derived from what the implementation happens to emit.
@Suite struct TableTransformContract2Tests {
  // MARK: - Spelling helpers (ADR 0016 "Reference grammar")

  private func col(_ column: Int) -> String {
    var number = column + 1
    var result = ""
    while number > 0 {
      number -= 1
      result = String(UnicodeScalar(UInt8(65 + number % 26))) + result
      number /= 26
    }
    return result
  }
  private func a1(_ row: Int, _ column: Int) -> String { col(column) + String(row + 2) }

  struct NoProjection: Error {}

  // MARK: - Fixtures

  private func makeTable(
    _ name: String, _ headers: [String], rows: Int,
    cells: [(row: Int, column: Int, source: String, override: Bool)] = []
  ) -> TableModel {
    var table = TableModel.creating(
      name: name, headers: headers.map { ($0, TableInputPolicy.value) }, rowCount: rows)
    for cell in cells {
      table.cells.append(
        TableCell(
          row: table.rows[cell.row], column: table.columns[cell.column].id, source: cell.source,
          isOverride: cell.override))
    }
    return table
  }

  private func blockText(_ table: TableModel, _ ending: LineTerminator = .lineFeed) throws
    -> String
  {
    try TableSourceDocument.canonicalBlock(for: table, lineEnding: ending)
  }

  private func sheet(
    _ tables: [TableModel], prose: [String] = [], ending: LineTerminator = .lineFeed
  ) throws -> TableSourceDocument {
    var text = ""
    for table in tables { text += try blockText(table, ending) }
    for line in prose { text += line + ending.rawValue }
    return TableSourceDocument(text)
  }

  /// Applies every returned patch as one transaction and re-parses, so each
  /// assertion reads reloaded state. A successful structural edit must not
  /// leave a block without its projection ("otherwise the block is stale and
  /// has no projection", docs/storage/table-blocks.md).
  @discardableResult
  private func commit(
    _ edit: TableSourceEdit, to before: TableSourceDocument, _ note: String = ""
  ) throws -> TableSourceDocument {
    let after = TableSourceDocument(try edit.applying(to: before.source))
    let known = Set(before.diagnostics.map(\.code))
    let extra = after.diagnostics.filter { !known.contains($0.code) }
    let detail = extra.map { "\($0.code) \($0.detail)" }.joined(separator: "; ")
    #expect(extra.isEmpty, "unexpected diagnostics after \(note): \(detail)")
    return after
  }

  private func view(_ doc: TableSourceDocument, name: String) throws -> TableModel {
    guard let found = doc.blocks.compactMap(\.table).first(where: { $0.name == name }) else {
      Issue.record("no projection for a table named \(name)")
      throw NoProjection()
    }
    return found
  }
  private func view(_ doc: TableSourceDocument, id: TableID) throws -> TableModel {
    guard let found = doc.blocks.compactMap(\.table).first(where: { $0.id == id }) else {
      Issue.record("no projection for table \(id.string)")
      throw NoProjection()
    }
    return found
  }

  private func record(
    _ table: TableModel, _ position: TableCellPosition
  ) -> TableCell? {
    table.cells.first {
      $0.row == table.rows[position.row] && $0.column == table.columns[position.column].id
    }
  }
  /// The cell's own source, or `inherit` when it has no record and reads a rule.
  private func text(
    _ table: TableModel, _ position: TableCellPosition, inherit: String = ""
  ) -> String {
    record(table, position)?.source ?? inherit
  }
  private func ledger(
    _ table: TableModel, _ position: TableCellPosition
  ) -> [TableLedgerEntry] {
    let owner = TableFormulaOwner.cell(
      row: table.rows[position.row], column: table.columns[position.column].id)
    return table.ledger.filter { $0.owner == owner }
  }
  private func bound(_ table: TableModel, _ position: TableCellPosition) -> [TableBinding] {
    ledger(table, position).first?.bindings ?? []
  }
  private func ruleLedger(_ table: TableModel, _ column: Int) -> TableLedgerEntry? {
    table.ledger.first { $0.owner == .rule(column: table.columns[column].id) }
  }
  private func ruleBound(_ table: TableModel, _ column: Int) -> [TableBinding] {
    ruleLedger(table, column)?.bindings ?? []
  }
  private func rectRows(_ binding: TableBinding) -> [RowID]? {
    guard case .rectangle(_, let rows, _) = binding.target,
      case .interval(let first, let last) = rows
    else { return nil }
    return [first, last]
  }
  /// The operand text a binding's span names.
  private func operand(_ fingerprint: String, _ binding: TableBinding) -> String {
    let bytes = Array(fingerprint.utf8)
    return String(
      decoding: bytes[binding.operand.lowerBound..<binding.operand.upperBound], as: UTF8.self)
  }

  /// The top-level items of the JSON array spelled for `key` in a payload.
  private func arrayList(_ payload: String, _ key: String) -> [String]? {
    guard let found = payload.range(of: "\"\(key)\":[") else { return nil }
    let chars = Array(payload)
    var index = payload.distance(from: payload.startIndex, to: found.upperBound)
    var depth = 0
    var items: [String] = []
    var current = ""
    var inString = false
    var escaped = false
    while index < chars.count {
      let character = chars[index]
      index += 1
      if inString {
        current.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
        current.append(character)
      case "{", "[":
        depth += 1
        current.append(character)
      case "}", "]":
        if depth == 0 {
          if !current.isEmpty { items.append(current) }
          return items
        }
        depth -= 1
        current.append(character)
      case ",":
        if depth == 0 {
          items.append(current)
          current = ""
        } else {
          current.append(character)
        }
      default: current.append(character)
      }
    }
    return nil
  }

  // MARK: - 1. setCell: literals, formulas, blank override, clearing

  @Test func aLiteralEditKeepsEveryTableRowAndColumnIdentity() throws {
    // Plan "Structural edit semantics": "Edit a value/formula | keep
    // table/row/column identities; recalculate dependents."
    let doc = try sheet([makeTable("Items", ["A", "B"], rows: 3)])
    let before = try view(doc, name: "Items")
    let edited = try commit(
      doc.setCell(table: before.id, at: .init(row: 1, column: 1), source: "7"), to: doc,
      "literal edit")
    let after = try view(edited, name: "Items")
    #expect(after.id == before.id)
    #expect(after.rows == before.rows)
    #expect(after.columns.map(\.id) == before.columns.map(\.id))
    #expect(text(after, .init(row: 1, column: 1)) == "7")
    #expect(after.cells.count == 1)
  }

  @Test func aFormulaEditReplacesItsOwnersLedgerEntryInTheSameEdit() throws {
    // docs/storage/table-blocks.md: "A formula edit must replace its owner's
    // ledger entry in the same transaction; otherwise the block is stale and
    // has no projection."
    let doc = try sheet([makeTable("Items", ["A", "B"], rows: 3)])
    let id = try view(doc, name: "Items").id
    let edit = try doc.setCell(table: id, at: .init(row: 1, column: 1), source: "=A2")
    #expect(!edit.patches.isEmpty)
    let edited = try commit(edit, to: doc, "formula edit")
    let table = try view(edited, name: "Items")
    let entries = ledger(table, .init(row: 1, column: 1))
    #expect(entries.count == 1, "a formula owner has exactly one ledger entry")
    #expect(entries[0].fingerprint == "=A2")
    #expect(entries[0].bindings.count == 1)
    #expect(operand(entries[0].fingerprint, entries[0].bindings[0]) == "A2")
    #expect(!entries[0].bindings[0].isDeleted)
    #expect(entries[0].bindings[0].target.rowID == table.rows[0])
    #expect(entries[0].bindings[0].target.columnID == table.columns[0].id)
  }

  @Test func aManuallyEditedFormulaNeverKeepsAStaleOccurrenceOrdinal() throws {
    // Plan "Identity in source and after reload": "Reuse persisted bindings
    // only when their formula-source fingerprint matches. A manually edited
    // formula invalidates its old bindings; do not attach a stale occurrence
    // ordinal to different text. New IDs are minted only for deliberate
    // creation, duplication or an explicit repair, not on every parse."
    let doc = try sheet([makeTable("Items", ["A", "B"], rows: 3)])
    let id = try view(doc, name: "Items").id
    let typed = try commit(
      doc.setCell(table: id, at: .init(row: 0, column: 1), source: "=sum(A2:A3)"), to: doc,
      "first formula")
    let persisted = bound(try view(typed, name: "Items"), .init(row: 0, column: 1))
    #expect(persisted.count == 1)
    #expect(persisted[0].id != nil, "a range binding carries a durable binding identity")
    let stale = persisted[0].id
    let edited = try commit(
      typed.setCell(table: id, at: .init(row: 0, column: 1), source: "=sum(A2:A3)+sum(A2:A3)"),
      to: typed, "manual formula edit")
    let table = try view(edited, name: "Items")
    let entries = ledger(table, .init(row: 0, column: 1))
    #expect(entries.count == 1)
    #expect(entries[0].fingerprint == "=sum(A2:A3)+sum(A2:A3)")
    let bindings = entries[0].bindings
    #expect(bindings.count == 2)
    // Neither occurrence reuses the invalidated binding identity, and every
    // operand span is re-derived from the edited text.
    #expect(bindings.allSatisfy { $0.id != nil && $0.id != stale })
    #expect(operand(entries[0].fingerprint, bindings[0]) == "A2:A3")
    #expect(operand(entries[0].fingerprint, bindings[1]) == "A2:A3")
    #expect(bindings[0].operand.upperBound <= bindings[1].operand.lowerBound)
    #expect(bindings.allSatisfy { !$0.isDeleted })
  }

  @Test func aBlankOverrideIsDistinctFromClearingAnOverride() throws {
    // ADR 0016: "Blank override is distinct from clearing override."
    var items = makeTable("Items", ["A", "B"], rows: 2)
    items.columns[1].rule = "=A2"
    let doc = try sheet([items])
    let id = try view(doc, name: "Items").id
    let blanked = try commit(
      doc.setCell(table: id, at: .init(row: 0, column: 1), source: ""), to: doc, "blank override")
    let withBlank = try view(blanked, name: "Items")
    let blank = record(withBlank, .init(row: 0, column: 1))
    #expect(blank?.source == "", "a blank override keeps an empty-source record")
    #expect(blank?.isOverride == true, "a blank override is visibly an override")
    // The other row is untouched and still inherits.
    #expect(record(withBlank, .init(row: 1, column: 1)) == nil)
    #expect(withBlank.columns[1].rule == "=A2")
    let cleared = try commit(
      blanked.setCell(table: id, at: .init(row: 0, column: 1), source: nil), to: blanked,
      "clearing an override")
    let inherited = try view(cleared, name: "Items")
    #expect(
      record(inherited, .init(row: 0, column: 1)) == nil,
      "clearing an override restores inheritance")
    #expect(inherited.columns[1].rule == "=A2")
  }

  @Test func aBlankInAPlainColumnLeavesNoRecord() throws {
    // docs/storage/table-blocks.md counts "cell records with non-empty source
    // plus rule-column cells without a record" as populated, so an
    // empty-source record in a ruleless column is not a representable cell.
    let doc = try sheet([makeTable("Items", ["A", "B"], rows: 2)])
    let id = try view(doc, name: "Items").id
    let blanked = try commit(
      doc.setCell(table: id, at: .init(row: 0, column: 1), source: ""), to: doc, "blank")
    #expect(try view(blanked, name: "Items").cells.isEmpty)
    let filled = try commit(
      blanked.setCell(table: id, at: .init(row: 0, column: 1), source: "5"), to: blanked)
    #expect(try view(filled, name: "Items").cells.count == 1)
    let cleared = try commit(
      filled.setCell(table: id, at: .init(row: 0, column: 1), source: nil), to: filled)
    #expect(try view(cleared, name: "Items").cells.isEmpty)
  }

  // MARK: - 2. setColumnRule

  @Test func addingARuleVisiblyMarksExistingRecordsAndLeavesInheritedCellsAlone() throws {
    // Plan: "Change column rule | update inherited cells; preserve and visibly
    // mark per-cell overrides."
    let doc = try sheet(
      [makeTable("Items", ["A", "B"], rows: 3, cells: [(0, 1, "7", false)])])
    let table = try view(doc, name: "Items")
    let ruled = try commit(
      doc.setColumnRule(table: table.id, column: table.columns[1].id, source: "=A2"), to: doc,
      "adding a rule")
    let after = try view(ruled, name: "Items")
    #expect(after.columns[1].rule == "=A2")
    let override = record(after, .init(row: 0, column: 1))
    #expect(override?.source == "7", "an existing record keeps its own source")
    #expect(override?.isOverride == true, "an existing record becomes a visible override")
    // Inherited cells carry no source at all, so they are unaffected in source.
    #expect(after.cells.count == 1)
    #expect(record(after, .init(row: 1, column: 1)) == nil)
    #expect(record(after, .init(row: 2, column: 1)) == nil)
  }

  @Test func removingARuleLeavesNoEmptyRecordAndKeepsRealOverrides() throws {
    let items = makeTable(
      "Items", ["A", "B"], rows: 3,
      cells: [(0, 1, "", true), (1, 1, "9", true)])
    var ruled = items
    ruled.columns[1].rule = "=A2"
    let doc = try sheet([ruled])
    let table = try view(doc, name: "Items")
    let unruled = try commit(
      doc.setColumnRule(table: table.id, column: table.columns[1].id, source: nil), to: doc,
      "removing a rule")
    let after = try view(unruled, name: "Items")
    #expect(after.columns[1].rule == nil)
    #expect(
      after.cells.filter { $0.column == after.columns[1].id && $0.source.isEmpty }.isEmpty,
      "a ruleless column must not keep an empty-source record")
    let kept = record(after, .init(row: 1, column: 1))
    #expect(kept?.source == "9")
    #expect(kept?.isOverride == false, "a record in a ruleless column is not an override")
    #expect(ruleLedger(after, 1) == nil)
  }

  // MARK: - 3. Rule rebase on first-row edits

  @Test func insertingTheFirstRowRebasesARelativeRuleOntoTheNewFirstRow() throws {
    // ADR 0016: "Relative column rules anchor to first data row; rebase
    // offsets and locked identities transactionally on first-row edits."
    var items = makeTable("Items", ["A", "B"], rows: 3)
    items.columns[1].rule = "=A2"
    let doc = try sheet([items])
    let id = try view(doc, name: "Items").id
    let grown = try commit(doc.insertRows(table: id, at: 0), to: doc, "first-row insert")
    let after = try view(grown, name: "Items")
    #expect(after.columns[1].rule == "=A2")
    let bindings = ruleBound(after, 1)
    #expect(bindings.count == 1)
    #expect(!bindings[0].isDeleted)
    #expect(bindings[0].target.rowID == after.rows[0], "the rule re-anchors to the new first row")
  }

  @Test func deletingTheFirstRowRebasesARelativeRuleOntoTheSurvivingFirstRow() throws {
    var items = makeTable("Items", ["A", "B"], rows: 3)
    items.columns[1].rule = "=A2"
    let doc = try sheet([items])
    let id = try view(doc, name: "Items").id
    let shrunk = try commit(doc.deleteRows(table: id, in: 0..<1), to: doc, "first-row delete")
    let after = try view(shrunk, name: "Items")
    #expect(after.columns[1].rule == "=A2")
    let bindings = ruleBound(after, 1)
    #expect(bindings.count == 1)
    #expect(!bindings[0].isDeleted)
    #expect(bindings[0].target.rowID == after.rows[0])
  }

  @Test func aRuleOnAnEmptyTableInstantiatesWhenTheFirstRowIsAppended() throws {
    // ADR 0016: "An empty table has a virtual row-2 anchor." A rule written
    // against the anchor is not a broken operand, and the first appended row
    // becomes its first data row.
    let doc = try sheet([makeTable("Items", ["A", "B"], rows: 0)])
    let id = try view(doc, name: "Items").id
    let ruled = try commit(
      doc.setColumnRule(
        table: id, column: try view(doc, name: "Items").columns[1].id, source: "=A2"),
      to: doc, "rule on an empty table")
    let empty = try view(ruled, name: "Items")
    #expect(empty.columns[1].rule == "=A2", "the virtual anchor is not a broken operand")
    let grown = try commit(ruled.insertRows(table: id, at: 0), to: ruled, "first append")
    let after = try view(grown, name: "Items")
    #expect(after.columns[1].rule == "=A2")
    let bindings = ruleBound(after, 1)
    #expect(bindings.count == 1, "the rule instantiates for the first data row")
    #expect(!bindings[0].isDeleted)
    #expect(bindings[0].target.rowID == after.rows[0])
  }

  @Test func aLockedRuleOperandHoldsItsTargetAcrossFirstRowEdits() throws {
    // ADR 0016: "locks hold targets" and "Insertions move their rendered
    // coordinates, including locked coordinates."
    var items = makeTable("Items", ["A", "B", "C"], rows: 3)
    items.columns[2].rule = "=$B$2"
    let doc = try sheet([items])
    let original = try view(doc, name: "Items")
    let anchored = original.rows[0]
    let grown = try commit(
      doc.insertRows(table: original.id, at: 0), to: doc, "first-row insert")
    let grownTable = try view(grown, name: "Items")
    let grownBindings = ruleBound(grownTable, 2)
    #expect(grownBindings.count == 1)
    #expect(grownBindings[0].target.rowID == anchored, "a locked operand holds its identity")
    #expect(grownTable.columns[2].rule == "=$B$3", "the locked coordinate still moves")
    let shrunk = try commit(
      doc.deleteRows(table: original.id, in: 1..<2), to: doc, "second-row delete")
    let shrunkTable = try view(shrunk, name: "Items")
    let shrunkBindings = ruleBound(shrunkTable, 2)
    #expect(shrunkBindings.count == 1)
    #expect(shrunkBindings[0].target.rowID == anchored)
    #expect(shrunkTable.columns[2].rule == "=$B$2")
  }

  // MARK: - 4. renameColumn

  @Test func renamingAColumnRewritesBoundOperandsAndEscapesHeaderPunctuation() throws {
    // ADR 0016 "Reference grammar": "inside header brackets `\]` is a literal
    // `]` and `\\` a literal backslash". Plan: "Rename table/column | rewrite
    // bound source references in the same Undo transaction".
    let doc = try sheet(
      [makeTable("Items", ["A", "B"], rows: 2, cells: [(0, 1, "=sum(Items[A])", false)])])
    let before = try view(doc, name: "Items")
    let renamed = try commit(
      doc.renameColumn(table: before.id, column: before.columns[0].id, to: "Odd]\\Name"), to: doc,
      "rename column")
    let after = try view(renamed, name: "Items")
    #expect(after.columns[0].header == "Odd]\\Name")
    #expect(text(after, .init(row: 0, column: 1)) == "=sum(Items[Odd\\]\\\\Name])")
    let bindings = bound(after, .init(row: 0, column: 1))
    #expect(bindings.count == 1)
    #expect(!bindings[0].isDeleted, "a rename must not break a bound reference")
    #expect(bindings[0].target.kind == "named")
    #expect(bindings[0].target.columnID == before.columns[0].id)
  }

  @Test func renamingAColumnLeavesOrdinaryTextUntouched() throws {
    // Plan: "ordinary text/comments are untouched". ADR 0016: "Rename patches
    // bound operands only, together with their ledger; prose/comments are
    // untouched."
    let doc = try sheet(
      [makeTable("Items", ["A", "B"], rows: 2, cells: [(0, 1, "=sum(Items[A])", false)])],
      prose: ["See Items[A] for details", "# sum(Items[A])"])
    let before = try view(doc, name: "Items")
    let proseStart = doc.lines[doc.blocks[0].physicalLines.upperBound].range.lowerBound
    let tail = String(doc.source.dropFirst(proseStart))
    let renamed = try commit(
      doc.renameColumn(table: before.id, column: before.columns[0].id, to: "Total"), to: doc,
      "rename column")
    #expect(renamed.source.hasSuffix(tail), "ordinary text after the block changed")
    #expect(renamed.source.contains("See Items[A] for details"))
    #expect(renamed.source.contains("# sum(Items[A])"))
    #expect(
      text(try view(renamed, name: "Items"), .init(row: 0, column: 1)) == "=sum(Items[Total])")
  }

  // MARK: - 5. renameTable with punctuation

  @Test func renamingATableWithPunctuationQuotesTheIdentifierAndKeepsTheBinding() throws {
    // ADR 0016 "Reference grammar": "table identifiers with punctuation use
    // backticks, doubled backticks escape a backtick".
    let items = makeTable("Items", ["A"], rows: 2)
    let rates = makeTable("Rates", ["A", "B"], rows: 2, cells: [(0, 1, "=Items!A2", false)])
    let doc = try sheet([items, rates])
    let ratesID = rates.id
    let itemsID = items.id
    let spaced = try commit(doc.renameTable(itemsID, to: "Cost Rate"), to: doc, "space name")
    var renamed = try view(spaced, id: ratesID)
    #expect(text(renamed, .init(row: 0, column: 1)) == "=`Cost Rate`!A2")
    var bindings = bound(renamed, .init(row: 0, column: 1))
    #expect(bindings.count == 1 && !bindings[0].isDeleted)
    #expect(bindings[0].target.table == itemsID)
    #expect(bindings[0].target.rowID == items.rows[0])
    #expect(bindings[0].target.columnID == items.columns[0].id)
    let backed = try commit(
      spaced.renameTable(itemsID, to: "Cost`Rate"), to: spaced, "backtick name")
    renamed = try view(backed, id: ratesID)
    #expect(text(renamed, .init(row: 0, column: 1)) == "=`Cost``Rate`!A2")
    bindings = bound(renamed, .init(row: 0, column: 1))
    #expect(bindings.count == 1 && !bindings[0].isDeleted)
    #expect(bindings[0].target.table == itemsID)
    #expect(bindings[0].target.rowID == items.rows[0])
  }

  // MARK: - 6. Prose operands

  @Test func proseOperandsFollowTheEditInTheSameTransaction() throws {
    // ADR 0016: "Rename patches bound operands only, together with their
    // ledger"; plan "Rename table/column: rewrite bound source references in
    // the same Undo transaction". A prose operand is a bound reference.
    let items = makeTable("Items", ["Amount", "Qty"], rows: 2)
    let rates = makeTable("Rates", ["A", "B"], rows: 2)
    let doc = try sheet(
      [items, rates], prose: ["cost = sum(Items[Amount])", "x = Rates!B2"])
    let ratesID = rates.id
    let itemsID = items.id
    let proseStart = doc.lines[doc.blocks[1].physicalLines.upperBound].range.lowerBound
    let tail = String(doc.source.dropFirst(proseStart))
    let grown = try commit(doc.insertRows(table: ratesID, at: 0), to: doc, "row insert")
    #expect(grown.source.hasSuffix("cost = sum(Items[Amount])\nx = Rates!B3\n"))
    #expect(!grown.source.contains(tail), "the qualified prose operand did not follow the edit")
    let renamed = try commit(
      doc.renameColumn(table: itemsID, column: items.columns[0].id, to: "Total"), to: doc,
      "rename column")
    #expect(renamed.source.hasSuffix("cost = sum(Items[Total])\nx = Rates!B2\n"))
  }

  @Test func aDeletedProseTargetKeepsABrokenMarkerThatCoordinateReuseCannotRepair() throws {
    // ADR 0016: "Deletion writes a persistent broken operand. Reusing an
    // address never repairs it." and "These tokens are operands with a
    // diagnostic, never values, and never bind to reused coordinates."
    let rates = makeTable("Rates", ["A", "B"], rows: 3)
    let doc = try sheet([rates], prose: ["x = Rates!B2"])
    let proseLine = doc.blocks[0].physicalLines.upperBound
    let deleted = try commit(doc.deleteRows(table: rates.id, in: 0..<1), to: doc, "delete target")
    let line = deleted.lines[proseLine].text
    #expect(line.hasPrefix("x = #REF!{"), "a deleted prose target must persist a marker: \(line)")
    let gone = rates.rows[0].string
    #expect(line.contains(gone), "the marker must name the deleted target identity: \(line)")
    let reused = try commit(
      deleted.insertRows(table: rates.id, at: 0), to: deleted, "coordinate reuse")
    #expect(
      reused.lines[proseLine].text == line, "coordinate reuse repaired a broken prose operand")
  }

  // MARK: - 7. Duplication

  @Test func duplicatingATableMintsEveryIdentityAndRebindsInternalReferences() throws {
    // ADR 0016: "Duplication mints new IDs and remaps internal references
    // while retaining only visible external targets."
    let plain = makeTable("Items", ["A", "B"], rows: 3, cells: [(0, 0, "5", false)])
    let seeded = try sheet([plain])
    let doc = try commit(
      seeded.setCell(table: plain.id, at: .init(row: 2, column: 1), source: "=sum(A2:A3)"),
      to: seeded, "seed an internal reference")
    let original = try view(doc, name: "Items")
    let sourceBinding = bound(original, .init(row: 2, column: 1))[0]
    #expect(sourceBinding.id != nil)
    let copy = try commit(
      doc.duplicateTable(original.id, named: "Copy", atUTF8: doc.source.utf8.count), to: doc,
      "duplicate table")
    let duplicated = try view(copy, name: "Copy")
    #expect(duplicated.id != original.id)
    #expect(Set(duplicated.rows).isDisjoint(with: Set(original.rows)))
    #expect(Set(duplicated.columns.map(\.id)).isDisjoint(with: Set(original.columns.map(\.id))))
    #expect(text(duplicated, .init(row: 2, column: 1)) == "=sum(A2:A3)")
    let bindings = bound(duplicated, .init(row: 2, column: 1))
    #expect(bindings.count == 1 && !bindings[0].isDeleted)
    #expect(bindings[0].target.kind == "rect")
    #expect(
      rectRows(bindings[0]) == [duplicated.rows[0], duplicated.rows[1]],
      "an internal reference must rebind to the copy's own identities")
    #expect(bindings[0].id != sourceBinding.id, "a duplicate mints new binding identities")
    // The original keeps its own source.
    #expect(try view(copy, name: "Items").cells.count == 2)
  }

  @Test func duplicatingATableRetainsAVisibleExternalTargetAndBreaksOneHiddenByADivider() throws {
    // ADR 0016: "retaining only visible external targets". Plan "Copy
    // table/sheet: … preserve external references only when their targets
    // remain visible, otherwise mark broken."
    let visible = makeTable("Visible", ["A"], rows: 2, cells: [(0, 0, "5", false)])
    let source = makeTable("Source", ["A", "B"], rows: 2, cells: [(0, 1, "=Visible!A2", false)])
    let doc = try sheet([visible, source])
    let sourceID = source.id
    // Insertion at the source's own opener: `Visible` is above it, so visible.
    let kept = try commit(
      doc.duplicateTable(sourceID, named: "Kept", atUTF8: doc.blocks[1].utf8Range.lowerBound),
      to: doc, "duplicate beside a visible target")
    let keptTable = try view(kept, name: "Kept")
    let keptBindings = bound(keptTable, .init(row: 0, column: 1))
    #expect(keptBindings.count == 1)
    #expect(!keptBindings[0].isDeleted, "a visible external target must stay live")
    #expect(keptBindings[0].target.rowID == visible.rows[0])
    #expect(keptBindings[0].target.columnID == visible.columns[0].id)
    #expect(text(keptTable, .init(row: 0, column: 1)) == "=Visible!A2")
    // Insertion below a divider: the divider clears visibility.
    let separated = TableSourceDocument(doc.source + "---\n")
    let broken = try commit(
      separated.duplicateTable(sourceID, named: "Broken", atUTF8: separated.source.utf8.count),
      to: separated, "duplicate below a divider")
    let brokenTable = try view(broken, name: "Broken")
    let brokenBindings = bound(brokenTable, .init(row: 0, column: 1))
    #expect(brokenBindings.count == 1)
    #expect(brokenBindings[0].isDeleted, "a hidden external target must be marked broken")
    #expect(text(brokenTable, .init(row: 0, column: 1)).hasPrefix("=#REF!{"))
    // It cannot revive: growing the still-visible target must not rebind it.
    let revived = try commit(
      broken.insertRows(table: visible.id, at: 0), to: broken, "coordinate reuse")
    let revivedBindings = bound(try view(revived, name: "Broken"), .init(row: 0, column: 1))
    #expect(revivedBindings[0].isDeleted, "a broken duplicate target was revived")
    #expect(
      text(try view(revived, name: "Broken"), .init(row: 0, column: 1)).hasPrefix("=#REF!{"))
  }

  @Test func duplicatingASheetRemintsIdentitiesAndQualifiedProseStillResolves() throws {
    // Plan "Copy table/sheet: mint appropriate new table/row/column IDs and
    // rebind references internal to the copied set; preserve external
    // references only when their targets remain visible".
    let items = makeTable("Items", ["A"], rows: 2, cells: [(0, 0, "5", false)])
    let rates = makeTable("Rates", ["A", "B"], rows: 2, cells: [(0, 1, "=Items!A2", false)])
    let doc = try sheet([items, rates], prose: ["x = Items!A2"])
    let proseStart = doc.lines[doc.blocks[1].physicalLines.upperBound].range.lowerBound
    let tail = String(doc.source.dropFirst(proseStart))
    let copy = try commit(doc.duplicateSheet(), to: doc, "duplicate sheet")
    let copiedItems = try view(copy, name: "Items")
    let copiedRates = try view(copy, name: "Rates")
    #expect(copiedItems.id != items.id && copiedRates.id != rates.id)
    #expect(Set(copiedItems.rows).isDisjoint(with: Set(items.rows)))
    #expect(Set(copiedRates.rows).isDisjoint(with: Set(rates.rows)))
    let bindings = bound(copiedRates, .init(row: 0, column: 1))
    #expect(bindings.count == 1 && !bindings[0].isDeleted)
    #expect(bindings[0].target.table == copiedItems.id, "an internal cross-table reference rebinds")
    #expect(bindings[0].target.rowID == copiedItems.rows[0])
    #expect(copy.source.hasSuffix(tail), "qualified prose must keep resolving to the copy")
  }

  // MARK: - 8. Byte fidelity

  @Test func unknownFieldsSurviveAnEditByteForByte() throws {
    // docs/storage/table-blocks.md: "Keys not defined below are allowed
    // anywhere, ignored, and kept byte for byte because edits patch spans
    // rather than re-encoding the block."
    let items = makeTable(
      "Items", ["A", "B"], rows: 2, cells: [(0, 0, "1", false), (1, 0, "2", false)])
    let payload = try blockText(items)
    let withRoot = payload.replacingOccurrences(
      of: ",\"n\":",
      with: ",\"zz\":{\"keep\":[1,2,\"three\"]},\"n\":")
    #expect(withRoot != payload)
    let doc = TableSourceDocument(withRoot + "naïve ✓ tail\n")
    let id = try view(doc, name: "Items").id
    let edited = try commit(
      doc.setCell(table: id, at: .init(row: 0, column: 1), source: "=A2"), to: doc,
      "edit with unknown fields")
    #expect(edited.source.contains("\"zz\":{\"keep\":[1,2,\"three\"]}"))
    #expect(edited.source.hasSuffix("naïve ✓ tail\n"))
    // The identity dictionary is untouched byte for byte.
    let before = doc.blocks[0].rawSource
    let after = edited.blocks[0].rawSource
    let ids = "\"ids\":"
    func dictionary(_ text: String) -> String {
      guard let from = text.range(of: ids),
        let to = text.range(of: ",\"t\":", range: from.upperBound..<text.endIndex)
      else { return "" }
      return String(text[from.lowerBound..<to.lowerBound])
    }
    #expect(dictionary(before) == dictionary(after))
    #expect(!dictionary(after).isEmpty)
  }

  @Test func recordOrderSurvivesAnEdit() throws {
    // docs/storage/table-blocks.md: "Readers accept any valid spelling;
    // canonical form only makes new blocks deterministic." So a non-row-major
    // record order is readable, and an edit keeps the existing order because
    // "edits replace or append individual JSON values".
    let items = makeTable(
      "Items", ["A", "B"], rows: 2, cells: [(0, 0, "1", false), (1, 0, "2", false)])
    let payload = try blockText(items)
    guard let records = arrayList(payload, "x"), records.count == 2 else {
      Issue.record("expected two cell records")
      return
    }
    let swapped = payload.replacingOccurrences(
      of: "\"x\":[\(records[0]),\(records[1])]", with: "\"x\":[\(records[1]),\(records[0])]")
    #expect(swapped != payload)
    let doc = TableSourceDocument(swapped)
    let id = try view(doc, name: "Items").id
    let edited = try commit(
      doc.setCell(table: id, at: .init(row: 0, column: 1), source: "=A2"), to: doc,
      "edit an unsorted block")
    // The bytes keep the existing order: the row-1 record still precedes the
    // row-0 record, because "edits replace or append individual JSON values".
    guard let earlier = edited.source.range(of: records[1]),
      let later = edited.source.range(of: records[0])
    else {
      Issue.record("an untouched record was re-encoded")
      return
    }
    #expect(
      earlier.lowerBound < later.lowerBound,
      "an edit re-sorted records it did not touch")
    #expect(edited.blocks[0].table != nil)
  }

  @Test func crlfAndCarriageReturnTerminatorsAndSurroundingTextSurviveAnEdit() throws {
    // Plan "Identity in source and after reload": "Lossless parse/serialize
    // preserves untouched UTF-8 text and line endings. Source commands patch
    // relevant spans."
    for ending in [LineTerminator.carriageReturnLineFeed, .carriageReturn] {
      let items = makeTable("Items", ["A", "B"], rows: 2, cells: [(0, 0, "1", false)])
      let block = try blockText(items, ending)
      let head = "café ☕ note" + ending.rawValue
      let tail = "naïve ✓ tail" + ending.rawValue
      let doc = TableSourceDocument(head + block + tail)
      let id = try view(doc, name: "Items").id
      let edited = try commit(
        doc.setCell(table: id, at: .init(row: 1, column: 1), source: "=A2"), to: doc,
        "edit with \(ending.rawValue.debugDescription)")
      #expect(edited.source.hasPrefix(head), "the text before the block changed")
      #expect(edited.source.hasSuffix(tail), "the text after the block changed")
      #expect(
        edited.lines.map(\.terminator) == doc.lines.map(\.terminator),
        "a line terminator changed for \(ending.rawValue.debugDescription)")
      // The untouched identity dictionary is byte identical.
      func dictionary(_ text: String) -> String {
        guard let from = text.range(of: "\"ids\":"),
          let to = text.range(of: ",\"t\":", range: from.upperBound..<text.endIndex)
        else { return "" }
        return String(text[from.lowerBound..<to.lowerBound])
      }
      #expect(dictionary(doc.blocks[0].rawSource) == dictionary(edited.blocks[0].rawSource))
      #expect(!dictionary(edited.blocks[0].rawSource).isEmpty)
      #expect(text(try view(edited, name: "Items"), .init(row: 1, column: 1)) == "=A2")
    }
  }

  @Test func aMalformedNeighbouringBlockSurvivesAnEditByteForByte() throws {
    // docs/storage/table-blocks.md: an unparseable block is diagnosed and
    // quarantined; nothing says an edit elsewhere may rewrite it.
    let items = makeTable("Items", ["A", "B"], rows: 2, cells: [(0, 0, "1", false)])
    let malformed = "@ganit-table 1\n{not json\n@end-ganit-table\n"
    let doc = TableSourceDocument(try blockText(items) + malformed)
    #expect(doc.blocks.count == 2)
    #expect(doc.blocks[1].table == nil)
    let id = try view(doc, name: "Items").id
    let edited = try commit(
      doc.setCell(table: id, at: .init(row: 1, column: 1), source: "=A2"), to: doc,
      "edit beside a malformed block")
    #expect(edited.source.hasSuffix(malformed), "a malformed neighbour was rewritten")
    #expect(edited.blocks.count == 2)
  }

  // MARK: - 9. Admission ceilings

  @Test func anEditThatWouldExceedThePopulatedCellCeilingDoesNotSilentlySucceed() throws {
    // docs/storage/table-blocks.md: "Populated cells … ceiling 4,000 per
    // sheet … exceeding either withholds projections, nothing is truncated."
    let rows = 1334
    var cells: [(row: Int, column: Int, source: String, override: Bool)] = []
    cells.reserveCapacity(4000)
    for row in 0..<rows {
      cells.append((row, 0, "1", false))
      cells.append((row, 1, "1", false))
    }
    for row in 0..<(rows - 2) { cells.append((row, 2, "1", false)) }
    let items = makeTable("Items", ["A", "B", "C"], rows: rows, cells: cells)
    #expect(items.populatedCellCount == 4000)
    let doc = try sheet([items])
    #expect(doc.blocks[0].table != nil, "4,000 populated cells must still project")
    #expect(
      throws: (any Error).self,
      "an edit that pushes the sheet past 4,000 populated cells must not silently succeed"
    ) {
      _ = try doc.setCell(table: items.id, at: .init(row: rows - 2, column: 2), source: "1")
    }
  }

  @Test func anEditThatWouldExceedTheSourceByteLimitDoesNotSilentlySucceed() throws {
    // docs/storage/table-blocks.md: "source limit 1,048,576 bytes".
    let doc = TableSourceDocument("")
    let rows = SyntaxLimits.default.maximumSourceUTF8Length / 38
    #expect(throws: (any Error).self, "a block past the source limit must not be written") {
      _ = try doc.createTable(
        name: "Huge", headers: [("A", TableInputPolicy.value)], rowCount: rows, atUTF8: 0)
    }
    #expect(throws: (any Error).self) {
      _ = try doc.createTable(
        name: "Huge", headers: [("A", TableInputPolicy.value)], rowCount: rows + 1, atUTF8: 0)
    }
  }
}

extension TableReferenceTarget {
  fileprivate var rowID: RowID? {
    if case .cell(_, let row, _) = self { return row }
    return nil
  }
  fileprivate var columnID: ColumnID? {
    if case .cell(_, _, let column) = self { return column }
    if case .namedColumn(_, let column) = self { return column }
    return nil
  }
}
