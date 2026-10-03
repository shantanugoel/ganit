import Foundation

/// Reconciles only known fields against a deliberately transformed model. The old
/// identity dictionary is append-only, so unknown records containing pointers keep
/// their meaning. Unknown fields and surviving records retain their exact bytes.
extension TableSourceBlock {
  /// `relocated` pairs moved cell owners with their destinations, so a moved
  /// record or ledger entry is patched in place rather than re-encoded.
  func patches(
    for replacement: TableModel, relocated: [TableFormulaOwner: TableFormulaOwner] = [:]
  ) throws -> [TableSourcePatch] {
    guard let table, let json, let ids = json["ids"]?.array else {
      throw TableCodecError.stalePatch
    }
    let order = try ids.map { node -> UUID in
      guard let string = node.string, let id = TableID(canonical: string) else {
        throw TableCodecError.stalePatch
      }
      return id.uuid
    }
    let old = TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: table, identityOrder: order))
    let new = TableSourceDocument(
      try TableSourceDocument.canonicalBlock(for: replacement, identityOrder: order))
    guard let oldJSON = old.blocks.first?.json, let newJSON = new.blocks.first?.json else {
      throw TableCodecError.stalePatch
    }
    // Both canonical spellings share the existing pointers, so an address is
    // spelled the same way in the source and in either canonical form.
    var pointers: [UUID: Int] = [:]
    for (index, node) in (newJSON["ids"]?.array ?? []).enumerated() {
      if let string = node.string, let id = TableID(canonical: string) { pointers[id.uuid] = index }
    }
    func address(_ owner: TableFormulaOwner) -> String? {
      guard case .cell(let row, let column) = owner, let row = pointers[row.uuid],
        let column = pointers[column.uuid]
      else { return nil }
      return "[\(row),\(column)]"
    }
    var moves: [String: String] = [:]
    for (from, to) in relocated {
      if let from = address(from), let to = address(to) { moves[from] = to }
    }
    let payload = String(
      decoding: rawSource.utf8.dropFirst(payloadUTF8Range.lowerBound - utf8Range.lowerBound).prefix(
        payloadUTF8Range.count), as: UTF8.self)
    let reconciler = TableJSONReconciler(bytes: Array(payload.utf8), relocated: moves)
    let merged =
      reconciler.raw(0..<json.utf8Range.lowerBound)
      + (try reconciler.merge(json, old: oldJSON, new: newJSON, root: true))
      + reconciler.raw(json.utf8Range.upperBound..<reconciler.bytes.count)
    if payload.utf8.elementsEqual(merged.utf8) { return [] }
    return [TableSourcePatch(utf8Range: payloadUTF8Range, expected: payload, replacement: merged)]
  }
}

/// Rebuilds a changed container from its source pieces: every surviving
/// element, unknown member and separator keeps its bytes and relative order,
/// removals drop only their own span, and new values are spliced in.
private struct TableJSONReconciler {
  let bytes: [UInt8]
  /// Encoded old cell addresses mapped to their moved destinations.
  let relocated: [String: String]

  /// One element of a rebuilt container: a source element (by index) with its
  /// possibly merged text, or a new encoded value.
  struct Piece {
    let index: Int?
    let text: String
  }

