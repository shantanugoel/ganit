import Foundation

/// A pure canonical-source edit. The caller applies all patches in one document
/// Undo transaction, then rebuilds projections; no mutable model is saved.
package struct TableSourceEdit: Sendable {
  package let patches: [TableSourcePatch]
  package let createdTable: TableID?
  /// Table and column identities reminted by a whole-sheet copy, for
  /// presentation metadata that follows the copied source.
  package let copiedIdentities: [UUID: UUID]

  package init(
    patches: [TableSourcePatch], createdTable: TableID?,
    copiedIdentities: [UUID: UUID] = [:]
  ) {
    self.patches = patches
    self.createdTable = createdTable
    self.copiedIdentities = copiedIdentities
  }
  package func applying(to source: String) throws -> String {
    try TableSourcePatch.applying(patches, to: source)
  }
}

package enum TableTransformError: Error, Equatable {
  case missingTable, invalidPosition, invalidSelection, invisibleTarget, unsupportedClipboard
  case inputPolicyMismatch
  /// Plain text carries no source origin: a field starting with `=` is entered
  /// only after the user explicitly chooses formula interpretation.
  case formulaPasteNotConfirmed
}

package struct TableCellPosition: Hashable, Sendable {
  /// Zero-based data row and column, excluding the header and footer.
  package var row: Int
  package var column: Int

  package init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }
}

package struct TableCellRectangle: Hashable, Sendable {
  package var rows: Range<Int>
  package var columns: Range<Int>

  package init(rows: Range<Int>, columns: Range<Int>) {
    self.rows = rows
    self.columns = columns
  }
}

/// Internal copy carries its origin; plain strings must be explicitly entered at
/// the destination. This version does not claim TSV formulas have an origin.
package struct TableClipboard: Sendable {
  static let currentVersion = 1
  var version = currentVersion
  let originTable: TableID
  let origin: TableCellPosition
  let cell: TableCell?
  let formula: String?
  let ledger: TableLedgerEntry?
  let policy: TableInputPolicy
}

/// A copied rectangle: one versioned payload per cell, row-major, each with
/// its own origin, so pasting translates every formula from where it was.
package struct TableClipboardRange: Sendable {
  static let currentVersion = 1
  var version = currentVersion
  let originTable: TableID
  let origin: TableCellRectangle
  let cells: [[TableClipboard]]
}

extension TableSourceDocument {
  package func createTable(
    name: String, headers: [(String, TableInputPolicy)], rowCount: Int,
    atUTF8 offset: Int, lineEnding: LineTerminator = .lineFeed
  ) throws -> TableSourceEdit {
    guard rowCount >= 0, rowCount <= SyntaxLimits.default.maximumSourceUTF8Length / 38,
      !headers.isEmpty, headers.count <= SyntaxLimits.default.maximumSourceUTF8Length / 38,
      offset >= 0
    else { throw TableTransformError.invalidPosition }
    try checkInsertion(atUTF8: offset)
    let table = TableModel.creating(name: name, headers: headers, rowCount: rowCount)
    let block = try Self.canonicalBlock(for: table, lineEnding: lineEnding)
    let edit = TableSourceEdit(
      patches: [TableSourcePatch(utf8Range: offset..<offset, expected: "", replacement: block)],
      createdTable: table.id)
    try checked(edit)
    return edit
  }

