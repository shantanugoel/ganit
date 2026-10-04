import Foundation

/// Version 1 table payload codec, frozen in docs/storage/table-blocks.md.
///
/// Reading decodes a lossless `TableJSON` tree into a validated projection;
/// the tree and canonical bytes stay authoritative. Writing emits the
/// canonical serialization only for deliberately created blocks: existing
/// blocks are edited by span patches, never re-encoded.
extension TableModel {
  /// Decodes and validates a version 1 payload. Unknown keys are ignored here
  /// and retained in source.
  init(payload json: TableJSON) throws {
    func malformed(_ detail: String) -> TableBlockError {
      TableBlockError(code: .malformed, detail: detail)
    }
    func required(_ node: TableJSON, _ key: String) throws -> TableJSON {
      guard let field = node[key] else { throw malformed("Missing field `\(key)`") }
      return field
    }
    func string(_ node: TableJSON?, _ what: String) throws -> String {
      guard let text = node?.string else { throw malformed("\(what) must be a string") }
      return text
    }
    func array(_ node: TableJSON?, _ what: String) throws -> [TableJSON] {
      guard let items = node?.array else { throw malformed("\(what) must be an array") }
      return items
    }
    func object(_ node: TableJSON, _ what: String) throws -> TableJSON {
      guard node.members != nil else { throw malformed("\(what) must be an object") }
      return node
    }
    func trueFlag(_ node: TableJSON?, _ what: String) throws -> Bool {
      guard let node else { return false }
      guard node.value == .bool(true) else { throw malformed("\(what) is present only as true") }
      return true
    }

    _ = try object(json, "The payload")
    var ids: [UUID] = []
    var seen: Set<UUID> = []
    for node in try array(required(json, "ids"), "`ids`") {
      guard let id = TableID(canonical: try string(node, "An identity")) else {
        throw malformed("Identities are canonical lowercase UUIDs")
      }
      guard seen.insert(id.uuid).inserted else {
        throw TableBlockError(code: .duplicateIdentity, detail: "The identity dictionary repeats")
      }
      ids.append(id.uuid)
    }
    func pointer(_ node: TableJSON?) throws -> UUID {
      guard let index = node?.index, index < ids.count else {
        throw malformed("Invalid identity pointer")
      }
      return ids[index]
    }
    func pair(_ node: TableJSON?, _ what: String, nullableFirst: Bool) throws -> (UUID?, UUID) {
      let items = try array(node, what)
      guard items.count == 2 else { throw malformed("\(what) has two pointers") }
      if nullableFirst, items[0].isNull { return (nil, try pointer(items[1])) }
      return (try pointer(items[0]), try pointer(items[1]))
    }
    func members(_ node: TableJSON) throws -> [UUID] {
      let items = try array(node, "A retained membership")
      guard !items.isEmpty else { throw malformed("A retained membership is non-empty") }
      let values = try items.map(pointer)
      guard Set(values).count == values.count else {
        throw TableBlockError(code: .duplicateIdentity, detail: "A membership repeats an ID")
      }
      return values
    }
    func membership<Kind>(_ first: TableJSON, _ last: TableJSON?, deleted: Bool) throws
      -> TableMembership<TableIdentity<Kind>>
    {
      if deleted { return .retained(try members(first).map(TableIdentity.init)) }
      guard let last else { throw malformed("A range has two endpoints") }
      return .interval(first: .init(try pointer(first)), last: .init(try pointer(last)))
    }

    id = TableID(try pointer(required(json, "t")))
    name = try string(required(json, "n"), "`n`")
    columns = try array(required(json, "c"), "`c`").map { node in
      let node = try object(node, "A column")
      guard let input = TableInputPolicy(rawValue: try string(required(node, "p"), "`p`")) else {
        throw malformed("Input policy is `value` or `text`")
      }
      var total: TableTotal?
      if let field = node["z"] {
        guard let value = TableTotal(rawValue: try string(field, "`z`")) else {
          throw malformed("Unknown total")
        }
        total = value
      }
      var column = TableColumn(
        id: ColumnID(try pointer(required(node, "i"))),
        header: try string(required(node, "h"), "`h`"), input: input,
        unit: try node["u"].map { try string($0, "`u`") },
        currency: try node["m"].map { try string($0, "`m`") },
        rule: try node["f"].map { try string($0, "`f`") }, total: total)
      if let digits = node["percent"] {
        guard let n = digits.index, (0...12).contains(n) else {
          throw malformed("Percentage decimals must be 0 to 12")
        }
        column.percentageDecimals = n
      }
      column.reviewSort = try node["sort"].map { try string($0, "`sort`") }
      if let sort = column.reviewSort, sort != "ascending", sort != "descending" {
        throw malformed("Unknown sort order")
      }
      column.reviewFilter = try node["filter"].map { try string($0, "`filter`") }
      column.frozen = try trueFlag(node["frozen"], "`frozen`")
      return column
    }
    rows = try array(required(json, "r"), "`r`").map { RowID(try pointer($0)) }
    cells = try array(required(json, "x"), "`x`").map { node in
      let node = try object(node, "A cell")
      let (row, column) = try pair(required(node, "a"), "A cell address", nullableFirst: false)
      return TableCell(
        row: RowID(row!), column: ColumnID(column),
        source: try string(required(node, "s"), "`s`"),
        isOverride: try trueFlag(node["o"], "`o`"))
    }
    ledger = try array(required(json, "b"), "`b`").map { node in
      let node = try object(node, "A ledger entry")
      let (row, column) = try pair(required(node, "o"), "An owner", nullableFirst: true)
      let owner: TableFormulaOwner =
        row.map { .cell(row: RowID($0), column: ColumnID(column)) }
        ?? .rule(column: ColumnID(column))
      let bindings = try array(required(node, "e"), "`e`").map { node in
        let node = try object(node, "A binding")
        let deleted = try trueFlag(node["d"], "`d`")
        let span = try array(required(node, "a"), "An operand span")
        guard span.count == 2, let lower = span[0].index, let upper = span[1].index,
          lower <= upper
        else { throw malformed("An operand span is two ordered offsets") }
        let t = try array(required(node, "t"), "A target")
        let kind = try string(required(node, "k"), "`k`")
        func arity(_ count: Int) throws {
          guard t.count == count else { throw malformed("A `\(kind)` target has \(count) items") }
        }
        let target: TableReferenceTarget
        switch kind {
        case "cell":
          try arity(3)
          target = .cell(
            table: TableID(try pointer(t[0])), row: t[1].isNull ? nil : RowID(try pointer(t[1])),
            column: ColumnID(try pointer(t[2])))
        case "rect":
          try arity(deleted ? 3 : 5)
          target = .rectangle(
            table: TableID(try pointer(t[0])),
            rows: try membership(t[1], deleted ? nil : t[3], deleted: deleted),
            columns: try membership(t[2], deleted ? nil : t[4], deleted: deleted))
        case "cols":
          try arity(deleted ? 2 : 3)
          target = .columns(
            table: TableID(try pointer(t[0])),
            try membership(t[1], deleted ? nil : t[2], deleted: deleted))
        case "rows":
          try arity(deleted ? 2 : 3)
          target = .rows(
            table: TableID(try pointer(t[0])),
            try membership(t[1], deleted ? nil : t[2], deleted: deleted))
        case "named":
          try arity(2)
          target = .namedColumn(
            table: TableID(try pointer(t[0])), column: ColumnID(try pointer(t[1])))
        case "current":
          try arity(1)
          target = .currentRow(column: ColumnID(try pointer(t[0])))
        default:
          throw malformed("Unknown binding kind")
        }
        if node["l"] != nil, target.lockCount == 0 {
          throw malformed("A `\(kind)` binding has no copy locks")
        }
        let locks = try node["l"].map {
          try array($0, "`l`").map { flag -> Bool in
            guard case .number(let text) = flag.value, text == "0" || text == "1" else {
              throw malformed("A copy lock is 0 or 1")
            }
            return text == "1"
          }
        }
        return TableBinding(
          id: try node["i"].map { TableBindingID(try pointer($0)) }, operand: lower..<upper,
          target: target, locks: locks ?? [], isDeleted: deleted)
      }
      return TableLedgerEntry(
        owner: owner, fingerprint: try string(required(node, "f"), "`f`"), bindings: bindings)
    }
    try validate()
  }
}

