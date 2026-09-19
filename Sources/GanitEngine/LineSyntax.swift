/// The structural role of one sheet line. All ranges are relative to the
/// start of the line's text and exclude surrounding whitespace.
public enum LineSyntax: Hashable, Sendable {
  /// An empty or whitespace-only line.
  case blank
  /// Three or more hyphens and nothing else: `---`.
  case divider
  /// `# Title`. The title range is empty for a bare `#`.
  case heading(title: SourceRange)
  /// A whole-line `// comment`, including its `//` marker.
  case comment(SourceRange)
  /// An optional `label:`, an optional `name =` declaration, an optional
  /// expression, and an optional trailing `// comment`. At least one of the
  /// label and expression is present; a declaration always has an
  /// expression range, which is empty when nothing follows `=`. `=>` ends the
  /// expression, Calca-style, and is not part of it.
  case calculation(
    label: SourceRange?,
    name: SourceRange?,
    expression: SourceRange?,
    comment: SourceRange?
  )
  /// A markdown paragraph: words that are not a calculation, in markdown mode.
  case markdown

  public init(_ text: String) {
    self = Self.parse(text).syntax
  }

  /// The `=>` ending a calculation line's expression, if it has one. In
  /// Markdown Mode only these lines show an answer, right after the arrow.
  public static func arrow(in text: String) -> SourceRange? {
    parse(text).arrow
  }

  private static func parse(_ text: String) -> (syntax: LineSyntax, arrow: SourceRange?) {
    let characters = LineCharacters(text)
    let content = characters.trimmed(0..<characters.count)
    guard !content.isEmpty else {
      return (.blank, nil)
    }
    if content.count >= 3, content.allSatisfy({ characters[$0] == "-" }) {
      return (.divider, nil)
    }
    if characters[content.lowerBound] == "#" {
      let title = characters.trimmed((content.lowerBound + 1)..<content.upperBound)
      return (.heading(title: characters.range(title)), nil)
    }

    let commentStart = content.first {
      characters[$0] == "/" && $0 + 1 < content.upperBound
        && characters[$0 + 1] == "/"
    }
    if commentStart == content.lowerBound {
      return (.comment(characters.range(content)), nil)
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
    var name: SourceRange?
    var expression = characters.trimmed(expressionStart..<body.upperBound)
    if let equals = expression.first(where: { characters[$0] == "=" }),
      equals + 1 >= expression.upperBound || characters[equals + 1] != ">"
    {
      let declared = characters.trimmed(expression.lowerBound..<equals)
      if !declared.isEmpty {
        name = characters.range(declared)
        expression = characters.trimmed((equals + 1)..<body.upperBound)
      }
    }
    var arrowRange: SourceRange?
    if let arrow = expression.first(where: { characters[$0] == "=" }),
      arrow + 1 < expression.upperBound, characters[arrow + 1] == ">"
    {
      arrowRange = characters.range(arrow..<(arrow + 2))
      expression = characters.trimmed(expression.lowerBound..<arrow)
    }
    let syntax = LineSyntax.calculation(
      label: label,
      name: name,
      expression: expression.isEmpty && name == nil
        ? nil : characters.range(expression),
      comment: comment
    )
    return (syntax, arrowRange)
  }
}

/// A line's grapheme clusters with UTF-8 offsets, so every split point lies
/// on a grapheme boundary.
private struct LineCharacters {
  private let characters: [Character]
  private let utf8Offsets: [Int]

  init(_ text: String) {
    characters = Array(text)
    var offsets = [0]
    for character in characters {
      offsets.append(offsets[offsets.count - 1] + character.utf8.count)
    }
    utf8Offsets = offsets
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
      graphemeLowerBound: range.lowerBound,
      graphemeUpperBound: range.upperBound
    )
  }
}
