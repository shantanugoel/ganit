/// A lossless, strict JSON syntax tree for table block payloads.
///
/// Ranges are UTF-8 offsets into the parsed payload. Objects keep their
/// members in source order with key spans, so unknown keys and the original
/// spelling and whitespace stay in canonical source: edits patch spans rather
/// than re-encoding a block. Numbers keep their exact lexeme and never pass
/// through `Double`.
struct TableJSON: Hashable, Sendable {
  struct Member: Hashable, Sendable {
    let key: String
    /// The quoted key's span, including its quotes.
    let keyUTF8Range: Range<Int>
    let value: TableJSON
  }

  indirect enum Value: Hashable, Sendable {
    case object([Member])
    case array([TableJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
  }

  let value: Value
  let utf8Range: Range<Int>

  /// Table payloads nest at most seven levels. The bound keeps the recursive
  /// descent far from thread stack limits, including under sanitizers.
  static let maximumDepth = 32

  /// A member's value, compared by exact UTF-8 key bytes.
  subscript(key: String) -> TableJSON? {
    guard case .object(let members) = value else { return nil }
    return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
  }
  var members: [Member]? {
    if case .object(let members) = value { return members }
    return nil
  }
  var array: [TableJSON]? {
    if case .array(let items) = value { return items }
    return nil
  }
  var string: String? {
    if case .string(let text) = value { return text }
    return nil
  }
  var isNull: Bool { value == .null }
  /// A non-negative integer spelled without sign, fraction or exponent.
  var index: Int? {
    guard case .number(let text) = value, text.utf8.allSatisfy({ (48...57).contains($0) })
    else { return nil }
    return Int(text)
  }

  static func parse(_ text: String) throws -> TableJSON {
    try parse(Array(text.utf8))
  }

  static func parse(_ bytes: [UInt8]) throws -> TableJSON {
    var parser = TableJSONParser(bytes: bytes)
    let tree = try parser.node(depth: 1)
    parser.space()
    guard parser.cursor == bytes.count else { throw TableCodecError.invalidJSON }
    return tree
  }

  /// The canonical encoding of one string, as the table writer emits it.
  /// `"`, `\`, every C0 and C1 control (U+0000–U+001F, U+007F–U+009F) and
  /// the line separators U+2028 and U+2029 are escaped, so payload lines stay
  /// intact in text editors. Everything else is literal UTF-8, never
  /// normalized.
  static func quoted(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\u{8}": result += "\\b"
      case "\u{C}": result += "\\f"
      case "\u{0}"..."\u{1F}", "\u{7F}"..."\u{9F}", "\u{2028}", "\u{2029}":
        let hex = String(scalar.value, radix: 16)
        result += "\\u" + String(repeating: "0", count: 4 - hex.utf8.count) + hex
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}

enum TableCodecError: Error, Equatable, Sendable {
  case invalidJSON
  case stalePatch
  case overlappingPatches
}

private struct TableJSONParser {
  let bytes: [UInt8]
  var cursor = 0

  mutating func space() {
    while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
  }

  mutating func take(_ byte: UInt8) -> Bool {
    space()
    guard cursor < bytes.count, bytes[cursor] == byte else { return false }
    cursor += 1
    return true
  }

  mutating func node(depth: Int) throws -> TableJSON {
    guard depth <= TableJSON.maximumDepth else { throw TableCodecError.invalidJSON }
    space()
    guard cursor < bytes.count else { throw TableCodecError.invalidJSON }
    let start = cursor
    let value: TableJSON.Value
    switch bytes[cursor] {
    case UInt8(ascii: "{"):
      cursor += 1
      var members: [TableJSON.Member] = []
      // Decoded key bytes; a set keeps duplicate detection linear.
      var keys: Set<[UInt8]> = []
      if !take(UInt8(ascii: "}")) {
        repeat {
          space()
          let keyStart = cursor
          guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") else {
            throw TableCodecError.invalidJSON
          }
          let key = try string()
          let keyRange = keyStart..<cursor
          // Escaped spellings decode first, so `"x"` duplicates `"x"`.
          guard keys.insert(Array(key.utf8)).inserted, take(UInt8(ascii: ":"))
          else { throw TableCodecError.invalidJSON }
          let member = try node(depth: depth + 1)
          members.append(TableJSON.Member(key: key, keyUTF8Range: keyRange, value: member))
        } while take(UInt8(ascii: ","))
        guard take(UInt8(ascii: "}")) else { throw TableCodecError.invalidJSON }
      }
      value = .object(members)
    case UInt8(ascii: "["):
      cursor += 1
      var items: [TableJSON] = []
      if !take(UInt8(ascii: "]")) {
        repeat { items.append(try node(depth: depth + 1)) } while take(UInt8(ascii: ","))
        guard take(UInt8(ascii: "]")) else { throw TableCodecError.invalidJSON }
      }
      value = .array(items)
    case UInt8(ascii: "\""):
      value = .string(try string())
    case UInt8(ascii: "t"):
      try literal("true")
      value = .bool(true)
    case UInt8(ascii: "f"):
      try literal("false")
      value = .bool(false)
    case UInt8(ascii: "n"):
      try literal("null")
      value = .null
    default:
      try number()
      value = .number(String(decoding: bytes[start..<cursor], as: UTF8.self))
    }
    return TableJSON(value: value, utf8Range: start..<cursor)
  }

  mutating func literal(_ text: String) throws {
    let spelling = Array(text.utf8)
    guard cursor + spelling.count <= bytes.count,
      bytes[cursor..<(cursor + spelling.count)].elementsEqual(spelling)
    else { throw TableCodecError.invalidJSON }
    cursor += spelling.count
  }

  /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, so `01`, `.5`, `1.`,
  /// `+1`, `NaN` and `Infinity` are rejected.
  mutating func number() throws {
    func isDigit() -> Bool { cursor < bytes.count && (48...57).contains(bytes[cursor]) }
    func digits() throws {
      guard isDigit() else { throw TableCodecError.invalidJSON }
      while isDigit() { cursor += 1 }
    }
    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "-") { cursor += 1 }
    guard isDigit() else { throw TableCodecError.invalidJSON }
    if bytes[cursor] == UInt8(ascii: "0") { cursor += 1 } else { try digits() }
    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ".") {
      cursor += 1
      try digits()
    }
    if cursor < bytes.count, bytes[cursor] | 0x20 == UInt8(ascii: "e") {
      cursor += 1
      if cursor < bytes.count, [UInt8(ascii: "+"), UInt8(ascii: "-")].contains(bytes[cursor]) {
        cursor += 1
      }
      try digits()
    }
  }

