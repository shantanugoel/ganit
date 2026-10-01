import Foundation

struct Address: Equatable {
  let column: Int
  let row: Int
  let lockColumn: Bool
  let lockRow: Bool
}
func address(_ token: String) -> Address? {
  let expression = try! NSRegularExpression(pattern: #"^(\$?)([A-Za-z]+)(\$?)([1-9][0-9]*)$"#)
  let ns = token as NSString
  guard
    let match = expression.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)),
    let row = Int(ns.substring(with: match.range(at: 4)))
  else { return nil }
  var column = 0
  for letter in ns.substring(with: match.range(at: 2)).uppercased().utf8 {
    let (shifted, overflow) = column.multipliedReportingOverflow(by: 26)
    let (next, addedOverflow) = shifted.addingReportingOverflow(Int(letter - 64))
    guard !overflow && !addedOverflow else { return nil }
    column = next
  }
  return Address(
    column: column, row: row,
    lockColumn: match.range(at: 1).length > 0, lockRow: match.range(at: 3).length > 0)
}
func escapedHeader(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
}
func header(_ token: String) throws -> String {
  try check(token.first == "[", "header opener")
  var result = ""
  var escaped = false
  var closed = false
  for character in token.dropFirst() {
    try check(!closed, "trailing header text")
    if escaped {
      try check(character == "]" || character == "\\", "unknown header escape")
      result.append(character)
      escaped = false
    } else if character == "\\" {
      escaped = true
    } else if character == "]" {
      closed = true
    } else {
      result.append(character)
    }
  }
  try check(closed && !escaped, "unterminated header")
  return result
}
func quotedIdentifier(_ token: String) throws -> String {
  try check(token.first == "`" && token.last == "`" && token.count >= 2, "quoted identifier")
  let interior = String(token.dropFirst().dropLast())
  let decoded = interior.replacingOccurrences(of: "``", with: "`")
  try check(decoded.replacingOccurrences(of: "`", with: "``") == interior, "unescaped backtick")
  return decoded
}
func translated(_ target: Address, from: Address, to: Address, width: Int, height: Int) -> Address?
{
  let column = target.column + (target.lockColumn ? 0 : to.column - from.column)
  let row = target.row + (target.lockRow ? 0 : to.row - from.row)
  guard (1...width).contains(column), (1...height).contains(row) else { return nil }
  return Address(column: column, row: row, lockColumn: target.lockColumn, lockRow: target.lockRow)
}
// The interval uses the old canonical coordinate order; encode identities after
// the transformation. Scalar locks do not participate in structural insertion.
func inserting(_ interval: ClosedRange<Int>, at position: Int) -> ClosedRange<Int> {
  if position <= interval.lowerBound {
    return (interval.lowerBound + 1)...(interval.upperBound + 1)
  }
  if position <= interval.upperBound { return interval.lowerBound...(interval.upperBound + 1) }
  return interval
}
func deleting(_ interval: ClosedRange<Int>, at position: Int) -> ClosedRange<Int>? {
  let surviving = interval.filter { $0 != position }.map { $0 > position ? $0 - 1 : $0 }
  guard let first = surviving.first, let last = surviving.last else { return nil }
  return first...last
}
func verifyGrammar() throws {
  try check(
    address("$B$2") == Address(column: 2, row: 2, lockColumn: true, lockRow: true),
    "absolute address")
  try check(address("$B2")?.lockColumn == true && address("B$2")?.lockRow == true, "mixed locks")
  try check(address("aa2")?.column == 27, "case-insensitive base26")
  for ordinary in ["$12", "12 USD", "3!", "10:30", "label:", "1 | 2", "@2", "@", "B0"] {
    try check(address(ordinary) == nil, "legacy token collision: \(ordinary)")
  }
  for name in ["Unit price", "品名 ] \" |", "USD", "m", "back\\slash", "x]]"] {
    try check(try header("[" + escapedHeader(name) + "]") == name, "header escape round trip")
  }
  try check(try quotedIdentifier("`Travel ``costs```") == "Travel `costs`", "table-name escaping")
  try check((try? header("[broken\\q]")) == nil, "unknown escape rejection")
  let unlocked = address("B2")!
  try check(
    translated(unlocked, from: address("A2")!, to: address("C4")!, width: 5, height: 10)
      == address("D4"), "relative copy")
  try check(
    translated(address("$B$2")!, from: address("A2")!, to: address("C4")!, width: 5, height: 10)
      == address("$B$2"), "locked copy")
  try check(
    translated(unlocked, from: address("A2")!, to: address("E9")!, width: 5, height: 10)
      == nil, "copy outside bounds breaks")
  try check(inserting(2...6, at: 2) == 3...7, "insert before first shifts")
  try check(inserting(2...6, at: 4) == 2...7, "insert strictly inside expands")
  try check(inserting(2...6, at: 7) == 2...6, "append outside finite rectangle")
  try check(deleting(2...6, at: 2) == 2...5, "delete first endpoint takes next included ID")
  try check(deleting(2...6, at: 6) == 2...5, "delete last endpoint avoids neighbor")
  try check(deleting(2...2, at: 2) == nil, "empty membership breaks")
}