  package func insertRows(table id: TableID, at index: Int, count: Int = 1) throws
    -> TableSourceEdit
  {
    try transform(id) { table in
      guard count > 0,
        count <= SyntaxLimits.default.maximumSourceUTF8Length / 38 - table.rows.count,
        index >= 0, index <= table.rows.count
      else {
        throw TableTransformError.invalidPosition
      }
      table.rows.insert(contentsOf: (0..<count).map { _ in .mint() }, at: index)
    }
  }
  /// Rows after the last data row: dynamic column ranges grow, while a finite
  /// rectangle ending at the old last row does not.
  package func appendRows(table id: TableID, count: Int = 1) throws -> TableSourceEdit {
    try insertRows(table: id, at: model(id).rows.count, count: count)
  }
  package func deleteRows(table id: TableID, in range: Range<Int>) throws -> TableSourceEdit {
    try transform(id) { table in
      guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= table.rows.count else {
        throw TableTransformError.invalidPosition
      }
      let removed = Set(table.rows[range])
      table.rows.removeSubrange(range)
      table.cells.removeAll { removed.contains($0.row) }
      table.ledger.removeAll { entry in
        if case .cell(let row, _) = entry.owner { return removed.contains(row) }
        return false
      }
    }
  }
  package func insertColumn(
    table id: TableID, at index: Int, header: String,
    policy: TableInputPolicy = .value
  ) throws -> TableSourceEdit {
    try transform(id) { table in
      guard index >= 0, index <= table.columns.count else {
        throw TableTransformError.invalidPosition
      }
      table.columns.insert(TableColumn(id: .mint(), header: header, input: policy), at: index)
    }
  }
  package func deleteColumns(table id: TableID, in range: Range<Int>) throws -> TableSourceEdit {
    try transform(id) { table in
      guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= table.columns.count,
        range.count < table.columns.count
      else { throw TableTransformError.invalidPosition }
      let removed = Set(table.columns[range].map(\.id))
      table.columns.removeSubrange(range)
      table.cells.removeAll { removed.contains($0.column) }
      table.ledger.removeAll { removed.contains($0.owner.column) }
    }
  }
  package func renameTable(_ id: TableID, to name: String) throws -> TableSourceEdit {
    try transform(id) { $0.name = name }
  }
  package func renameColumn(table id: TableID, column: ColumnID, to header: String) throws
    -> TableSourceEdit
  {
    try transform(id) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      table.columns[index].header = header
    }
  }

  /// `nil` clears a record (and restores inheritance); `""` is a blank override.
  package func setCell(table id: TableID, at position: TableCellPosition, source input: String?)
    throws
    -> TableSourceEdit
  {
    try transform(id, rewriteRules: false) { table in
      try Self.check(position, in: table)
      let row = table.rows[position.row]
      let column = table.columns[position.column]
      table.cells.removeAll { $0.row == row && $0.column == column.id }
      table.ledger.removeAll { $0.owner == .cell(row: row, column: column.id) }
      if let input, !input.isEmpty || column.rule != nil {
        table.cells.append(
          TableCell(row: row, column: column.id, source: input, isOverride: column.rule != nil))
      }
    }
  }
  package func setColumnRule(table id: TableID, column: ColumnID, source formula: String?) throws
    -> TableSourceEdit
  {
    try transform(id, rewriteRules: false) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      table.columns[index].rule = formula
      table.ledger.removeAll { $0.owner == .rule(column: column) }
      for cellIndex in table.cells.indices where table.cells[cellIndex].column == column {
        table.cells[cellIndex].isOverride = formula != nil
      }
      if formula == nil { table.cells.removeAll { $0.column == column && $0.source.isEmpty } }
    }
  }
  /// `nil` removes the footer aggregate. The footer reads data rows only and
  /// never becomes a numbered data member, so no reference moves.
  package func setColumnTotal(table id: TableID, column: ColumnID, total: TableTotal?) throws
    -> TableSourceEdit
  {
    try transform(id, rewriteRules: false) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      table.columns[index].total = total
    }
  }
  /// Semantic input settings are canonical source: they change how literals
  /// are read, so they are edited as one checked transaction. A text column
  /// has no unit or currency default.
  package func setColumnInput(
    table id: TableID, column: ColumnID, policy: TableInputPolicy, unit: String? = nil,
    currency: String? = nil
  ) throws -> TableSourceEdit {
    try transform(id, rewriteRules: false) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      table.columns[index].input = policy
      table.columns[index].unit = unit
      table.columns[index].currency = currency
    }
  }

  package func setColumnPresentation(
    table id: TableID, column: ColumnID, percentageDecimals: Int?
  ) throws -> TableSourceEdit {
    guard percentageDecimals.map({ (0...12).contains($0) }) ?? true else {
      throw TableTransformError.invalidSelection
    }
    return try transform(id, rewriteRules: false) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      table.columns[index].percentageDecimals = percentageDecimals
    }
  }

  package func setColumnReview(
    table id: TableID, column: ColumnID, sort: String?, filter: String?, frozen: Bool
  ) throws -> TableSourceEdit {
    guard sort == nil || sort == "ascending" || sort == "descending" else {
      throw TableTransformError.invalidSelection
    }
    return try transform(id, rewriteRules: false) { table in
      guard let index = table.columns.firstIndex(where: { $0.id == column }) else {
        throw TableTransformError.invalidPosition
      }
      if sort != nil { for i in table.columns.indices { table.columns[i].reviewSort = nil } }
      table.columns[index].reviewSort = sort
      table.columns[index].reviewFilter = filter
      if frozen { for i in table.columns.indices { table.columns[i].frozen = false } }
      table.columns[index].frozen = frozen
    }
  }

  package func clipboard(table id: TableID, at position: TableCellPosition) throws -> TableClipboard
  {
    let table = try model(id)
    try Self.check(position, in: table)
    return Self.clipboard(
      table, bound: try Self.bound(table, visible: visible(at: id)), at: position)
  }
  private static func clipboard(
    _ table: TableModel, bound: TableModel, at position: TableCellPosition
  ) -> TableClipboard {
    let row = table.rows[position.row]
    let column = table.columns[position.column]
    let cell = table.cells.first { $0.row == row && $0.column == column.id }
    let owner: TableFormulaOwner =
      cell == nil && column.rule != nil
      ? .rule(column: column.id) : .cell(row: row, column: column.id)
    let formula = cell?.source ?? column.rule
    return TableClipboard(
      originTable: table.id, origin: position, cell: cell, formula: formula,
      ledger: bound.ledger.first { $0.owner == owner }, policy: column.input)
  }
  package func clipboard(table id: TableID, rectangle: TableCellRectangle) throws
    -> TableClipboardRange
  {
    let table = try model(id)
    try Self.check(rectangle, in: table)
    let bound = try Self.bound(table, visible: visible(at: id))
    return TableClipboardRange(
      originTable: id, origin: rectangle,
      cells: rectangle.rows.map { row in
        rectangle.columns.map {
          Self.clipboard(table, bound: bound, at: .init(row: row, column: $0))
        }
      })
  }
  /// Pastes a copied rectangle with its top-left at `destination`, as one
  /// edit. Each cell translates from its own origin; the destination must fit
  /// inside the table, which never grows to receive a paste.
  package func paste(
    _ clipboard: TableClipboardRange, table id: TableID, at destination: TableCellPosition
  ) throws -> TableSourceEdit {
    guard clipboard.version == TableClipboardRange.currentVersion,
      clipboard.cells.allSatisfy({ row in
        row.allSatisfy { $0.version == TableClipboard.currentVersion }
      })
    else { throw TableTransformError.unsupportedClipboard }
    let size = (rows: clipboard.cells.count, columns: clipboard.cells.first?.count ?? 0)
    guard size.rows > 0, size.columns > 0, clipboard.cells.allSatisfy({ $0.count == size.columns })
    else { throw TableTransformError.invalidSelection }
    try Self.check(
      TableCellRectangle(
        rows: destination.row..<(destination.row + size.rows),
        columns: destination.column..<(destination.column + size.columns)), in: model(id))
    let targets = blocks.compactMap(\.table)
    let visible = visible(at: id)
    return try transform(id, rewriteRules: false) { table in
      for (rowOffset, row) in clipboard.cells.enumerated() {
        for (columnOffset, payload) in row.enumerated() {
          try Self.paste(
            payload, into: &table,
            at: .init(row: destination.row + rowOffset, column: destination.column + columnOffset),
            targets: targets, visible: visible)
        }
      }
    }
  }

  /// The interoperable plain-text fallback: tab-separated source rows. An
  /// inherited rule cell is spelled as its instantiated formula for that row.
  /// Fields holding a tab, line break or leading quote are quoted, doubling
  /// inner quotes, as spreadsheets exchange them.
  package func plainText(table id: TableID, rectangle: TableCellRectangle) throws -> String {
    let table = try model(id)
    try Self.check(rectangle, in: table)
    let visible = visible(at: id)
    let bound = try Self.bound(table, visible: visible)
    let targets = blocks.compactMap(\.table)
    var lines: [String] = []
    for row in rectangle.rows {
      var fields: [String] = []
      for column in rectangle.columns {
        let rowID = table.rows[row]
        let columnID = table.columns[column].id
        var text = table.cells.first { $0.row == rowID && $0.column == columnID }?.source ?? ""
        if text.isEmpty, table.columns[column].rule != nil,
          !table.cells.contains(where: { $0.row == rowID && $0.column == columnID })
        {
          var scratch = bound
          let position = TableCellPosition(row: row, column: column)
          try Self.paste(
            Self.clipboard(table, bound: bound, at: position), into: &scratch, at: position,
            targets: targets, visible: visible)
          scratch = try Self.rewritten(scratch, targets: visible + [scratch])
          text = scratch.cells.first { $0.row == rowID && $0.column == columnID }?.source ?? ""
        }
        let quoted =
          text.contains(where: { $0 == "\t" || $0.isNewline }) || text.hasPrefix("\"")
        fields.append(
          quoted ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text)
      }
      lines.append(fields.joined(separator: "\t"))
    }
    return lines.joined(separator: "\n")
  }

  /// Enters external plain text (TSV) with its top-left at `destination`.
  /// It has no trustworthy origin, so nothing is translated: literals are read
  /// by each destination column, and formulas bind afresh at their destination
  /// only when `formulas` records the user's explicit formula-paste choice.
  /// An empty field is blank (a blank override in a rule column). The table
  /// never grows to receive the paste.
  package func pastePlainText(
    _ text: String, table id: TableID, at destination: TableCellPosition, formulas: Bool
  ) throws -> TableSourceEdit {
    let grid = Self.tabSeparated(text)
    let width = grid.map(\.count).max() ?? 0
    guard !grid.isEmpty, width > 0 else { throw TableTransformError.invalidSelection }
    try Self.check(
      TableCellRectangle(
        rows: destination.row..<(destination.row + grid.count),
        columns: destination.column..<(destination.column + width)), in: model(id))
    if !formulas, grid.contains(where: { $0.contains { $0.hasPrefix("=") } }) {
      throw TableTransformError.formulaPasteNotConfirmed
    }
    return try transform(id, rewriteRules: false) { table in
      for (rowOffset, fields) in grid.enumerated() {
        for (columnOffset, input) in fields.enumerated() {
          let row = table.rows[destination.row + rowOffset]
          let column = table.columns[destination.column + columnOffset]
          table.cells.removeAll { $0.row == row && $0.column == column.id }
          table.ledger.removeAll { $0.owner == .cell(row: row, column: column.id) }
          if !input.isEmpty || column.rule != nil {
            table.cells.append(
              TableCell(row: row, column: column.id, source: input, isOverride: column.rule != nil))
          }
        }
      }
    }
  }

  /// Splits TSV into rows of fields. One final line break ends the last row
  /// rather than adding an empty one; CRLF, CR and LF all end rows.
  package static func tabSeparated(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var fields: [String] = []
    var field = ""
    var quoted = false
    var started = false
    var characters = text.makeIterator()
    var pending = characters.next()
    while let character = pending {
      pending = characters.next()
      if quoted {
        if character == "\"" {
          if pending == "\"" {
            field.append("\"")
            pending = characters.next()
          } else {
            quoted = false
          }
        } else {
          field.append(character)
        }
        continue
      }
      switch character {
      case "\"" where field.isEmpty:
        quoted = true
        started = true
      case "\t":
        fields.append(field)
        field = ""
        started = true
      case "\n", "\r", "\r\n":
        fields.append(field)
        rows.append(fields)
        fields = []
        field = ""
        started = false
      default:
        field.append(character)
        started = true
      }
    }
    if started || !field.isEmpty || !fields.isEmpty {
      fields.append(field)
      rows.append(fields)
    }
    return rows
  }

  package func copyCell(
    table id: TableID, from origin: TableCellPosition, to destination: TableCellPosition
  ) throws -> TableSourceEdit {
    try paste(clipboard(table: id, at: origin), table: id, at: destination)
  }
  /// Across tables, literals require the same input policy. Formula operands
  /// retain their original target table and translate against its bounded axes;
  /// visible targets are qualified in source. Invisible targets and current-row
  /// columns absent from the destination remain persistently broken. Moves are
  /// deliberately limited to one table.
  package func paste(
    _ clipboard: TableClipboard, table id: TableID, at destination: TableCellPosition
  )
    throws -> TableSourceEdit
  {
    guard clipboard.version == TableClipboard.currentVersion else {
      throw TableTransformError.unsupportedClipboard
    }
    let targets = blocks.compactMap(\.table)
    let visible = visible(at: id)
    return try transform(id, rewriteRules: false) { table in
      try Self.paste(clipboard, into: &table, at: destination, targets: targets, visible: visible)
    }
  }

  private static func paste(
    _ clipboard: TableClipboard, into table: inout TableModel,
    at destination: TableCellPosition, targets: [TableModel], visible: [TableModel]
  ) throws {
    try Self.check(destination, in: table)
    let row = table.rows[destination.row]
    let column = table.columns[destination.column]
    if clipboard.policy != column.input, clipboard.formula?.hasPrefix("=") != true {
      throw TableTransformError.inputPolicyMismatch
    }
    table.cells.removeAll { $0.row == row && $0.column == column.id }
    table.ledger.removeAll { $0.owner == .cell(row: row, column: column.id) }
    guard let input = clipboard.formula else {
      if column.rule != nil {
        table.cells.append(TableCell(row: row, column: column.id, source: "", isOverride: true))
      }
      return
    }
    let owner = TableFormulaOwner.cell(row: row, column: column.id)
    var entry = clipboard.ledger
    if var copied = entry {
      copied.owner = owner
      let originRow = clipboard.cell == nil ? 0 : clipboard.origin.row
      for index in copied.bindings.indices {
        copied.bindings[index] = Self.translated(
          copied.bindings[index],
          in: targets.first(where: { $0.id == copied.bindings[index].target.table }) ?? table,
          rows: destination.row - originRow, columns: destination.column - clipboard.origin.column
        )
        var binding = copied.bindings[index]
        if clipboard.originTable != table.id, !binding.isDeleted {
          if case .currentRow(let sourceColumn) = binding.target {
            if !table.columns.contains(where: { $0.id == sourceColumn }) {
              binding.isDeleted = true
            }
          } else if let target = binding.target.table, target != table.id,
            !visible.contains(where: { $0.id == target })
          {
            binding = Self.brokenExternal(binding)
          }
        }
        if binding.id != nil { binding.id = .mint() }
        copied.bindings[index] = binding
      }
      entry = copied
    }
    if !input.isEmpty || column.rule != nil {
      table.cells.append(
        TableCell(row: row, column: column.id, source: input, isOverride: column.rule != nil))
    }
    if let entry { table.ledger.append(entry) }
  }
  package func fill(
    table id: TableID, from origin: TableCellPosition, into rectangle: TableCellRectangle
  )
    throws -> TableSourceEdit
  {
    let payload = try clipboard(table: id, at: origin)
    let table = try model(id)
    guard !rectangle.rows.isEmpty, !rectangle.columns.isEmpty else {
      throw TableTransformError.invalidSelection
    }
    try Self.check(
      .init(row: rectangle.rows.lowerBound, column: rectangle.columns.lowerBound), in: table)
    try Self.check(
      .init(row: rectangle.rows.upperBound - 1, column: rectangle.columns.upperBound - 1), in: table
    )
    let targets = blocks.compactMap(\.table)
    let visible = visible(at: id)
    return try transform(id, rewriteRules: false) { table in
      for row in rectangle.rows {
        for column in rectangle.columns where TableCellPosition(row: row, column: column) != origin
        {
          try Self.paste(
            payload, into: &table, at: .init(row: row, column: column), targets: targets,
            visible: visible)
        }
      }
    }
  }

  /// Simultaneous rectangular relocation. Overlap is supported; destinations
  /// are overwritten, while every moved formula keeps its target identities.
  package func move(
    table id: TableID, rectangle: TableCellRectangle, to destination: TableCellPosition
  )
    throws -> TableSourceEdit
  {
    let old = try model(id)
    guard !rectangle.rows.isEmpty, !rectangle.columns.isEmpty else {
      throw TableTransformError.invalidSelection
    }
    try Self.check(
      TableCellPosition(row: rectangle.rows.lowerBound, column: rectangle.columns.lowerBound),
      in: old)
    try Self.check(
      TableCellPosition(
        row: rectangle.rows.upperBound - 1, column: rectangle.columns.upperBound - 1), in: old)
    try Self.check(destination, in: old)
    try Self.check(
      TableCellPosition(
        row: destination.row + rectangle.rows.count - 1,
        column: destination.column + rectangle.columns.count - 1), in: old)
    // Binding never changes axes, so these pairs also address the bound model.
    var relocated: [TableFormulaOwner: TableFormulaOwner] = [:]
    for row in rectangle.rows {
      for column in rectangle.columns {
        let fromColumn = old.columns[column]
        let toColumn = old.columns[destination.column + column - rectangle.columns.lowerBound]
        let cell = old.cells.first { $0.row == old.rows[row] && $0.column == fromColumn.id }
        // Moving inherited rules partially would change the source column's
        // semantics; require an explicit override first rather than guessing.
        guard fromColumn.rule == nil || cell != nil else {
          throw TableTransformError.invalidSelection
        }
        // Literals keep the copy policy: they never change input policy silently.
        if fromColumn.input != toColumn.input, cell?.isFormula != true {
          throw TableTransformError.inputPolicyMismatch
        }
        relocated[.cell(row: old.rows[row], column: fromColumn.id)] = .cell(
          row: old.rows[destination.row + row - rectangle.rows.lowerBound], column: toColumn.id)
      }
    }
    return try transform(id, rewriteRules: false, relocated: relocated) { table in
      let old = table
      var moved: [(TableCell?, TableLedgerEntry?, RowID, ColumnID)] = []
      var affected: Set<TableFormulaOwner> = []
      for (owner, target) in relocated {
        guard case .cell(let fromRow, let fromColumn) = owner,
          case .cell(let toRow, let toColumn) = target
        else { continue }
        let cell = old.cells.first { $0.row == fromRow && $0.column == fromColumn }
        moved.append((cell, old.ledger.first { $0.owner == owner }, toRow, toColumn))
        affected.insert(owner)
        affected.insert(target)
      }
      table.cells.removeAll { affected.contains(.cell(row: $0.row, column: $0.column)) }
      table.ledger.removeAll { affected.contains($0.owner) }
      for (cell, entry, row, column) in moved {
        let ruled = table.columns.contains { $0.id == column && $0.rule != nil }
        if var cell {
          cell.row = row
          cell.column = column
          cell.isOverride = ruled
          if !cell.source.isEmpty || cell.isOverride { table.cells.append(cell) }
        } else if ruled {
          table.cells.append(TableCell(row: row, column: column, source: "", isOverride: true))
        }
        if var entry {
          entry.owner = .cell(row: row, column: column)
          table.ledger.append(entry)
        }
      }
    }
  }

  private func model(_ id: TableID) throws -> TableModel {
    guard let table = blocks.compactMap(\.table).first(where: { $0.id == id }) else {
      throw TableTransformError.missingTable
    }
    return table
  }
  func visible(at id: TableID) -> [TableModel] {
    var visible: [TableModel] = []
    var line = 0
    for block in blocks {
      for text in lines[line..<block.physicalLines.lowerBound].map(\.text) where Self.divider(text)
      { visible.removeAll() }
      if block.table?.id == id { break }
      if let table = block.table { visible.append(table) }
      line = block.physicalLines.upperBound
    }
    return visible
  }
  private static func divider(_ text: String) -> Bool {
    if case .divider = LineSyntax(text) { return true }
    return false
  }
  private static func check(_ position: TableCellPosition, in table: TableModel) throws {
    guard table.rows.indices.contains(position.row), table.columns.indices.contains(position.column)
    else { throw TableTransformError.invalidPosition }
  }
  private static func check(_ rectangle: TableCellRectangle, in table: TableModel) throws {
    guard !rectangle.rows.isEmpty, !rectangle.columns.isEmpty else {
      throw TableTransformError.invalidSelection
    }
    try check(
      .init(row: rectangle.rows.lowerBound, column: rectangle.columns.lowerBound), in: table)
    try check(
      .init(row: rectangle.rows.upperBound - 1, column: rectangle.columns.upperBound - 1), in: table
    )
  }
  private func checkInsertion(atUTF8 offset: Int) throws {
    let bytes = Array(source.utf8)
    guard isUTF8Boundary(offset, bytes),
      lines.contains(where: { $0.range.lowerBound == offset })
        || offset == bytes.count && (bytes.isEmpty || bytes.last == 10 || bytes.last == 13),
      !blocks.contains(where: { $0.utf8Range.contains(offset) && $0.utf8Range.lowerBound != offset }
      )
    else { throw TableTransformError.invalidPosition }
  }

  private func checked(_ edit: TableSourceEdit) throws {
    let result = TableSourceDocument(try edit.applying(to: source))
    if let created = edit.createdTable, !result.blocks.contains(where: { $0.table?.id == created })
    {
      throw TableTransformError.invalidPosition
    }
    let oldInvalid = blocks.filter { $0.table == nil }.map(\.rawSource)
    for block in result.blocks where block.table == nil {
      guard oldInvalid.contains(where: { $0.utf8.elementsEqual(block.rawSource.utf8) }) else {
        throw TableBlockError(
          code: block.diagnostics.first?.code ?? .invalidRecord,
          detail: "The source edit violates the table contract")
      }
    }
  }

  /// `relocated` maps moved cell owners to their destinations so their records
  /// keep their unknown members in source.
  private func transform(
    _ id: TableID, rewriteRules: Bool = true,
    relocated: [TableFormulaOwner: TableFormulaOwner] = [:],
    mutation: (inout TableModel) throws -> Void
  ) throws -> TableSourceEdit {
    var models = blocks.compactMap(\.table)
    guard let index = models.firstIndex(where: { $0.id == id }) else {
      throw TableTransformError.missingTable
    }
    // Bind existing live references before touching coordinates. A failed inherited
    // scalar does not prevent references from retaining structural identity.
    for position in models.indices {
      models[position] = try Self.bound(models[position], visible: visible(at: models[position].id))
    }
    let old = models
    try mutation(&models[index])
    let changed = models[index]
    if rewriteRules, changed.rows.isEmpty {
      for entryIndex in models[index].ledger.indices {
        guard case .rule = models[index].ledger[entryIndex].owner else { continue }
        models[index].ledger[entryIndex].bindings.removeAll { binding in
          guard !binding.isDeleted, binding.target.table == id else { return false }
          switch binding.target {
          case .cell(_, let row, _): return row != nil && !binding.locks[0]
          case .rectangle: return !binding.locks[0] && !binding.locks[2]
          case .rows: return binding.locks.allSatisfy { !$0 }
          case .columns, .namedColumn, .currentRow: return false
          }
        }
      }
      models[index].ledger.removeAll { $0.bindings.isEmpty }
    }
    for position in models.indices {
      for entryIndex in models[position].ledger.indices {
        var entry = models[position].ledger[entryIndex]
        for bindingIndex in entry.bindings.indices {
          var binding = entry.bindings[bindingIndex]
          if !binding.isDeleted,
            binding.target.table == id || (binding.target.table == nil && models[position].id == id)
          {
            binding = Self.surviving(binding, old: old[index], new: changed)
            if rewriteRules, models[position].id == id, case .rule = entry.owner,
              old[index].rows.first != changed.rows.first
            {
              binding = Self.rebased(
                binding, original: entry.bindings[bindingIndex], old: old[index], new: changed)
            }
          }
          entry.bindings[bindingIndex] = binding
        }
        models[position].ledger[entryIndex] = entry
      }
    }
    for position in models.indices {
      models[position] = try Self.rewritten(models[position], targets: models)
      models[position] = try Self.bound(
        models[position],
        visible: models.filter { visible(at: models[position].id).map(\.id).contains($0.id) })
    }
    // Identities are minted only by the deliberate edit: in another table, an
    // owner whose text did not change keeps exactly its persisted bindings.
    for (position, original) in zip(models.indices, blocks.compactMap(\.table))
    where position != index {
      models[position].ledger = models[position].ledger.compactMap { entry in
        let text: String?
        switch entry.owner {
        case .rule(let column): text = original.columns.first { $0.id == column }?.rule
        case .cell(let row, let column):
          text = original.cells.first { $0.row == row && $0.column == column }?.source
        }
        guard let text, text.utf8.elementsEqual(entry.fingerprint.utf8) else { return entry }
        let persisted = original.ledger.first { $0.owner == entry.owner }?.bindings ?? []
        var entry = entry
        entry.bindings.removeAll { binding in !persisted.contains { $0.operand == binding.operand }
        }
        return entry.bindings.isEmpty ? nil : entry
      }
    }
    var patches: [TableSourcePatch] = []
    for block in blocks {
      if let table = block.table, let replacement = models.first(where: { $0.id == table.id }) {
        patches += try block.patches(
          for: replacement, relocated: table.id == id ? relocated : [:])
      }
    }
    patches += try prosePatches(old: old, new: models)
    let edit = TableSourceEdit(patches: patches, createdTable: nil)
    try checked(edit)
    return edit
  }

  private static func bound(_ table: TableModel, visible: [TableModel]) throws -> TableModel {
    var table = table
    let sources =
      table.columns.compactMap { column in
        column.rule.map { (TableFormulaOwner.rule(column: column.id), $0) }
      } + table.cells.filter(\.isFormula).map { (.cell(row: $0.row, column: $0.column), $0.source) }
    for (owner, source) in sources {
      guard let syntax = try? TableFormulaSyntax.discover(source) else { continue }
      let persisted = table.ledger.first { $0.owner == owner }
      if let persisted, !persisted.fingerprint.utf8.elementsEqual(source.utf8) {
        throw TableCodecError.stalePatch
      }
      var bindings: [TableBinding] = []
      for occurrence in syntax.references {
        if case .inherited = occurrence.syntax { continue }
        let span = occurrence.range.lowerBound..<occurrence.range.upperBound
        let existing = persisted?.bindings.first { $0.operand == span }
        let single = TableFormulaSyntax(
          source: source, tableFormula: true,
          references: [occurrence], tokens: syntax.tokens, diagnostics: syntax.diagnostics)
        let entry = existing.map {
          TableLedgerEntry(owner: owner, fingerprint: source, bindings: [$0])
        }
        do {
          let references = try single.bind(
            scope: TableFormulaScope(current: table, visible: visible, inherited: [:]),
            ledger: entry)
          if let reference = references.first, let target = reference.target {
            bindings.append(
              TableBinding(
                id: existing?.id ?? (target.hasBindingID ? .mint() : nil), operand: span,
                target: target, locks: reference.locks, isDeleted: reference.deleted))
          }
        } catch {
          // A fresh unresolved occurrence is repairable source, while an already
          // bound occurrence must never silently fall back to coordinates.
          if existing != nil { throw error }
        }
      }
      if let persisted,
        !persisted.bindings.allSatisfy({ old in bindings.contains { $0.operand == old.operand } })
      {
        throw TableCodecError.stalePatch
      }
      table.ledger.removeAll { $0.owner == owner }
      if !bindings.isEmpty {
        table.ledger.append(TableLedgerEntry(owner: owner, fingerprint: source, bindings: bindings))
      }
    }
    return table
  }

  private static func members<ID>(_ axis: TableMembership<ID>, in order: [ID]) -> [ID] {
    switch axis {
    case .retained(let ids): return ids
    case .interval(let first, let last):
      guard let start = order.firstIndex(of: first), let end = order.firstIndex(of: last),
        start <= end
      else { return [] }
      return Array(order[start...end])
    }
  }
  private static func survived<ID>(_ axis: TableMembership<ID>, old: [ID], new: [ID]) -> (
    TableMembership<ID>, Bool
  ) {
    let included = members(axis, in: old)
    let kept = included.filter { new.contains($0) }
    if let first = kept.first, let last = kept.last {
      return (.interval(first: first, last: last), true)
    }
    return (.retained(included), false)
  }
  private static func surviving(_ original: TableBinding, old: TableModel, new: TableModel)
    -> TableBinding
  {
    if original.isDeleted { return original }
    var binding = original
    let columns = new.columns.map(\.id)
    let oldColumns = old.columns.map(\.id)
    switch original.target {
    case .cell(let table, let row, let column):
      binding.isDeleted = !columns.contains(column) || (row.map { !new.rows.contains($0) } ?? false)
      binding.target = .cell(table: table, row: row, column: column)
    case .rectangle(let table, let rows, let cols):
      let (r, liveR) = survived(rows, old: old.rows, new: new.rows)
      let (c, liveC) = survived(cols, old: oldColumns, new: columns)
      binding.isDeleted = !liveR || !liveC
      binding.target = .rectangle(
        table: table,
        rows: binding.isDeleted ? .retained(members(rows, in: old.rows)) : r,
        columns: binding.isDeleted ? .retained(members(cols, in: oldColumns)) : c)
    case .rows(let table, let rows):
      let (axis, live) = survived(rows, old: old.rows, new: new.rows)
      binding.target = .rows(table: table, axis)
      binding.isDeleted = !live
    case .columns(let table, let cols):
      let (axis, live) = survived(cols, old: oldColumns, new: columns)
      binding.target = .columns(table: table, axis)
      binding.isDeleted = !live
    case .namedColumn(let table, let column):
      binding.target = .namedColumn(table: table, column: column)
      binding.isDeleted = !columns.contains(column)
    case .currentRow(let column): binding.isDeleted = !columns.contains(column)
    }
    return binding
  }

  /// Copy translates coordinates against the bounded target table. New missing
  /// axis identities represent out-of-bounds destinations, and cannot be revived
  /// by later coordinate reuse. Existing broken operands are copied as broken.
  private static func translated(
    _ original: TableBinding, in table: TableModel, rows deltaRow: Int, columns deltaColumn: Int
  ) -> TableBinding {
    if original.isDeleted || original.target.table != nil && original.target.table != table.id {
      return original
    }
    var binding = original
    func row(_ id: RowID?, locked: Bool) -> (RowID?, Bool) {
      if locked { return (id, true) }
      let number = id.flatMap { table.rows.firstIndex(of: $0).map { $0 + 2 } } ?? 1
      let translated = number + deltaRow
      if translated == 1 { return (nil, true) }
      if translated >= 2, translated <= table.rows.count + 1 {
        return (table.rows[translated - 2], true)
      }
      return (.mint(), false)
    }
    func column(_ id: ColumnID, locked: Bool) -> (ColumnID, Bool) {
      if locked { return (id, true) }
      guard let current = table.columns.firstIndex(where: { $0.id == id }) else {
        return (id, false)
      }
      let translated = current + deltaColumn
      return table.columns.indices.contains(translated)
        ? (table.columns[translated].id, true) : (.mint(), false)
    }
    func rowAxis(_ axis: TableMembership<RowID>, locks: [Bool]) -> (TableMembership<RowID>, Bool) {
      guard case .interval(let first, let last) = axis else { return (axis, false) }
      let a = row(first, locked: locks[0])
      let b = row(last, locked: locks[1])
      // Header rows do not belong to data ranges.
      guard a.1, b.1, let first = a.0, let last = b.0,
        let start = table.rows.firstIndex(of: first), let end = table.rows.firstIndex(of: last),
        start <= end
      else {
        return (.retained([RowID.mint()]), false)
      }
      return (.interval(first: first, last: last), true)
    }
    func columnAxis(_ axis: TableMembership<ColumnID>, locks: [Bool]) -> (
      TableMembership<ColumnID>, Bool
    ) {
      guard case .interval(let first, let last) = axis else { return (axis, false) }
      let a = column(first, locked: locks[0])
      let b = column(last, locked: locks[1])
      guard a.1, b.1, let start = table.columns.firstIndex(where: { $0.id == a.0 }),
        let end = table.columns.firstIndex(where: { $0.id == b.0 }), start <= end
      else {
        return (.retained([ColumnID.mint()]), false)
      }
      return (.interval(first: a.0, last: b.0), true)
    }
    switch original.target {
    case .cell(let t, let r, let c):
      let translatedRow = row(r, locked: original.locks[0])
      let translatedColumn = column(c, locked: original.locks[1])
      binding.target = .cell(table: t, row: translatedRow.0, column: translatedColumn.0)
      binding.isDeleted = !translatedRow.1 || !translatedColumn.1
    case .rectangle(let t, let r, let c):
      let rr = rowAxis(r, locks: [original.locks[0], original.locks[2]])
      let cc = columnAxis(c, locks: [original.locks[1], original.locks[3]])
      binding.isDeleted = !rr.1 || !cc.1
      binding.target = .rectangle(
        table: t,
        rows: binding.isDeleted ? .retained(members(rr.0, in: table.rows)) : rr.0,
        columns: binding.isDeleted ? .retained(members(cc.0, in: table.columns.map(\.id))) : cc.0)
    case .rows(let t, let axis):
      let result = rowAxis(axis, locks: original.locks)
      binding.target = .rows(table: t, result.0)
      binding.isDeleted = !result.1
    case .columns(let t, let axis):
      let result = columnAxis(axis, locks: original.locks)
      binding.target = .columns(table: t, result.0)
      binding.isDeleted = !result.1
    case .namedColumn, .currentRow: break
    }
    return binding
  }

  private static func rebased(
    _ surviving: TableBinding, original: TableBinding, old: TableModel, new: TableModel
  ) -> TableBinding {
    // Relative rule rows retain their offset from the virtual/first row-2
    // anchor. Locks retain old identity and therefore use structural survival.
    // A shrunken table cannot hold every old offset: a range end clamps to the
    // last row, and any other bound keeps its structural survivor (shifted by
    // the rows removed before it) instead of inventing a broken identity.
    var result = surviving
    func offset(_ id: RowID) -> RowID? {
      guard let index = old.rows.firstIndex(of: id), new.rows.indices.contains(index) else {
        return nil
      }
      return new.rows[index]
    }
    func interval(_ axis: TableMembership<RowID>, startLocked: Bool, endLocked: Bool)
      -> TableMembership<RowID>?
    {
      guard case .interval(let first, let last) = axis else { return nil }
      var survivors: (first: RowID, last: RowID)?
      if case (.interval(let a, let b), true) = survived(axis, old: old.rows, new: new.rows) {
        survivors = (a, b)
      }
      let start = startLocked ? survivors?.first : offset(first)
      let end = endLocked ? survivors?.last : offset(last) ?? start.flatMap { _ in new.rows.last }
      guard let start, let end, let a = new.rows.firstIndex(of: start),
        let b = new.rows.firstIndex(of: end), a <= b
      else { return nil }
      return .interval(first: start, last: end)
    }
    switch original.target {
    case .cell(let table, let row?, let column) where !original.locks[0]:
      guard let rebased = offset(row) else { return surviving }
      result.target = .cell(table: table, row: rebased, column: column)
      result.isDeleted = !new.columns.contains { $0.id == column }
    case .rectangle(let table, let rows, let columns):
      let (cols, hasColumns) = survived(
        columns, old: old.columns.map(\.id), new: new.columns.map(\.id))
      guard hasColumns,
        let rows = interval(rows, startLocked: original.locks[0], endLocked: original.locks[2])
      else { return surviving }
      result.isDeleted = false
      result.target = .rectangle(table: table, rows: rows, columns: cols)
    case .rows(let table, let rows):
      guard let rows = interval(rows, startLocked: original.locks[0], endLocked: original.locks[1])
      else { return surviving }
      result.isDeleted = false
      result.target = .rows(table: table, rows)
    case .cell, .columns, .namedColumn, .currentRow: break
    }
    return result
  }

  static func identifier(_ name: String) -> String {
    let chars = Array(name)
    if let first = chars.first, first.isASCII && (first.isLetter || first == "_"),
      chars.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    {
      return name
    }
    return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
  }
  private static func bracket(_ name: String) -> String {
    name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
  }
  package static func letters(_ index: Int) -> String {
    var number = index + 1
    var result = ""
    while number > 0 {
      number -= 1
      result = String(UnicodeScalar(65 + number % 26)!) + result
      number /= 26
    }
    return result
  }
  private static func rendered(
    _ binding: TableBinding, owner: TableID?, targets: [TableModel], original: String
  ) throws -> String {
    if binding.isDeleted { return binding.brokenMarker }
    if let syntax = try? TableFormulaSyntax.discover(original),
      let references = try? syntax.bind(
        scope: TableFormulaScope(
          current: targets.first { $0.id == owner }, visible: targets, inherited: [:])),
      references.count == 1, references[0].target == binding.target,
      references[0].locks == binding.locks
    {
      return original
    }
    guard let table = targets.first(where: { $0.id == (binding.target.table ?? owner) }) else {
      throw TableTransformError.invisibleTarget
    }
    let qualified = owner != table.id || original.contains("!")
    let prefix = qualified ? identifier(table.name) + "!" : ""
    func column(_ id: ColumnID, _ locked: Bool) throws -> String {
      guard let index = table.columns.firstIndex(where: { $0.id == id }) else {
        throw TableTransformError.invalidPosition
      }
      return (locked ? "$" : "") + letters(index)
    }
    func row(_ id: RowID?, _ locked: Bool) throws -> String {
      let number: Int
      if let id {
        guard let index = table.rows.firstIndex(of: id) else {
          throw TableTransformError.invalidPosition
        }
        number = index + 2
      } else {
        number = 1
      }
      return (locked ? "$" : "") + String(number)
    }
    switch binding.target {
    case .cell(_, let r, let c):
      return prefix + (try column(c, binding.locks[1])) + (try row(r, binding.locks[0]))
    case .rectangle(_, let rows, let columns):
      guard case .interval(let a, let b) = rows, case .interval(let c, let d) = columns else {
        throw TableTransformError.invalidSelection
      }
      return prefix + (try column(c, binding.locks[1])) + (try row(a, binding.locks[0])) + ":"
        + (try column(d, binding.locks[3])) + (try row(b, binding.locks[2]))
    case .columns(_, let columns):
      guard case .interval(let first, let last) = columns else {
        throw TableTransformError.invalidSelection
      }
      return prefix + (try column(first, binding.locks[0])) + ":"
        + (try column(last, binding.locks[1]))
    case .rows(_, let rows):
      guard case .interval(let first, let last) = rows else {
        throw TableTransformError.invalidSelection
      }
      // Qualify otherwise clock-like row ranges (2:4) to disambiguate them.
      return identifier(table.name) + "!" + (try row(first, binding.locks[0])) + ":"
        + (try row(last, binding.locks[1]))
    case .namedColumn(_, let id):
      guard let col = table.columns.first(where: { $0.id == id }) else {
        throw TableTransformError.invalidPosition
      }
      return identifier(table.name) + "[" + bracket(col.header) + "]"
    case .currentRow(let id):
      guard let col = table.columns.first(where: { $0.id == id }) else {
        throw TableTransformError.invalidPosition
      }
      return "[@[" + bracket(col.header) + "]]"
    }
  }
  private static func rewrite(_ entry: TableLedgerEntry, owner: TableID?, targets: [TableModel])
    throws -> TableLedgerEntry
  {
    var updated = entry
    var bytes: [UInt8] = []
    var cursor = 0
    let source = Array(entry.fingerprint.utf8)
    for index in entry.bindings.indices {
      var binding = entry.bindings[index]
      bytes += source[cursor..<binding.operand.lowerBound]
      let original = String(decoding: source[binding.operand], as: UTF8.self)
      let replacement = try rendered(binding, owner: owner, targets: targets, original: original)
      let start = bytes.count
      bytes += replacement.utf8
      cursor = binding.operand.upperBound
      binding.operand = start..<bytes.count
      updated.bindings[index] = binding
    }
    bytes += source[cursor...]
    updated.fingerprint = String(decoding: bytes, as: UTF8.self)
    return updated
  }
  private static func rewritten(_ table: TableModel, targets: [TableModel]) throws -> TableModel {
    var table = table
    for index in table.ledger.indices {
      let entry = try rewrite(table.ledger[index], owner: table.id, targets: targets)
      table.ledger[index] = entry
      // An entry always has its owner's text; a missing owner is a stale model.
      switch entry.owner {
      case .rule(let column):
        guard let owner = table.columns.firstIndex(where: { $0.id == column }) else {
          throw TableCodecError.stalePatch
        }
        table.columns[owner].rule = entry.fingerprint
      case .cell(let row, let column):
        guard let owner = table.cells.firstIndex(where: { $0.row == row && $0.column == column })
        else { throw TableCodecError.stalePatch }
        table.cells[owner].source = entry.fingerprint
      }
    }
    return table
  }

  private func prosePatches(old: [TableModel], new: [TableModel]) throws -> [TableSourcePatch] {
    var visible: [TableModel] = []
    var patches: [TableSourcePatch] = []
    // Blocks occupy disjoint whole lines, so start lines are unique; keep the
    // first anyway rather than trapping.
    let starts = Dictionary(
      blocks.map { ($0.physicalLines.lowerBound, $0) }, uniquingKeysWith: { first, _ in first })
    let tableLines = IndexSet(blocks.flatMap { Array($0.physicalLines) })
    for index in lines.indices {
      let line = lines[index]
      if let block = starts[index], let table = block.table,
        let bound = old.first(where: { $0.id == table.id })
      {
        visible.append(bound)
      }
      if tableLines.contains(index) { continue }
      let syntax = LineSyntax(line.text)
      if case .divider = syntax {
        visible.removeAll()
        continue
      }
      guard case .calculation(_, _, let expression?, _) = syntax else { continue }
      let text = String(
        decoding: line.text.utf8.dropFirst(expression.lowerBound).prefix(
          expression.upperBound - expression.lowerBound), as: UTF8.self)
      guard let syntax = try? TableFormulaSyntax.discover(text, tableFormula: false) else {
        continue
      }
      // Bind one operand at a time: an unrelated unresolved operand must not
      // prevent a surviving bound reference on this line from following edits.
      for occurrence in syntax.references {
        let span = occurrence.range.lowerBound..<occurrence.range.upperBound
        let operand = String(
          decoding: text.utf8.dropFirst(span.lowerBound).prefix(span.count), as: UTF8.self)
        guard let discovered = try? TableFormulaSyntax.discover(operand, tableFormula: false),
          let references = try? discovered.bind(
            scope: TableFormulaScope(current: nil, visible: visible, inherited: [:])),
          let reference = references.first, let target = reference.target
        else { continue }
        var binding = TableBinding(
          id: target.hasBindingID ? .mint() : nil, operand: span, target: target,
          locks: reference.locks)
        if let oldTarget = old.first(where: { $0.id == target.table }),
          let newTarget = new.first(where: { $0.id == target.table })
        {
          binding = Self.surviving(binding, old: oldTarget, new: newTarget)
        }
        let replacement = try Self.rendered(binding, owner: nil, targets: new, original: operand)
        if !replacement.utf8.elementsEqual(operand.utf8) {
          let lower = line.range.lowerBound + expression.lowerBound + span.lowerBound
          patches.append(
            TableSourcePatch(
              utf8Range: lower..<(lower + span.count), expected: operand, replacement: replacement))
        }
      }
    }
    return patches
  }

  package func duplicateTable(_ id: TableID, named name: String, atUTF8 offset: Int) throws
    -> TableSourceEdit
  {
    let original = try Self.bound(model(id), visible: visible(at: id))
    try checkInsertion(atUTF8: offset)
    var visible: [TableModel] = []
    for line in lines where line.range.lowerBound < offset {
      if Self.divider(line.text) { visible.removeAll() }
      if let block = blocks.first(where: { $0.utf8Range.lowerBound == line.range.lowerBound }),
        let table = block.table
      {
        visible.append(table)
      }
    }
    var duplicated = Self.remapped([original])[0]
    duplicated.name = name
    // External targets must already be visible at the copy's insertion point.
    // Missing targets get deliberate missing identities rather than masquerading
    // as deleted while pointing at a still-live target elsewhere in the sheet.
    for entryIndex in duplicated.ledger.indices {
      for bindingIndex in duplicated.ledger[entryIndex].bindings.indices {
        var binding = duplicated.ledger[entryIndex].bindings[bindingIndex]
        if let target = binding.target.table, target != duplicated.id,
          !visible.contains(where: { $0.id == target }), !binding.isDeleted
        {
          binding = Self.brokenExternal(binding)
        }
        duplicated.ledger[entryIndex].bindings[bindingIndex] = binding
      }
    }
    duplicated = try Self.rewritten(duplicated, targets: visible + [duplicated])
    let block = try Self.canonicalBlock(for: duplicated)
    let edit = TableSourceEdit(
      patches: [TableSourcePatch(utf8Range: offset..<offset, expected: "", replacement: block)],
      createdTable: duplicated.id)
    try checked(edit)
    return edit
  }

  /// A new sheet source; every copied table/axis/binding gets a new identity,
  /// and internal references across the complete copied set are rebound.
  package func duplicateSheet() throws -> TableSourceEdit {
    let old = try blocks.compactMap(\.table).map { try Self.bound($0, visible: visible(at: $0.id)) }
    var copies = Self.remapped(old)
    for index in copies.indices {
      copies[index] = try Self.rewritten(copies[index], targets: copies)
    }
    var patches: [TableSourcePatch] = []
    for block in blocks {
      guard let table = block.table, let index = old.firstIndex(where: { $0.id == table.id }) else {
        continue
      }
      patches.append(
        TableSourcePatch(
          utf8Range: block.utf8Range, expected: block.rawSource,
          replacement: try Self.canonicalBlock(
            for: copies[index],
            lineEnding: lines[block.physicalLines.lowerBound].terminator ?? .lineFeed)))
    }
    // Display names and coordinates are unchanged, so qualified prose operands
    // continue to resolve to the copied set. Broken prose tokens keep originals.
    var copiedIdentities: [UUID: UUID] = [:]
    for (original, copy) in zip(old, copies) {
      copiedIdentities[original.id.uuid] = copy.id.uuid
      for (column, copiedColumn) in zip(original.columns, copy.columns) {
        copiedIdentities[column.id.uuid] = copiedColumn.id.uuid
      }
    }
    let edit = TableSourceEdit(
      patches: patches, createdTable: nil, copiedIdentities: copiedIdentities)
    try checked(edit)
    return edit
  }

  private static func brokenExternal(_ original: TableBinding) -> TableBinding {
    var binding = original
    binding.isDeleted = true
    switch original.target {
    case .cell(let table, _, let column):
      binding.target = .cell(table: table, row: .mint(), column: column)
    case .rectangle(let table, _, let columns):
      let retainedColumns: [ColumnID]
      switch columns {
      case .interval(let a, let b): retainedColumns = a == b ? [a] : [a, b]
      case .retained(let ids): retainedColumns = ids
      }
      binding.target = .rectangle(
        table: table, rows: .retained([.mint()]), columns: .retained(retainedColumns))
    case .columns(let table, _): binding.target = .columns(table: table, .retained([.mint()]))
    case .rows(let table, _): binding.target = .rows(table: table, .retained([.mint()]))
    case .namedColumn(let table, _): binding.target = .namedColumn(table: table, column: .mint())
    case .currentRow: break
    }
    return binding
  }
  private static func remapped(_ originals: [TableModel]) -> [TableModel] {
    let copied = Set(originals.map(\.id))
    var mapping: [UUID: UUID] = [:]
    func uuid(_ id: UUID) -> UUID {
      if let mapped = mapping[id] { return mapped }
      let new = UUID()
      mapping[id] = new
      return new
    }
    func tableID(_ id: TableID) -> TableID { copied.contains(id) ? TableID(uuid(id.uuid)) : id }
    func axis<K>(_ axis: TableMembership<TableIdentity<K>>) -> TableMembership<TableIdentity<K>> {
      switch axis {
      case .interval(let a, let b):
        return .interval(first: .init(uuid(a.uuid)), last: .init(uuid(b.uuid)))
      case .retained(let ids): return .retained(ids.map { .init(uuid($0.uuid)) })
      }
    }
    return originals.map { original in
      var table = original
      table.id = tableID(original.id)
      table.rows = original.rows.map { RowID(uuid($0.uuid)) }
      table.columns = original.columns.map { column in
        var column = column
        column.id = ColumnID(uuid(column.id.uuid))
        return column
      }
      table.cells = original.cells.map { cell in
        var cell = cell
        cell.row = RowID(uuid(cell.row.uuid))
        cell.column = ColumnID(uuid(cell.column.uuid))
        return cell
      }
      table.ledger = original.ledger.map { entry in
        var entry = entry
        switch entry.owner {
        case .cell(let row, let column):
          entry.owner = .cell(row: RowID(uuid(row.uuid)), column: ColumnID(uuid(column.uuid)))
        case .rule(let column): entry.owner = .rule(column: ColumnID(uuid(column.uuid)))
        }
        entry.bindings = entry.bindings.map { binding in
          var binding = binding
          if let id = binding.id { binding.id = TableBindingID(uuid(id.uuid)) }
          if binding.target.table == nil || copied.contains(binding.target.table!) {
            switch binding.target {
            case .cell(let t, let r, let c):
              binding.target = .cell(
                table: tableID(t), row: r.map { RowID(uuid($0.uuid)) },
                column: ColumnID(uuid(c.uuid)))
            case .rectangle(let t, let r, let c):
              binding.target = .rectangle(table: tableID(t), rows: axis(r), columns: axis(c))
            case .columns(let t, let c): binding.target = .columns(table: tableID(t), axis(c))
            case .rows(let t, let r): binding.target = .rows(table: tableID(t), axis(r))
            case .namedColumn(let t, let c):
              binding.target = .namedColumn(table: tableID(t), column: ColumnID(uuid(c.uuid)))
            case .currentRow(let c): binding.target = .currentRow(column: ColumnID(uuid(c.uuid)))
            }
          }
          return binding
        }
        return entry
      }
      return table
    }
  }
}

