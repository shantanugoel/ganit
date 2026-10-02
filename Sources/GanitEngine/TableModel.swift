import Foundation

enum TableIdentityKind: Sendable {}
enum RowIdentityKind: Sendable {}
enum ColumnIdentityKind: Sendable {}
enum BindingIdentityKind: Sendable {}

/// A durable identity. It is a UUID, never a dictionary position, physical
/// row index or session `LineID`, and is minted only by deliberate creation,
/// duplication or repair, never while parsing.
struct TableIdentity<Kind: Sendable>: Hashable, Sendable {
  let uuid: UUID
  init(_ uuid: UUID) { self.uuid = uuid }
  static func mint() -> Self { Self(UUID()) }

  /// Accepts only the canonical lowercase 36-character spelling, because
  /// broken-reference markers compare identities textually.
  init?(canonical text: String) {
    let bytes = Array(text.utf8)
    guard bytes.count == 36 else { return nil }
    for (offset, byte) in bytes.enumerated() {
      let valid =
        [8, 13, 18, 23].contains(offset)
        ? byte == UInt8(ascii: "-")
        : (48...57).contains(byte) || (97...102).contains(byte)
      guard valid else { return nil }
    }
    guard let uuid = UUID(uuidString: text) else { return nil }
    self.uuid = uuid
  }

  /// The canonical lowercase spelling.
  var string: String { uuid.uuidString.lowercased() }
}
typealias TableID = TableIdentity<TableIdentityKind>
typealias RowID = TableIdentity<RowIdentityKind>
typealias ColumnID = TableIdentity<ColumnIdentityKind>
typealias TableBindingID = TableIdentity<BindingIdentityKind>

/// How a column reads literal (non-formula) input. A leading `=` always
/// marks a formula, whatever the policy.
enum TableInputPolicy: String, Hashable, Sendable {
  /// Complete supported literals: numbers, percentages, money, quantities
  /// and temporal values.
  case value
  /// Literal text, never interpreted.
  case text
}

/// The totals-footer summary for one column. The footer reads data rows only.
enum TableTotal: String, Hashable, Sendable, CaseIterable {
  case sum, average, median, min, max, count
}

struct TableColumn: Hashable, Sendable {
  var id: ColumnID
  /// Literal text; never parsed as units, variables or syntax.
  var header: String
  var input: TableInputPolicy
  /// The default unit for value literals entered without one.
  var unit: String?
  /// The default ISO currency code for value literals entered without one.
  var currency: String?
  /// A formula inherited by every data cell without an override record.
  var rule: String?
  var total: TableTotal?

  init(
    id: ColumnID, header: String, input: TableInputPolicy = .value, unit: String? = nil,
    currency: String? = nil, rule: String? = nil, total: TableTotal? = nil
  ) {
    self.id = id
    self.header = header
    self.input = input
    self.unit = unit
    self.currency = currency
    self.rule = rule
    self.total = total
  }
}

/// A populated data cell. A cell without a record is blank, or inherits its
/// column's rule. An override replaces the rule for one cell; its source may
/// be empty, which is a blank override, distinct from deleting the record.
struct TableCell: Hashable, Sendable {
  var row: RowID
  var column: ColumnID
  var source: String
  var isOverride: Bool

  init(row: RowID, column: ColumnID, source: String, isOverride: Bool = false) {
    self.row = row
    self.column = column
    self.source = source
    self.isOverride = isOverride
  }

  var isFormula: Bool { source.hasPrefix("=") }
}

/// What owns a formula's bindings: a data cell, or a column rule. Headers
/// never own formulas.
enum TableFormulaOwner: Hashable, Sendable {
  case cell(row: RowID, column: ColumnID)
  case rule(column: ColumnID)

  var column: ColumnID {
    switch self {
    case .cell(_, let column), .rule(let column): return column
    }
  }
}

/// Membership on one axis of a range. Live ranges are inclusive intervals over
/// the target table's ordered IDs; a deleted range keeps its original ordered
/// members so those IDs never leave the identity dictionary.
enum TableMembership<ID: Hashable & Sendable>: Hashable, Sendable {
  case interval(first: ID, last: ID)
  case retained([ID])
}

