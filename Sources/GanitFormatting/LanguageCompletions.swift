import Foundation

/// Names a person can complete while typing: functions with their parameters,
/// constants, and keywords.
public enum LanguageCompletions {
  public static let items: [String] = {
    let calls = LanguageReference.topics.compactMap(\.signature).map(insertion(from:))
    let words = [
      "pi", "π", "e", "previous", "prev", "sum", "total", "subtotal", "average", "avg", "median",
      "count",
    ]
    return Array(Set(calls + words)).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }()

  public static func matching(_ prefix: String) -> [String] {
    let needle = prefix.lowercased()
    guard !needle.isEmpty else {
      return []
    }
    return items.filter { $0.lowercased().hasPrefix(needle) }
  }

  /// The text inserted for a help signature: `round(x, places?)` becomes
  /// `round(x, places)`.
  public static func insertion(from signature: String) -> String {
    signature.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: ", ...", with: "")
      .replacingOccurrences(of: "...", with: "")
  }

  /// UTF-16 ranges of each argument placeholder inside a completed call,
  /// shifted by `base` so they sit in the sheet.
  public static func argumentRanges(in insertion: String, at base: Int) -> [NSRange] {
    guard let open = insertion.firstIndex(of: "("),
      let close = insertion.lastIndex(of: ")"),
      open < close
    else {
      return []
    }
    let inner = insertion[insertion.index(after: open)..<close]
    var location = insertion[..<insertion.index(after: open)].utf16.count + base
    var ranges: [NSRange] = []
    var skipComma = false
    for part in inner.split(separator: ",", omittingEmptySubsequences: false) {
      if skipComma {
        location += 1
      }
      skipComma = true
      let raw = String(part)
      let leading = raw.prefix { $0.isWhitespace }.utf16.count
      var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      name.removeAll { $0 == "?" }
      if !name.isEmpty, name != "..." {
        ranges.append(NSRange(location: location + leading, length: name.utf16.count))
      }
      location += raw.utf16.count
    }
    return ranges
  }
}