/// Deleting a table, by command or by deleting its block's text, breaks every
/// reference to it in the same edit: a binding in another table becomes its
/// deleted marker (ranges keep their original members) and a prose operand
/// becomes the marker a deleted target has. A marker names identities, so a
/// later table with the same name never revives it.
extension TableSourceDocument {
  /// Removes the table's block, with its lines. References to it break, and
  /// line references around the removed lines follow their targets, exactly
  /// as deleting the block's text in the editor does.
  package func deleteTable(
    _ id: TableID, configuration: LexingConfiguration = .englishUnitedStates
  ) throws -> TableSourceEdit {
    guard let block = blocks.first(where: { $0.table?.id == id }) else {
      throw TableTransformError.missingTable
    }
    let text = source
    let utf8 = text.utf8
    func utf16(_ offset: Int) -> Int {
      text.utf16.distance(
        from: text.utf16.startIndex, to: utf8.index(utf8.startIndex, offsetBy: offset))
    }
    let removed = NSRange(
      location: utf16(block.utf8Range.lowerBound),
      length: utf16(block.utf8Range.upperBound) - utf16(block.utf8Range.lowerBound))
    let rewrites = LineReferenceRenumbering.edits(
      replacing: removed, in: text, with: "", configuration: configuration)
    // Rewrites are in the text after the removal; none is inside it.
    let units = Array(text.utf16)
    func utf8Offset(_ utf16: Int) -> Int {
      String(decoding: units[..<utf16], as: UTF16.self).utf8.count
    }
    var patches = [
      TableSourcePatch(utf8Range: block.utf8Range, expected: block.rawSource, replacement: "")
    ]
    for rewrite in rewrites {
      let shift = rewrite.range.location >= removed.location ? removed.length : 0
      let lower = utf8Offset(rewrite.range.location + shift)
      let upper = utf8Offset(rewrite.range.upperBound + shift)
      patches.append(
        TableSourcePatch(
          utf8Range: lower..<upper,
          expected: String(decoding: Array(utf8)[lower..<upper], as: UTF8.self),
          replacement: rewrite.replacement))
    }
    let edit = TableSourceEdit(
      patches: patches.sorted { $0.utf8Range.lowerBound < $1.utf8Range.lowerBound },
      createdTable: nil)
    try checked(edit)
    return edit
  }