/// The identity a bound operand reads, by form. Forms differ because copy,
/// fill and structural edits transform them differently (ADR 0016).
enum TableReferenceTarget: Hashable, Sendable {
  /// `B2`, `$B$2`, `Rates!B2`; a `nil` row is the header cell (`B1`).
  case cell(table: TableID, row: RowID?, column: ColumnID)
  /// `B2:D6`, over data rows only.
  case rectangle(table: TableID, rows: TableMembership<RowID>, columns: TableMembership<ColumnID>)
  /// `C:C` or `C:E`: every data row of these columns.
  case columns(table: TableID, TableMembership<ColumnID>)
  /// `2:2` or `2:4`: every column of these data rows.
  case rows(table: TableID, TableMembership<RowID>)
  /// `Items[Amount]`: the column's current data membership. Never translates.
  case namedColumn(table: TableID, column: ColumnID)
  /// `[@Qty]`: the owner's own row in a column of the same table.
  case currentRow(column: ColumnID)

  /// The frozen wire spelling of the form.
  var kind: String {
    switch self {
    case .cell: return "cell"
    case .rectangle: return "rect"
    case .columns: return "cols"
    case .rows: return "rows"
    case .namedColumn: return "named"
    case .currentRow: return "current"
    }
  }

  /// Copy locks per endpoint axis: `[row, column]` for a cell, `[start row,
  /// start column, end row, end column]` for a rectangle, `[start, end]` on
  /// the one axis of row and column ranges, none for structured forms.
  var lockCount: Int {
    switch self {
    case .cell, .columns, .rows: return 2
    case .rectangle: return 4
    case .namedColumn, .currentRow: return 0
    }
  }

  /// Every form except a scalar cell has a binding ID, which its broken
  /// marker names because it has no single target cell.
  var hasBindingID: Bool {
    if case .cell = self { return false }
    return true
  }

  /// The target table, or `nil` for the owner's own table.
  var table: TableID? {
    switch self {
    case .cell(let table, _, _), .rectangle(let table, _, _), .columns(let table, _),
      .rows(let table, _), .namedColumn(let table, _):
      return table
    case .currentRow: return nil
    }
  }
}

/// One bound operand occurrence in its owner's formula.
struct TableBinding: Hashable, Sendable {
  var id: TableBindingID?
  /// The operand's UTF-8 span within the owner's exact source, `=` included.
  var operand: Range<Int>
  var target: TableReferenceTarget
  var locks: [Bool]
  /// A deleted binding's operand is its persisted broken marker.
  var isDeleted: Bool

  init(
    id: TableBindingID? = nil, operand: Range<Int>, target: TableReferenceTarget,
    locks: [Bool] = [], isDeleted: Bool = false
  ) {
    self.id = id
    self.operand = operand
    self.target = target
    self.locks = locks
    self.isDeleted = isDeleted
  }

  /// The exact ADR 0016 marker a deleted binding's operand must spell.
  var brokenMarker: String {
    if case .cell(let table, let row, let column) = target {
      return "#REF!{\(table.string)/\(row?.string ?? "header")/\(column.string)}"
    }
    return "#REF!{range:\(id?.string ?? "")}"
  }
}

/// The bindings of one formula owner. The fingerprint is the owner's exact
/// source when the ledger was written: if the source changes without its
/// ledger, the ledger is stale and no binding is reused by occurrence order.
struct TableLedgerEntry: Hashable, Sendable {
  var owner: TableFormulaOwner
  var fingerprint: String
  /// In operand order; a binding's index is its occurrence ordinal.
  var bindings: [TableBinding]
}

/// A validated table projection. Canonical source and its syntax tree are
/// kept by `TableSourceBlock`; this derived model is never saved instead.
struct TableModel: Hashable, Sendable {
  var id: TableID
  var name: String
  var columns: [TableColumn]
  var rows: [RowID]
  var cells: [TableCell]
  var ledger: [TableLedgerEntry]

