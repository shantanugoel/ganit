import Foundation

// Revised candidate: intern stable IDs once; integer indexes are only wire
// dictionary pointers, never durable coordinate identities. Formula source
// itself is an exact fingerprint (no hash collision and cheap for short formulas).
struct CompactTable: Codable {
  var id: String
  var name: String
  var columns: [Column]
  var rows: [String]
  var ids: [String]
  var cells: [[String]]
  var bindings: [[String]]
  var totals: [String: String]

  init(_ table: Table) {
    id = table.id
    name = table.name
    columns = table.columns
    rows = table.rows
    totals = table.totals
    ids = Set(
      [table.id] + table.rows + table.columns.map(\.id)
        + table.bindings.flatMap { [$0.target.table, $0.target.row, $0.target.column] }
    ).sorted()
    let lookup = Dictionary(
      uniqueKeysWithValues: ids.enumerated().map { ($0.element, String($0.offset)) })
    let key = { (key: CellKey) in [lookup[key.table]!, lookup[key.row]!, lookup[key.column]!] }
    let inputs = Dictionary(uniqueKeysWithValues: table.cells.map { ($0.key, $0.input) })
    cells = table.cells.map { key($0.key) + [$0.input, $0.override ? "1" : "0"] }
    bindings = table.bindings.map {
      key($0.owner) + [inputs[$0.owner]!, String($0.occurrence)] + key($0.target)
        + [$0.lockRow ? "1" : "0", $0.lockColumn ? "1" : "0", $0.deleted ? "1" : "0"]
    }
  }
  func expanded() throws -> Table {
    try check(Set(ids).count == ids.count, "duplicate ID dictionary")
    func key(_ values: ArraySlice<String>) throws -> CellKey {
      var resolved: [String] = []
      for value in values {
        guard let index = Int(value), ids.indices.contains(index) else {
          throw SpikeFailure(message: "invalid ID dictionary pointer")
        }
        resolved.append(ids[index])
      }
      try check(resolved.count == 3, "invalid identity tuple")
      return CellKey(table: resolved[0], row: resolved[1], column: resolved[2])
    }
    var expandedCells: [Cell] = []
    for record in cells {
      try check(record.count == 5 && ["0", "1"].contains(record[4]), "invalid cell record")
      expandedCells.append(
        Cell(key: try key(record[0..<3]), input: record[3], override: record[4] == "1"))
    }
    var expandedBindings: [Binding] = []
    for record in bindings {
      try check(
        record.count == 11 && record[8...10].allSatisfy { ["0", "1"].contains($0) },
        "invalid binding record")
      guard let occurrence = Int(record[4]) else {
        throw SpikeFailure(message: "invalid occurrence")
      }
      expandedBindings.append(
        Binding(
          owner: try key(record[0..<3]), fingerprint: fingerprint(record[3]),
          occurrence: occurrence, target: try key(record[5..<8]), lockRow: record[8] == "1",
          lockColumn: record[9] == "1", deleted: record[10] == "1"))
    }
    let table = Table(
      id: id, name: name, columns: columns, rows: rows, cells: expandedCells,
      bindings: expandedBindings, totals: totals)
    try table.validate()
    return table
  }
  static func encode(_ table: Table) throws -> Data {
    try table.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(CompactTable(table))
  }
}