  /// Decodes a string starting at its opening quote. Raw controls, unknown
  /// escapes and unpaired UTF-16 surrogate escapes are rejected rather than
  /// replaced, so decoded text is exactly what the source spells.
  mutating func string() throws -> String {
    cursor += 1
    var decoded: [UInt8] = []
    var escaped = false
    var run = cursor
    while cursor < bytes.count {
      let byte = bytes[cursor]
      if byte == UInt8(ascii: "\"") {
        defer { cursor += 1 }
        guard escaped else { return String(decoding: bytes[run..<cursor], as: UTF8.self) }
        decoded.append(contentsOf: bytes[run..<cursor])
        return String(decoding: decoded, as: UTF8.self)
      }
      guard byte >= 0x20 else { throw TableCodecError.invalidJSON }
      guard byte == UInt8(ascii: "\\") else {
        cursor += 1
        continue
      }
      escaped = true
      decoded.append(contentsOf: bytes[run..<cursor])
      cursor += 1
      guard cursor < bytes.count else { throw TableCodecError.invalidJSON }
      let escape = bytes[cursor]
      cursor += 1
      switch escape {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(escape)
      case UInt8(ascii: "b"): decoded.append(8)
      case UInt8(ascii: "f"): decoded.append(12)
      case UInt8(ascii: "n"): decoded.append(10)
      case UInt8(ascii: "r"): decoded.append(13)
      case UInt8(ascii: "t"): decoded.append(9)
      case UInt8(ascii: "u"):
        var value = try hex()
        if (0xDC00...0xDFFF).contains(value) { throw TableCodecError.invalidJSON }
        if (0xD800...0xDBFF).contains(value) {
          guard cursor + 1 < bytes.count, bytes[cursor] == UInt8(ascii: "\\"),
            bytes[cursor + 1] == UInt8(ascii: "u")
          else { throw TableCodecError.invalidJSON }
          cursor += 2
          let low = try hex()
          guard (0xDC00...0xDFFF).contains(low) else { throw TableCodecError.invalidJSON }
          value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { throw TableCodecError.invalidJSON }
        decoded.append(contentsOf: String(scalar).utf8)
      default:
        throw TableCodecError.invalidJSON
      }
      run = cursor
    }
    throw TableCodecError.invalidJSON
  }

  mutating func hex() throws -> UInt32 {
    guard cursor + 4 <= bytes.count else { throw TableCodecError.invalidJSON }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[cursor]
      let nibble: UInt8
      switch byte {
      case 0x30...0x39: nibble = byte - 0x30
      case 0x41...0x46: nibble = byte - 0x37
      case 0x61...0x66: nibble = byte - 0x57
      default: throw TableCodecError.invalidJSON
      }
      value = value << 4 | UInt32(nibble)
      cursor += 1
    }
    return value
  }
}

/// An explicit edit with an optimistic-source guard. No invalid projection is
/// ever substituted for canonical source; repair is an ordinary raw-source edit.
package struct TableSourcePatch: Hashable, Sendable {
  package let utf8Range: Range<Int>
  package let expected: String
  package let replacement: String

  /// Applies every patch to the same original source as one transaction, or
  /// none of them when any patch is stale or two overlap.
  package static func applying(_ patches: [Self], to source: String) throws -> String {
    let sorted = patches.sorted {
      ($0.utf8Range.lowerBound, $0.utf8Range.upperBound)
        < ($1.utf8Range.lowerBound, $1.utf8Range.upperBound)
    }
    let original = Array(source.utf8)
    var end = 0
    for patch in sorted {
      let range = patch.utf8Range
      guard range.lowerBound >= 0 else { throw TableCodecError.stalePatch }
      guard range.lowerBound >= end else { throw TableCodecError.overlappingPatches }
      guard range.upperBound <= original.count, isUTF8Boundary(range.lowerBound, original),
        isUTF8Boundary(range.upperBound, original),
        original[range].elementsEqual(patch.expected.utf8)
      else { throw TableCodecError.stalePatch }
      // Two insertions at one offset have no defined order.
      end = range.isEmpty ? range.upperBound + 1 : range.upperBound
    }
    var bytes = original
    for patch in sorted.reversed() {
      bytes.replaceSubrange(patch.utf8Range, with: patch.replacement.utf8)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

func isUTF8Boundary(_ index: Int, _ bytes: [UInt8]) -> Bool {
  index >= 0 && index <= bytes.count && (index == bytes.count || bytes[index] & 0xC0 != 0x80)
}