  init(
    id: TableID, name: String, columns: [TableColumn], rows: [RowID],
    cells: [TableCell] = [], ledger: [TableLedgerEntry] = []
  ) {
    self.id = id
    self.name = name
    self.columns = columns
    self.rows = rows
    self.cells = cells
    self.ledger = ledger
  }

  /// A new table with freshly minted identities; the only place IDs are
  /// created besides explicit duplication and repair.
  static func creating(
    name: String, headers: [(String, TableInputPolicy)], rowCount: Int
  ) -> TableModel {
    TableModel(
      id: .mint(), name: name,
      columns: headers.map { TableColumn(id: .mint(), header: $0.0, input: $0.1) },
      rows: (0..<rowCount).map { _ in .mint() })
  }

  /// Data cells with content: non-empty records, plus rule cells without an
  /// override. These count against the sheet's populated-cell ceiling.
  var populatedCellCount: Int {
    var records: [ColumnID: Int] = [:]
    var count = 0
    for cell in cells {
      records[cell.column, default: 0] += 1
      if !cell.source.isEmpty { count += 1 }
    }
    for column in columns where column.rule != nil {
      count += rows.count - (records[column.id] ?? 0)
    }
    return count
  }
}

/// Positions of a table's live rows and columns, built once per check.
struct TableAxes {
  let rows: [RowID: Int]
  let columns: [ColumnID: Int]

  init(_ table: TableModel) {
    rows = Dictionary(uniqueKeysWithValues: table.rows.enumerated().map { ($1, $0) })
    columns = Dictionary(uniqueKeysWithValues: table.columns.enumerated().map { ($1.id, $0) })
  }
}

/// A block-level failure, reported as a diagnostic; source is never changed.
struct TableBlockError: Error, Equatable, Sendable {
  let code: TableSourceDiagnostic.Code
  /// Developer-facing detail without user text; UI presents `code`.
  let detail: String
}

private func failure(_ code: TableSourceDiagnostic.Code, _ detail: String) -> TableBlockError {
  TableBlockError(code: code, detail: detail)
}

// MARK: - Validation

