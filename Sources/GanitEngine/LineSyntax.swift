/// The structural role of one sheet line. All ranges are in sheet
/// coordinates and exclude surrounding whitespace.
public enum LineSyntax: Hashable, Sendable {
  /// An empty or whitespace-only line.
  case blank
  /// Three or more hyphens and nothing else: `---`.
  case divider
  /// `# Title`. The title range is empty for a bare `#`.
  case heading(title: SourceRange)
  /// A whole-line `// comment`, including its `//` marker.
  case comment(SourceRange)
  /// An optional `label:`, an optional expression, and an optional trailing
  /// `// comment`. At least one of the label and expression is present.
  case calculation(
    label: SourceRange?,
    expression: SourceRange?,
    comment: SourceRange?
  )

  public init(_ line: SheetLine) {
    let characters = LineCharacters(line)
    let content = characters.trimmed(0..<characters.count)
    guard !content.isEmpty else {
      self = .blank
      return
    }
    if content.count >= 3, content.allSatisfy({ characters[$0] == "-" }) {
      self = .divider
      return
    }
    if characters[content.lowerBound] == "#" {
      self = .heading(
        title: characters.range(
          characters.trimmed((content.lowerBound + 1)..<content.upperBound)
        )
      )
      return
    }

    let commentStart = content.first {
      characters[$0] == "/" && $0 + 1 < content.upperBound
        && characters[$0 + 1] == "/"
    }
    if commentStart == content.lowerBound {
      self = .comment(characters.range(content))
      return
    }
    let body = content.lowerBound..<(commentStart ?? content.upperBound)
    let comment = commentStart.map {
      characters.range($0..<content.upperBound)
    }

    // A label colon must be followed by whitespace, leaving forms such as
    // `10:30` available to expression grammar.
    let colon = body.first {
      characters[$0] == ":"
        && ($0 + 1 == body.upperBound || characters[$0 + 1].isWhitespace)
    }
    var label: SourceRange?
    var expressionStart = body.lowerBound
    if let colon {
      let name = characters.trimmed(body.lowerBound..<colon)
      if !name.isEmpty {
        label = characters.range(name)
        expressionStart = colon + 1
      }
    }
    let expression = characters.trimmed(expressionStart..<body.upperBound)
    self = .calculation(
      label: label,
      expression: expression.isEmpty ? nil : characters.range(expression),
      comment: comment
    )
  }
}

/// A line's grapheme clusters with sheet offsets, so every split point lies on
/// a grapheme boundary.
private struct LineCharacters {
  private let characters: [Character]
  private let utf8Offsets: [Int]
  private let graphemeOrigin: Int

  init(_ line: SheetLine) {
    characters = Array(line.text)
    var offsets = [line.range.lowerBound]
    for character in characters {
      offsets.append(offsets[offsets.count - 1] + character.utf8.count)
    }
    utf8Offsets = offsets
    graphemeOrigin = line.range.graphemeLowerBound
  }

  var count: Int {
    characters.count
  }

  subscript(index: Int) -> Character {
    characters[index]
  }

  func trimmed(_ range: Range<Int>) -> Range<Int> {
    var lower = range.lowerBound
    var upper = range.upperBound
    while lower < upper, characters[lower].isWhitespace {
      lower += 1
    }
    while upper > lower, characters[upper - 1].isWhitespace {
      upper -= 1
    }
    return lower..<upper
  }

  func range(_ range: Range<Int>) -> SourceRange {
    SourceRange(
      lowerBound: utf8Offsets[range.lowerBound],
      upperBound: utf8Offsets[range.upperBound],
      graphemeLowerBound: graphemeOrigin + range.lowerBound,
      graphemeUpperBound: graphemeOrigin + range.upperBound
    )
  }
}
