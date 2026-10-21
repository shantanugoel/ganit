import Foundation

/// Check JSON syntax and duplicate object keys before the platform decoder runs.
/// The nesting limit prevents a small reply from consuming an unbounded stack.
struct StrictSuggestionJSON {
  private let bytes: [UInt8]
  private var cursor = 0

  init(_ data: Data) { bytes = Array(data) }

  mutating func check() throws {
    try value(depth: 0)
    whitespace()
    guard cursor == bytes.count else { throw SuggestionDecodingError.invalidSchema }
  }

  private mutating func value(depth: Int) throws {
    guard depth <= 64 else { throw SuggestionDecodingError.invalidBounds }
    whitespace()
    guard let current else { throw SuggestionDecodingError.invalidSchema }
    switch current {
    case 123:
      cursor += 1
      whitespace()
      if take(125) { return }
      var keys: Set<String> = []
      while true {
        whitespace()
        let start = cursor
        try string()
        let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
        guard keys.insert(key).inserted else { throw SuggestionDecodingError.invalidSchema }
        whitespace()
        guard take(58) else { throw SuggestionDecodingError.invalidSchema }
        try value(depth: depth + 1)
        whitespace()
        if take(125) { return }
        guard take(44) else { throw SuggestionDecodingError.invalidSchema }
      }
    case 91:
      cursor += 1
      whitespace()
      if take(93) { return }
      while true {
        try value(depth: depth + 1)
        whitespace()
        if take(93) { return }
        guard take(44) else { throw SuggestionDecodingError.invalidSchema }
      }
    case 34: try string()
    case 116: try literal("true")
    case 102: try literal("false")
    case 110: try literal("null")
    case 45, 48...57: try number()
    default: throw SuggestionDecodingError.invalidSchema
    }
  }

  private mutating func string() throws {
    guard take(34) else { throw SuggestionDecodingError.invalidSchema }
    while let byte = current {
      cursor += 1
      if byte == 34 { return }
      guard byte >= 32 else { throw SuggestionDecodingError.invalidSchema }
      if byte == 92 {
        guard let escape = current else { throw SuggestionDecodingError.invalidSchema }
        cursor += 1
        switch escape {
        case 34, 92, 47, 98, 102, 110, 114, 116: break
        case 117:
          for _ in 0..<4 {
            guard let hex = current,
              (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex)
            else { throw SuggestionDecodingError.invalidSchema }
            cursor += 1
          }
        default: throw SuggestionDecodingError.invalidSchema
        }
      }
    }
    throw SuggestionDecodingError.invalidSchema
  }

  private mutating func number() throws {
    _ = take(45)
    if !take(48) {
      guard let byte = current, (49...57).contains(byte) else {
        throw SuggestionDecodingError.invalidSchema
      }
      digits()
    }
    if take(46) {
      guard let byte = current, (48...57).contains(byte) else {
        throw SuggestionDecodingError.invalidSchema
      }
      digits()
    }
    if take(101) || take(69) {
      _ = take(43) || take(45)
      guard let byte = current, (48...57).contains(byte) else {
        throw SuggestionDecodingError.invalidSchema
      }
      digits()
    }
  }

  private mutating func literal(_ text: String) throws {
    for byte in text.utf8 {
      guard take(byte) else { throw SuggestionDecodingError.invalidSchema }
    }
  }

  private var current: UInt8? { cursor < bytes.count ? bytes[cursor] : nil }

  private mutating func take(_ byte: UInt8) -> Bool {
    guard current == byte else { return false }
    cursor += 1
    return true
  }

  private mutating func digits() {
    while let byte = current, (48...57).contains(byte) { cursor += 1 }
  }

  private mutating func whitespace() {
    while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 {
      cursor += 1
    }
  }
}