extension TableModel {
  /// Checks every rule that the block can decide alone. Targets in other
  /// tables are checked by `TableSourceDocument` against the whole sheet.
  func validate() throws {
    try Self.checkName(name, "Table name")
    guard name.lowercased() != "sheet" else {
      throw failure(.invalidRecord, "`sheet` is reserved as a table name")
    }
    guard !columns.isEmpty else { throw failure(.invalidRecord, "A table needs a column") }
    var roles: [UUID: String] = [id.uuid: "table"]
    func claim(_ uuid: UUID, _ role: String) throws {
      guard roles.updateValue(role, forKey: uuid) == nil else {
        throw failure(.duplicateIdentity, "An identity is used twice in a table")
      }
    }
    for row in rows { try claim(row.uuid, "row") }
    var headers: Set<String> = []
    for column in columns {
      try claim(column.id.uuid, "column")
      try Self.checkName(column.header, "Column header")
      guard headers.insert(column.header.lowercased()).inserted else {
        throw failure(.invalidRecord, "Column headers must be unique ignoring case")
      }
      try Self.check(column)
    }

    let axes = TableAxes(self)
    let rowIndex = axes.rows
    let columnIndex = axes.columns
    var sources: [TableFormulaOwner: String] = [:]
    for column in columns {
      if let rule = column.rule { sources[.rule(column: column.id)] = rule }
    }
    for cell in cells {
      guard rowIndex[cell.row] != nil, let column = columnIndex[cell.column] else {
        throw failure(.orphanTarget, "A cell names a row or column the table does not have")
      }
      let hasRule = columns[column].rule != nil
      if cell.isOverride {
        guard hasRule else {
          throw failure(.invalidRecord, "An override needs a column rule")
        }
      } else {
        guard !hasRule else {
          throw failure(.invalidRecord, "A cell in a rule column must be an override")
        }
        guard !cell.source.isEmpty else {
          throw failure(.invalidRecord, "A blank cell has no record")
        }
      }
      let owner = TableFormulaOwner.cell(row: cell.row, column: cell.column)
      guard sources.updateValue(cell.source, forKey: owner) == nil else {
        throw failure(.duplicateIdentity, "Two records describe one cell")
      }
    }

    var owners: Set<TableFormulaOwner> = []
    for entry in ledger {
      guard owners.insert(entry.owner).inserted else {
        throw failure(.staleBinding, "Two ledger entries describe one owner")
      }
      guard let source = sources[entry.owner], source.hasPrefix("=") else {
        throw failure(.staleBinding, "A ledger entry's owner is not a formula")
      }
      guard source.utf8.elementsEqual(entry.fingerprint.utf8) else {
        throw failure(.staleBinding, "A ledger fingerprint does not match its formula")
      }
      guard !entry.bindings.isEmpty else {
        throw failure(.invalidRecord, "A ledger entry needs a binding")
      }
      let bytes = Array(source.utf8)
      var end = 1
      for binding in entry.bindings {
        let span = binding.operand
        guard span.lowerBound >= end, !span.isEmpty, span.upperBound <= bytes.count,
          isUTF8Boundary(span.lowerBound, bytes), isUTF8Boundary(span.upperBound, bytes)
        else {
          throw failure(.staleBinding, "Binding operands must be ordered spans after `=`")
        }
        end = span.upperBound
        guard binding.locks.count == binding.target.lockCount,
          (binding.id != nil) == binding.target.hasBindingID,
          binding.target.hasMembershipShape(deleted: binding.isDeleted)
        else { throw failure(.malformed, "A binding has the wrong shape for its kind") }
        for members in binding.target.retainedMembers where Set(members).count != members.count {
          throw failure(.duplicateIdentity, "A retained membership repeats an identity")
        }
        if let bindingID = binding.id { try claim(bindingID.uuid, "binding") }
        let operand = bytes[span]
        if binding.isDeleted {
          guard operand.elementsEqual(binding.brokenMarker.utf8) else {
            throw failure(.staleBinding, "A deleted binding's operand is not its marker")
          }
        } else if operand.starts(with: "#REF!".utf8) {
          throw failure(.staleBinding, "A live binding's operand is a broken marker")
        }
        if binding.target.table == nil || binding.target.table == id {
          try checkTarget(binding, axes)
        }
      }
    }
    // Deleted and external target IDs keep one role each and never take
    // the role of a live identity.
    var targetRoles: [UUID: String] = [:]
    for entry in ledger {
      for binding in entry.bindings {
        for (uuid, role) in binding.target.identities(owner: id) {
          if let known = roles[uuid] ?? targetRoles[uuid], known != role {
            throw failure(.duplicateIdentity, "An identity has two roles")
          }
          if roles[uuid] == nil { targetRoles[uuid] = role }
        }
      }
    }
  }

  /// Checks a target in this table: a live target must exist with ordered
  /// interval endpoints; a deleted one must really be gone, so a marker never
  /// hides a target that could be bound again.
  func checkTarget(_ binding: TableBinding, _ axes: TableAxes) throws {
    let rowIndex = axes.rows
    let columnIndex = axes.columns
    func live<ID>(_ membership: TableMembership<ID>, _ index: [ID: Int]) -> Bool? {
      switch membership {
      case .interval(let first, let last):
        guard let start = index[first], let end = index[last] else { return nil }
        return start <= end
      case .retained: return nil
      }
    }
    func gone<ID>(_ membership: TableMembership<ID>, _ index: [ID: Int]) -> Bool {
      if case .retained(let members) = membership {
        return members.allSatisfy { index[$0] == nil }
      }
      return false
    }
    let present: Bool
    var ordered = true
    switch binding.target {
    case .cell(_, let row, let column):
      present = (row.map { rowIndex[$0] != nil } ?? true) && columnIndex[column] != nil
    case .rectangle(_, let rowsAxis, let columnsAxis):
      if binding.isDeleted {
        present = !(gone(rowsAxis, rowIndex) || gone(columnsAxis, columnIndex))
      } else {
        let rowsLive = live(rowsAxis, rowIndex)
        let columnsLive = live(columnsAxis, columnIndex)
        present = rowsLive != nil && columnsLive != nil
        ordered = rowsLive != false && columnsLive != false
      }
    case .columns(_, let axis):
      present = binding.isDeleted ? !gone(axis, columnIndex) : live(axis, columnIndex) != nil
      ordered = binding.isDeleted || live(axis, columnIndex) != false
    case .rows(_, let axis):
      present = binding.isDeleted ? !gone(axis, rowIndex) : live(axis, rowIndex) != nil
      ordered = binding.isDeleted || live(axis, rowIndex) != false
    case .namedColumn(_, let column), .currentRow(let column):
      present = columnIndex[column] != nil
    }
    if binding.isDeleted {
      guard !present else {
        throw failure(.staleBinding, "A deleted binding's target still exists")
      }
    } else {
      guard present else { throw failure(.orphanTarget, "A binding's target does not exist") }
      guard ordered else {
        throw failure(.invalidRecord, "A range's first endpoint follows its last")
      }
    }
  }

