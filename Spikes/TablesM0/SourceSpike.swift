import CryptoKit
import Foundation
import GanitEngine

// Experimental encoding, deliberately isolated from the production reader.
struct Column: Codable, Equatable {
  var id: String
  var name: String
  var policy: String
  var defaultUnit: String?
  var rule: String?
}
struct CellKey: Codable, Hashable {
  var table: String
  var row: String
  var column: String
}
struct Binding: Codable, Equatable {
  var owner: CellKey
  var fingerprint: String
  var occurrence: Int
  var target: CellKey
  var lockRow: Bool
  var lockColumn: Bool
  var deleted: Bool
}
struct Cell: Codable, Equatable {
  var key: CellKey
  var input: String
  // Explicit blank override is input="", override=true; inheritance is false.
  var override: Bool
}
struct Table: Codable, Equatable {
  var id: String
  var name: String
  var columns: [Column]
  var rows: [String]
  var cells: [Cell]
  var bindings: [Binding]
  var totals: [String: String]

  func validate() throws {
    try check(!id.isEmpty && name.lowercased() != "sheet", "reserved/empty table identity")
    try check(Set(rows).count == rows.count, "duplicate row ID")
    try check(Set(columns.map(\.id)).count == columns.count, "duplicate column ID")
    try check(Set(columns.map { $0.name.lowercased() }).count == columns.count, "duplicate header")
    try check(Set(cells.map(\.key)).count == cells.count, "duplicate cell identity")
    let rowIDs = Set(rows)
    let columnIDs = Set(columns.map(\.id))
    let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.key, $0) })
    for cell in cells {
      try check(
        cell.key.table == id && rowIDs.contains(cell.key.row)
          && columnIDs.contains(cell.key.column), "orphan cell")
    }
    var occurrences: Set<String> = []
    for binding in bindings {
      guard let cell = byKey[binding.owner] else {
        throw SpikeFailure(message: "orphan binding owner")
      }
      try check(binding.fingerprint == fingerprint(cell.input), "stale fingerprint")
      try check(binding.occurrence >= 0, "negative occurrence")
      try check(
        occurrences.insert("\(binding.owner.row)/\(binding.owner.column)/\(binding.occurrence)")
          .inserted,
        "conflicting ledger")
      if !binding.deleted && binding.target.table == id {
        try check(
          rowIDs.contains(binding.target.row) && columnIDs.contains(binding.target.column),
          "missing live target")
      }
    }
  }

  mutating func deleteRow(_ row: String) {
    rows.removeAll { $0 == row }
    cells.removeAll { $0.key.row == row }
    bindings.removeAll { $0.owner.row == row }
    for index in bindings.indices where bindings[index].target.row == row {
      bindings[index].deleted = true
      let owner = bindings[index].owner
      if let cellIndex = cells.firstIndex(where: { $0.key == owner }) {
        // Tiny fixture has one reference. Production must patch token spans, not strings.
        cells[cellIndex].input = "=#REF!{\(id)/\(row)/\(bindings[index].target.column)}"
        bindings[index].fingerprint = fingerprint(cells[cellIndex].input)
      }
    }
  }
}
func fingerprint(_ source: String) -> String {
  SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
}
struct Block {
  var range: NSRange
  var raw: String
  var table: Table?
  var diagnostic: String?
}
struct Codec {
  static let start = "@ganit-table "
  static let end = "@end-ganit-table"

  static func encode(_ table: Table, newline: String = "\n") throws -> String {
    try table.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(table), as: UTF8.self)
    return start + "1" + newline + json.replacingOccurrences(of: "\n", with: newline)
      + newline + end
  }

  // Segments first, without asking the ordinary line parser about any body line.
  // SheetSource preserves CR/LF/CRLF and physical source coordinates.
  static func blocks(_ source: String) -> [Block] {
    let lines = physicalLines(source)
    var blocks: [Block] = []
    var index = 0
    while index < lines.count {
      guard lines[index].text.hasPrefix(start) else {
        index += 1
        continue
      }
      let first = index
      index += 1
      while index < lines.count && lines[index].text != end { index += 1 }
      let terminated = index < lines.count
      let last = terminated ? index : lines.count - 1
      let range = NSRange(
        location: lines[first].offset,
        length: lines[last].offset + lines[last].text.utf16.count - lines[first].offset)
      let raw = (source as NSString).substring(with: range)
      var table: Table?
      var diagnostic: String?
      do {
        try check(terminated, "unterminated block; body quarantined through EOF")
        try check(lines[first].text == start + "1", "unsupported version")
        let body = lines[(first + 1)..<last].map(\.text).joined(separator: "\n")
        let decoded = try JSONDecoder().decode(Table.self, from: Data(body.utf8))
        try decoded.validate()
        table = decoded
      } catch { diagnostic = String(describing: error) }
      blocks.append(Block(range: range, raw: raw, table: table, diagnostic: diagnostic))
      index += 1
    }
    return blocks
  }
}
struct PhysicalLine {
  var text: String
  var offset: Int
}
func physicalLines(_ source: String) -> [PhysicalLine] {
  var result: [PhysicalLine] = []
  var offset = 0
  for line in SheetSource(source).lines {
    result.append(PhysicalLine(text: line.text, offset: offset))
    offset += line.text.utf16.count + (line.terminator?.rawValue.utf16.count ?? 0)
  }
  return result
}
func fixtureTable() -> Table {
  let key = { (row: String, column: String) in CellKey(table: "t-items", row: row, column: column) }
  return Table(
    id: "t-items", name: "Items",
    columns: [
      Column(id: "c-name", name: "品名 ] \" |", policy: "text"),
      Column(id: "c-qty", name: "Qty", policy: "value"),
      Column(id: "c-price", name: "Unit price", policy: "value", defaultUnit: "INR"),
    ], rows: ["r-a", "r-b", "r-c"],
    cells: [
      Cell(
        key: key("r-a", "c-name"),
        input:
          "चाय 😀 é\r\nsecond line\rthird\nUnicode separators \u{2028} \u{2029} [brackets] \"quoted\"",
        override: false),
      Cell(key: key("r-a", "c-qty"), input: "=B3", override: true),
      Cell(key: key("r-b", "c-qty"), input: "=B3", override: true),
      Cell(key: key("r-c", "c-qty"), input: "1,25", override: false),
      Cell(key: key("r-a", "c-price"), input: "=1 | 2", override: true),
      Cell(key: key("r-b", "c-price"), input: "", override: true),
    ],
    bindings: [
      Binding(
        owner: key("r-a", "c-qty"), fingerprint: fingerprint("=B3"), occurrence: 0,
        target: key("r-b", "c-qty"), lockRow: false, lockColumn: false, deleted: false),
      Binding(
        owner: key("r-b", "c-qty"), fingerprint: fingerprint("=B3"), occurrence: 0,
        target: key("r-b", "c-qty"), lockRow: false, lockColumn: false, deleted: false),
    ], totals: ["c-qty": "sum"])
}
