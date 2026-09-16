import Foundation

/// Keeps each `line N` naming the same line when lines above it are added or
/// removed, the way a spreadsheet keeps its cell references.
public enum LineReferenceRenumbering {
  /// The line shift an edit makes: `delta` lines added (or removed, when
  /// negative), moving the old one-based line `firstMovedLine` and every line
  /// below it. `nil` when the edit adds and removes the same number of lines.
  public static func shift(
    replacing range: NSRange, in old: String, with replacement: String
  ) -> (firstMovedLine: Int, delta: Int)? {
    let text = old as NSString
    let removed = newlines(in: text.substring(with: range))
    let delta = newlines(in: replacement) - removed
    guard delta != 0 else {
      return nil
    }
    let before = text.substring(to: range.upperBound)
    let endLine = newlines(in: before)
    // A line starting where the edit ends moves with the lines after it.
    let endsAtLineStart = before.isEmpty || before.hasSuffix("\n")
    return (endLine + (endsAtLineStart ? 1 : 2), delta)
  }

  /// UTF-16 ranges of `source`, the text after the edit, and the numbers to
  /// write there. Lines in `editedLines` (zero-based, after the edit) are what
  /// the person just wrote and are left as written.
  public static func edits(
    in source: String,
    firstMovedLine: Int,
    delta: Int,
    editedLines: ClosedRange<Int>,
    configuration: LexingConfiguration
  ) -> [(range: NSRange, number: String)] {
    var edits: [(range: NSRange, number: String)] = []
    var lineStart = 0
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    // A reference past the old last line named nothing, so it still names nothing.
    let oldLineCount = lines.count - delta
    for (index, line) in lines.enumerated() {
      defer { lineStart += line.utf16.count + 1 }
      guard !editedLines.contains(index),
        case .calculation(_, _, let expression?, _) = LineSyntax(String(line)),
        let expressionText = expression.text(in: String(line))
      else {
        continue
      }
      let tokens = Lexer(source: String(expressionText), configuration: configuration).lex().tokens
      for (word, number) in zip(tokens, tokens.dropFirst()) {
        guard case .identifier("line") = word.kind,
          case .number(.integer(let digits, .decimal)) = number.kind,
          let old = Int(digits), old >= firstMovedLine, old <= oldLineCount, old + delta >= 1
        else {
          continue
        }
        let prefix = String(line).utf8.prefix(expression.lowerBound + number.range.lowerBound)
        let location = lineStart + String(decoding: prefix, as: UTF8.self).utf16.count
        edits.append(
          (NSRange(location: location, length: digits.utf16.count), String(old + delta)))
      }
    }
    return edits
  }

  private static func newlines(in text: String) -> Int {
    text.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
  }
}