  private static func checkName(_ text: String, _ what: String) throws {
    guard !text.isEmpty, text.first?.isWhitespace == false, text.last?.isWhitespace == false,
      !text.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}"
      })
    else {
      throw failure(
        .invalidRecord, "\(what) must be non-empty single-line text without outer spaces")
    }
  }

  private static func check(_ column: TableColumn) throws {
    if let rule = column.rule, !rule.hasPrefix("=") {
      throw failure(.invalidRecord, "A column rule is a formula starting with `=`")
    }
    if column.unit != nil || column.currency != nil {
      guard column.input == .value, column.unit == nil || column.currency == nil else {
        throw failure(.invalidRecord, "Only value columns have one unit or currency default")
      }
    }
    if let unit = column.unit { try checkName(unit, "A unit default") }
    if let currency = column.currency {
      guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
        throw failure(.invalidRecord, "A currency default is an uppercase ISO code")
      }
    }
  }
}

extension TableReferenceTarget {
  /// Live ranges are intervals; deleted ranges retain their unique,
  /// non-empty original members.
  func hasMembershipShape(deleted: Bool) -> Bool {
    func valid<ID>(_ membership: TableMembership<ID>) -> Bool {
      switch membership {
      case .interval: return !deleted
      case .retained(let ids): return deleted && !ids.isEmpty
      }
    }
    switch self {
    case .rectangle(_, let rows, let columns): return valid(rows) && valid(columns)
    case .columns(_, let axis): return valid(axis)
    case .rows(_, let axis): return valid(axis)
    case .cell, .namedColumn, .currentRow: return true
    }
  }

  /// A deleted range's retained member lists, one per axis.
  var retainedMembers: [[UUID]] {
    func members<ID>(_ membership: TableMembership<TableIdentity<ID>>) -> [[UUID]] {
      if case .retained(let ids) = membership { return [ids.map(\.uuid)] }
      return []
    }
    switch self {
    case .rectangle(_, let rows, let columns): return members(rows) + members(columns)
    case .columns(_, let axis): return members(axis)
    case .rows(_, let axis): return members(axis)
    case .cell, .namedColumn, .currentRow: return []
    }
  }

  /// Every identity the target names, with its role, for role consistency.
  func identities(owner: TableID) -> [(UUID, String)] {
    func members<ID>(_ membership: TableMembership<ID>) -> [ID] {
      switch membership {
      case .interval(let first, let last): return [first, last]
      case .retained(let ids): return ids
      }
    }
    switch self {
    case .cell(let table, let row, let column):
      return [(table.uuid, "table"), (column.uuid, "column")]
        + (row.map { [($0.uuid, "row")] } ?? [])
    case .rectangle(let table, let rows, let columns):
      return [(table.uuid, "table")] + members(rows).map { ($0.uuid, "row") }
        + members(columns).map { ($0.uuid, "column") }
    case .columns(let table, let columns):
      return [(table.uuid, "table")] + members(columns).map { ($0.uuid, "column") }
    case .rows(let table, let rows):
      return [(table.uuid, "table")] + members(rows).map { ($0.uuid, "row") }
    case .namedColumn(let table, let column):
      return [(table.uuid, "table"), (column.uuid, "column")]
    case .currentRow(let column):
      return [(owner.uuid, "table"), (column.uuid, "column")]
    }
  }
}