  /// `table` with every live binding to a removed table deleted: its
  /// operand becomes the marker, and the owner's source, fingerprint and
  /// later spans change together. Other operands are left byte for byte.
  static func breaking(
    _ table: TableModel, removed: [TableID: TableModel], visible: [TableModel]
  ) -> TableModel {
    // A freshly typed formula can have no persisted ledger. Bind it against
    // the pre-deletion scope, then persist only owners that deletion rewrites.
    // Unrelated owners keep their source and ledger bytes unchanged.
    let bound = (try? Self.bound(table, visible: visible)) ?? table
    var changed = table
    for original in bound.ledger {
      var entry = original
      guard
        entry.bindings.contains(where: {
          !$0.isDeleted && $0.target.table.map { removed[$0] != nil } == true
        })
      else { continue }
      let source = Array(entry.fingerprint.utf8)
      var bytes: [UInt8] = []
      var cursor = 0
      for position in entry.bindings.indices {
        var binding = entry.bindings[position]
        bytes += source[cursor..<binding.operand.lowerBound]
        var replacement = Array(source[binding.operand])
        if !binding.isDeleted, let target = binding.target.table, let old = removed[target] {
          var gone = old
          gone.rows = []
          gone.columns = []
          binding = surviving(binding, old: old, new: gone)
          replacement = Array(binding.brokenMarker.utf8)
        }
        let start = bytes.count
        bytes += replacement
        cursor = binding.operand.upperBound
        binding.operand = start..<bytes.count
        entry.bindings[position] = binding
      }
      bytes += source[cursor...]
      entry.fingerprint = String(decoding: bytes, as: UTF8.self)
      if let index = changed.ledger.firstIndex(where: { $0.owner == entry.owner }) {
        changed.ledger[index] = entry
      } else {
        changed.ledger.append(entry)
      }
      switch entry.owner {
      case .rule(let column):
        if let owner = changed.columns.firstIndex(where: { $0.id == column }) {
          changed.columns[owner].rule = entry.fingerprint
        }
      case .cell(let row, let column):
        if let owner = changed.cells.firstIndex(where: { $0.row == row && $0.column == column }) {
          changed.cells[owner].source = entry.fingerprint
        }
      }
    }
    return changed
  }