extension TableSourceDocument {
  /// The canonical block for a deliberately created or duplicated table:
  /// opener, one compact JSON payload line and closer, each followed by
  /// `lineEnding`. Keys use a fixed order and identities are interned in
  /// first-use order, so equal models always produce equal bytes.
  static func canonicalBlock(
    for table: TableModel, lineEnding: LineTerminator = .lineFeed, identityOrder: [UUID] = []
  ) throws -> String {
    try table.validate()
    guard Set(identityOrder).count == identityOrder.count else { throw TableCodecError.stalePatch }
    var ids = identityOrder
    var pointers = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    func pointer(_ uuid: UUID) -> String {
      if let index = pointers[uuid] { return String(index) }
      pointers[uuid] = ids.count
      ids.append(uuid)
      return String(ids.count - 1)
    }
    func list(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }
    func membership<Kind>(_ axis: TableMembership<TableIdentity<Kind>>) -> [String] {
      switch axis {
      case .interval(let first, let last): return [pointer(first.uuid), pointer(last.uuid)]
      case .retained(let members): return [list(members.map { pointer($0.uuid) })]
      }
    }
    // Records are emitted row-major and rules before cells, so record order
    // in the model does not change the bytes.
    let axes = TableAxes(table)
    func position(_ row: RowID?, _ column: ColumnID) -> (Int, Int) {
      (row.map { axes.rows[$0]! + 1 } ?? 0, axes.columns[column]!)
    }
    let sortedCells = table.cells.sorted {
      position($0.row, $0.column) < position($1.row, $1.column)
    }
    func owner(_ entry: TableLedgerEntry) -> (Int, Int) {
      switch entry.owner {
      case .cell(let row, let column): return position(row, column)
      case .rule(let column): return position(nil, column)
      }
    }
    let sortedLedger = table.ledger.sorted { owner($0) < owner($1) }
    _ = pointer(table.id.uuid)
    for column in table.columns { _ = pointer(column.id.uuid) }
    for row in table.rows { _ = pointer(row.uuid) }

    let columns = table.columns.map { column in
      var fields = [
        "\"i\":" + pointer(column.id.uuid), "\"h\":" + TableJSON.quoted(column.header),
        "\"p\":" + TableJSON.quoted(column.input.rawValue),
      ]
      if let unit = column.unit { fields.append("\"u\":" + TableJSON.quoted(unit)) }
      if let currency = column.currency { fields.append("\"m\":" + TableJSON.quoted(currency)) }
      if let rule = column.rule { fields.append("\"f\":" + TableJSON.quoted(rule)) }
      if let total = column.total { fields.append("\"z\":" + TableJSON.quoted(total.rawValue)) }
      if let digits = column.percentageDecimals { fields.append("\"percent\":\(digits)") }
      if let sort = column.reviewSort { fields.append("\"sort\":" + TableJSON.quoted(sort)) }
      if let filter = column.reviewFilter {
        fields.append("\"filter\":" + TableJSON.quoted(filter))
      }
      if column.frozen { fields.append("\"frozen\":true") }
      return "{" + fields.joined(separator: ",") + "}"
    }
    let cells = sortedCells.map { cell in
      "{\"a\":" + list([pointer(cell.row.uuid), pointer(cell.column.uuid)]) + ",\"s\":"
        + TableJSON.quoted(cell.source) + (cell.isOverride ? ",\"o\":true}" : "}")
    }
    let ledger = sortedLedger.map { entry in
      let owner: [String]
      switch entry.owner {
      case .cell(let row, let column): owner = [pointer(row.uuid), pointer(column.uuid)]
      case .rule(let column): owner = ["null", pointer(column.uuid)]
      }
      let bindings = entry.bindings.map { binding in
        var fields: [String] = []
        if let id = binding.id { fields.append("\"i\":" + pointer(id.uuid)) }
        fields.append("\"k\":" + TableJSON.quoted(binding.target.kind))
        fields.append(
          "\"a\":" + list([String(binding.operand.lowerBound), String(binding.operand.upperBound)]))
        let target: [String]
        switch binding.target {
        case .cell(let t, let row, let column):
          target = [pointer(t.uuid), row.map { pointer($0.uuid) } ?? "null", pointer(column.uuid)]
        case .rectangle(let t, let rows, let columns):
          let rowItems = membership(rows)
          let columnItems = membership(columns)
          target =
            [pointer(t.uuid)]
            + (binding.isDeleted
              ? rowItems + columnItems
              : [rowItems[0], columnItems[0], rowItems[1], columnItems[1]])
        case .columns(let t, let axis): target = [pointer(t.uuid)] + membership(axis)
        case .rows(let t, let axis): target = [pointer(t.uuid)] + membership(axis)
        case .namedColumn(let t, let column): target = [pointer(t.uuid), pointer(column.uuid)]
        case .currentRow(let column): target = [pointer(column.uuid)]
        }
        fields.append("\"t\":" + list(target))
        if !binding.locks.isEmpty {
          fields.append("\"l\":" + list(binding.locks.map { $0 ? "1" : "0" }))
        }
        if binding.isDeleted { fields.append("\"d\":true") }
        return "{" + fields.joined(separator: ",") + "}"
      }
      return "{\"o\":" + list(owner) + ",\"f\":" + TableJSON.quoted(entry.fingerprint) + ",\"e\":"
        + list(bindings) + "}"
    }
    // Every pointer above is assigned before the dictionary is spelled.
    let payload =
      "{\"ids\":" + list(ids.map { TableJSON.quoted(TableID($0).string) }) + ",\"t\":"
      + pointer(table.id.uuid) + ",\"n\":"
      + TableJSON.quoted(table.name) + ",\"c\":" + list(columns) + ",\"r\":"
      + list(table.rows.map { pointer($0.uuid) }) + ",\"x\":" + list(cells) + ",\"b\":"
      + list(ledger) + "}"
    let end = lineEnding.rawValue
    let block = opener + end + payload + end + closer + end
    guard block.utf8.count <= SyntaxLimits.default.maximumSourceUTF8Length else {
      throw TableBlockError(code: .sourceLimit, detail: "The block exceeds the source limit")
    }
    return block
  }
}