  func raw(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
  func raw(_ node: TableJSON) -> String { raw(node.utf8Range) }
  func encode(_ node: TableJSON) -> String {
    switch node.value {
    case .object(let members):
      return "{"
        + members.map { TableJSON.quoted($0.key) + ":" + encode($0.value) }.joined(separator: ",")
        + "}"
    case .array(let items): return "[" + items.map(encode).joined(separator: ",") + "]"
    case .string(let string): return TableJSON.quoted(string)
    case .number(let number): return number
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    }
  }
  func same(_ a: TableJSON, _ b: TableJSON) -> Bool { encode(a) == encode(b) }
  func key(_ node: TableJSON, index: Int) -> String {
    if node["k"] != nil && node["i"] == nil { return "ordinal:\(index)" }
    for name in ["i", "a", "o"] {
      if let value = node[name] { return name + encode(value) }
    }
    return "ordinal:\(index)"
  }
  /// A source record's identity after the edit. A record overwritten by a move
  /// has no successor, even though a moved record now owns its address.
  func relocatedKey(_ node: TableJSON, index: Int) -> String {
    let key = key(node, index: index)
    guard node["i"] == nil, let name = ["a", "o"].first(where: { node[$0] != nil }) else {
      return key
    }
    let address = String(key.dropFirst())
    if let target = relocated[address] { return name + target }
    return relocated.values.contains(address) ? "replaced:" + key : key
  }

  func merge(_ actual: TableJSON, old: TableJSON, new: TableJSON, root: Bool = false) throws
    -> String
  {
    if same(old, new) { return raw(actual) }
    if let members = actual.members, let oldMembers = old.members, let newMembers = new.members {
      return try mergeObject(actual, members, old: oldMembers, new: newMembers, root: root)
    }
    if let actualItems = actual.array, let oldItems = old.array, let newItems = new.array {
      return try mergeArray(actual, actualItems, old: oldItems, new: newItems, unordered: false)
    }
    return encode(new)
  }

  private func mergeObject(
    _ actual: TableJSON, _ members: [TableJSON.Member], old: [TableJSON.Member],
    new: [TableJSON.Member], root: Bool
  ) throws -> String {
    func value(_ list: [TableJSON.Member], _ key: String) -> TableJSON? {
      list.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }
    var pieces: [(key: String, piece: Piece)] = []
    for (index, member) in members.enumerated() {
      let lower = member.keyUTF8Range.lowerBound
      let previous = value(old, member.key)
      guard let after = value(new, member.key) else {
        // Removed known fields drop out; unknown members are copied verbatim.
        if previous == nil {
          pieces.append(
            (member.key, Piece(index: index, text: raw(lower..<member.value.utf8Range.upperBound))))
        }
        continue
      }
      let text: String
      if let previous {
        // Record arrays have no meaningful order, so they keep their source order.
        if root, ["x", "b"].contains(member.key), let items = member.value.array,
          let oldItems = previous.array, let newItems = after.array, !same(previous, after)
        {
          text = try mergeArray(member.value, items, old: oldItems, new: newItems, unordered: true)
        } else {
          text = try merge(member.value, old: previous, new: after)
        }
      } else {
        text = encode(after)
      }
      pieces.append(
        (
          member.key,
          Piece(index: index, text: raw(lower..<member.value.utf8Range.lowerBound) + text)
        ))
    }
    // Additions take their canonical position after the nearest earlier
    // canonical key that is present, or lead the object.
    for (position, member) in new.enumerated()
    where !members.contains(where: { $0.key.utf8.elementsEqual(member.key.utf8) }) {
      let anchor = new[..<position].reversed().lazy.compactMap { earlier in
        pieces.lastIndex { $0.key.utf8.elementsEqual(earlier.key.utf8) }
      }.first
      pieces.insert(
        (
          member.key,
          Piece(index: nil, text: TableJSON.quoted(member.key) + ":" + encode(member.value))
        ),
        at: anchor.map { $0 + 1 } ?? 0)
    }
    return assemble(
      actual, spans: members.map { $0.keyUTF8Range.lowerBound..<$0.value.utf8Range.upperBound },
      pieces: pieces.map(\.piece))
  }

  /// Ordered arrays (columns, rows, bindings, pointer lists) take the new
  /// order. Unordered record arrays keep the source order of survivors, put a
  /// trailing addition before `]` and any other addition after its canonical
  /// predecessor.
  private func mergeArray(
    _ actual: TableJSON, _ items: [TableJSON], old: [TableJSON], new: [TableJSON],
    unordered: Bool
  ) throws -> String {
    guard let matches = match(items, old: old, new: new, unordered: unordered) else {
      return "[" + new.map(encode).joined(separator: ",") + "]"
    }
    func merged(_ index: Int) throws -> Piece {
      guard let pair = matches[index] else { return Piece(index: nil, text: encode(new[index])) }
      return Piece(index: pair.0, text: try merge(items[pair.0], old: old[pair.1], new: new[index]))
    }
    guard unordered else {
      return assemble(actual, spans: items.map(\.utf8Range), pieces: try new.indices.map(merged))
    }
    var pieces: [(new: Int, piece: Piece)] = []
    for index in new.indices where matches[index] != nil {
      pieces.append((index, try merged(index)))
    }
    pieces.sort { ($0.piece.index ?? 0) < ($1.piece.index ?? 0) }
    let last = matches.lastIndex { $0 != nil } ?? -1
    for index in new.indices where matches[index] == nil {
      let predecessor = (0..<index).last { earlier in pieces.contains { $0.new == earlier } }
      let anchor = predecessor.flatMap { earlier in pieces.firstIndex { $0.new == earlier } }
      let position = index > last ? pieces.count : anchor.map { $0 + 1 } ?? 0
      pieces.insert((index, try merged(index)), at: position)
    }
    return assemble(actual, spans: items.map(\.utf8Range), pieces: pieces.map(\.piece))
  }

  /// For each new item, its source and old counterparts, or `nil` when it is
  /// new. Objects match by durable identity; other items by position around
  /// the changed run. `nil` overall when the source is not a faithful
  /// spelling of the old canonical form.
  private func match(_ items: [TableJSON], old: [TableJSON], new: [TableJSON], unordered: Bool)
    -> [(Int, Int)?]?
  {
    if (items + old + new).allSatisfy({ $0.members != nil }) {
      func keys(_ list: [TableJSON], _ relocate: Bool) -> [String: Int]? {
        var result: [String: Int] = [:]
        for (index, node) in list.enumerated() {
          let key = relocate ? relocatedKey(node, index: index) : key(node, index: index)
          guard result.updateValue(index, forKey: key) == nil else { return nil }
        }
        return result
      }
      guard let source = keys(items, unordered), let previous = keys(old, unordered),
        keys(new, false) != nil
      else { return nil }
      return new.enumerated().map { index, node in
        let key = key(node, index: index)
        guard let a = source[key], let b = previous[key] else { return nil }
        return (a, b)
      }
    }
    guard items.count == old.count,
      zip(items, old).allSatisfy({ $0.members != nil || same($0, $1) })
    else { return nil }
    if old.count == new.count { return new.indices.map { ($0, $0) } }
    var prefix = 0
    while prefix < min(old.count, new.count), same(old[prefix], new[prefix]) { prefix += 1 }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix,
      same(old[old.count - 1 - suffix], new[new.count - 1 - suffix])
    {
      suffix += 1
    }
    return new.indices.map { index in
      if index < prefix { return (index, index) }
      if index >= new.count - suffix {
        let source = index - new.count + old.count
        return (source, source)
      }
      return nil
    }
  }

  /// Joins pieces inside the source container's brackets. A separator comes
  /// from the source gap before a surviving element, or after one, so spacing
  /// and line breaks between untouched elements stay as written.
  private func assemble(_ node: TableJSON, spans: [Range<Int>], pieces: [Piece]) -> String {
    let open = node.utf8Range.lowerBound
    let close = node.utf8Range.upperBound - 1
    let count = spans.count
    func gap(_ index: Int) -> String {
      raw(
        (index == 0 ? open + 1 : spans[index - 1].upperBound)..<(index == count
          ? close : spans[index].lowerBound))
    }
    guard count > 0 else {
      return raw(open..<open + 1) + pieces.map(\.text).joined(separator: ",") + gap(0)
        + raw(close..<close + 1)
    }
    var text = raw(open..<open + 1) + gap(0)
    for (position, piece) in pieces.enumerated() {
      if position > 0 {
        if let index = piece.index, index > 0 {
          text += gap(index)
        } else if let index = pieces[position - 1].index, index < count - 1 {
          text += gap(index + 1)
        } else {
          text += count > 1 ? gap(count - 1) : ","
        }
      }
      text += piece.text
    }
    return text + gap(count) + raw(close..<close + 1)
  }
}