  /// Prose operands that read a removed table, each with the UTF-8 range of
  /// the operand in its line's text and the marker replacing it. Lines
  /// `skips` rejects, such as ones an edit touches, are left alone.
  func proseBreaks(
    removed: [TableID: TableModel], configuration: LexingConfiguration,
    skips: (Int) -> Bool
  ) -> [(line: Int, range: Range<Int>, marker: String)] {
    var visible: [TableModel] = []
    var breaks: [(line: Int, range: Range<Int>, marker: String)] = []
    let starts = Dictionary(
      blocks.map { ($0.physicalLines.lowerBound, $0) }, uniquingKeysWith: { first, _ in first })
    let tableLines = IndexSet(blocks.flatMap { Array($0.physicalLines) })
    for index in lines.indices {
      let text = lines[index].text
      if let table = starts[index]?.table { visible.append(table) }
      if tableLines.contains(index) { continue }
      let syntax = LineSyntax(text)
      if case .divider = syntax {
        visible.removeAll()
        continue
      }
      guard case .calculation(_, _, let expression?, _) = syntax, !skips(index),
        text.utf8.contains(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "!") })
      else { continue }
      let body = String(
        decoding: text.utf8.dropFirst(expression.lowerBound).prefix(expression.utf8Length),
        as: UTF8.self)
      guard
        let found = try? TableFormulaSyntax.discover(
          body, tableFormula: false, configuration: configuration)
      else { continue }
      for occurrence in found.references {
        let span = occurrence.range.lowerBound..<occurrence.range.upperBound
        let operand = String(
          decoding: body.utf8.dropFirst(span.lowerBound).prefix(span.count), as: UTF8.self)
        guard
          let single = try? TableFormulaSyntax.discover(
            operand, tableFormula: false, configuration: configuration),
          let reference = try? single.bind(
            scope: TableFormulaScope(current: nil, visible: visible, inherited: [:])
          ).first,
          !reference.deleted, let target = reference.target, let table = target.table,
          let old = removed[table]
        else { continue }
        var gone = old
        gone.rows = []
        gone.columns = []
        let binding = Self.surviving(
          TableBinding(
            id: target.hasBindingID ? .mint() : nil, operand: span, target: target,
            locks: reference.locks), old: old, new: gone)
        breaks.append(
          (
            index,
            (expression.lowerBound + span.lowerBound)..<(expression.lowerBound + span.upperBound),
            binding.brokenMarker
          ))
      }
    }
    return breaks
  }
}
