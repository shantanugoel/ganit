import Foundation

struct BoundProseOperand {
  let range: NSRange
  let source: String
  let target: CellKey
}
// Supplied token spans come from binding discovery, never a global replacement.
// Persist the marker in ordinary source; no durable prose LineID/ledger is needed.
func deletingProseTargets(_ source: String, operands: [BoundProseOperand], row: String) throws
  -> String
{
  let ns = source as NSString
  var result = source
  for operand in operands.sorted(by: { $0.range.location > $1.range.location }) {
    try check(
      NSMaxRange(operand.range) <= ns.length
        && ns.substring(with: operand.range) == operand.source, "stale prose operand span")
    if operand.target.row == row {
      let key = operand.target
      result = (result as NSString).replacingCharacters(
        in: operand.range,
        with: "#REF!{\(key.table)/\(key.row)/\(key.column)}")
    }
  }
  return result
}
func verifyProseBindings() throws {
  let source = "first = Items!B3\r\nsecond = Items!B3\n# comment Items!B3\n"
  let first = (source as NSString).range(of: "Items!B3")
  let second = (source as NSString).range(
    of: "Items!B3", options: [],
    range: NSRange(location: NSMaxRange(first), length: source.utf16.count - NSMaxRange(first)))
  let target = CellKey(table: "t-items", row: "r-b", column: "c-qty")
  let operands = [first, second].map {
    BoundProseOperand(range: $0, source: "Items!B3", target: target)
  }
  let broken = try deletingProseTargets(source, operands: operands, row: "r-b")
  try check(
    broken
      == "first = #REF!{t-items/r-b/c-qty}\r\nsecond = #REF!{t-items/r-b/c-qty}\n# comment Items!B3\n",
    "duplicate prose operands patched; comment and line endings intact")
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(broken.utf8).write(to: url, options: .atomic)
  try check(try Data(contentsOf: url) == Data(broken.utf8), "prose deletion source survives reload")
}
