import AppKit
import GanitEngine

/// Visual emphasis for a range of one line, applied as TextKit rendering
/// attributes so the text storage and its offsets never change.
struct LineDecoration: Equatable {
  private static let interpretationUnits = try? UnitCatalog.minimal()
  enum Style: Equatable {
    /// Comments and labels.
    case secondary
    /// Dividers and heading markers.
    case tertiary
    /// A markdown heading's title.
    case heading
    /// Markdown `**bold**`.
    case bold
    /// Markdown `*italic*`.
    case italic
    case interpretation
    case error
    case warning
  }

  struct Run: Equatable {
    /// A UTF-16 range relative to the start of the line.
    let range: NSRange
    let style: Style
  }

  let runs: [Run]

  /// Decorates a line from its role and result. Incomplete input is only
  /// flagged once the insertion point has left the line.
  init(
    text: String, syntax: LineSyntax, result: CalculationResult?, isEditing: Bool,
    lexingConfiguration: LexingConfiguration = .englishUnitedStates
  ) {
    var runs: [Run] = []
    func add(_ range: SourceRange, _ style: Style) {
      runs.append(Run(range: utf16Range(of: range, in: text), style: style))
    }

    switch syntax {
    case .blank:
      break
    case .divider:
      runs.append(Run(range: NSRange(location: 0, length: text.utf16.count), style: .tertiary))
    case .heading:
      if let marker = text.utf16.firstIndex(of: UInt16(UInt8(ascii: "#"))) {
        let location = text.utf16.distance(from: text.utf16.startIndex, to: marker)
        var hashes = 1
        while location + hashes < text.utf16.count {
          let index = text.utf16.index(text.utf16.startIndex, offsetBy: location + hashes)
          if text.utf16[index] != UInt16(UInt8(ascii: "#")) {
            break
          }
          hashes += 1
        }
        runs.append(Run(range: NSRange(location: location, length: hashes), style: .tertiary))
        let titleStart = location + hashes
        let titleLength = text.utf16.count - titleStart
        if titleLength > 0 {
          runs.append(
            Run(range: NSRange(location: titleStart, length: titleLength), style: .heading))
        }
      }
    case .comment(let range):
      add(range, .secondary)
    case .markdown:
      runs.append(contentsOf: markdownEmphasis(in: text))
    case .calculation(let label, _, _, let comment):
      label.map { add($0, .secondary) }
      comment.map { add($0, .secondary) }
    }

    // An accent marks a choice, not an error. Diagnostics still draw after it.
    if case .calculation(_, _, let expression?, _) = syntax {
      let tokens = Lexer(source: text, configuration: lexingConfiguration).lex().tokens
      for index in tokens.indices {
        let token = tokens[index]
        guard token.range.lowerBound >= expression.lowerBound,
          token.range.upperBound <= expression.upperBound
        else { continue }
        let beforeIsNumber: Bool =
          if index > 0, case .number = tokens[index - 1].kind { true } else { false }
        let afterIsNumber: Bool =
          if index + 1 < tokens.count, case .number = tokens[index + 1].kind { true } else { false }
        guard beforeIsNumber || afterIsNumber else { continue }
        switch token.kind {
        case .identifier(let word) where ["m", "l"].contains(word.lowercased()):
          add(token.range, .interpretation)
        case .identifier(let word)
        where CurrencyCatalog.minorUnits[word.uppercased()] != nil
          && Self.interpretationUnits?.unit(matching: word) != nil:
          add(token.range, .interpretation)
        case .currencySymbol("$"):
          add(token.range, .interpretation)
        default: break
        }
      }
    }

    switch result {
    case .syntaxFailure(let diagnostics):
      for diagnostic in diagnostics {
        guard let style = Self.style(for: diagnostic.severity, isEditing: isEditing) else {
          continue
        }
        runs.append(Run(range: visibleRange(diagnostic.range, in: text), style: style))
      }
    case .evaluationFailure(let error):
      guard let style = Self.style(for: error.severity, isEditing: isEditing) else {
        break
      }
      for range in error.ranges {
        runs.append(Run(range: visibleRange(range, in: text), style: style))
      }
    case .value, nil:
      break
    }
    self.runs = runs
  }

  /// The underline style for a diagnostic, or `nil` while incomplete input
  /// is still being edited.
  static func style(for severity: DiagnosticSeverity, isEditing: Bool) -> Style? {
    switch severity {
    case .incomplete:
      return isEditing ? nil : .error
    case .error:
      return .error
    case .warning, .ambiguity:
      return .warning
    }
  }
}

extension LineDecoration.Style {
  /// Rendering attributes for color styles.
  var attributes: [NSAttributedString.Key: Any] {
    switch self {
    case .secondary:
      return [.foregroundColor: VisualStyle.Color.secondary]
    case .tertiary:
      return [.foregroundColor: VisualStyle.Color.tertiary]
    case .interpretation:
      return [.foregroundColor: VisualStyle.Color.interpretation]
    case .heading:
      return [
        .font: NSFont.systemFont(ofSize: VisualStyle.Typography.editorSize, weight: .semibold)
      ]
    case .bold:
      return [
        .font: NSFont.systemFont(ofSize: VisualStyle.Typography.editorSize, weight: .bold)
      ]
    case .italic:
      return [
        .font: NSFontManager.shared.convert(
          NSFont.systemFont(ofSize: VisualStyle.Typography.editorSize),
          toHaveTrait: .italicFontMask
        )
      ]
    case .error, .warning:
      return [:]
    }
  }

  /// The color of a dotted underline, so the state does not rely on text
  /// color alone.
  var underlineColor: NSColor? {
    switch self {
    case .secondary, .tertiary, .heading, .bold, .italic, .interpretation:
      return nil
    case .error:
      return VisualStyle.Color.failure
    case .warning:
      return VisualStyle.Color.warning
    }
  }
}

private func utf16Range(of range: SourceRange, in text: String) -> NSRange {
  let utf8 = text.utf8
  let lower = utf8.index(utf8.startIndex, offsetBy: min(range.lowerBound, utf8.count))
  let upper = utf8.index(utf8.startIndex, offsetBy: min(range.upperBound, utf8.count))
  let location = text.utf16.distance(from: text.utf16.startIndex, to: lower)
  return NSRange(location: location, length: text.utf16.distance(from: lower, to: upper))
}

/// An empty diagnostic range, such as the end of `1 +`, underlines the
/// preceding character so it remains visible.
private func visibleRange(_ range: SourceRange, in text: String) -> NSRange {
  let nsRange = utf16Range(of: range, in: text)
  guard nsRange.length == 0 else {
    return nsRange
  }
  let string = text as NSString
  if nsRange.location > 0 {
    return string.rangeOfComposedCharacterSequence(at: nsRange.location - 1)
  }
  return string.length > 0 ? string.rangeOfComposedCharacterSequence(at: 0) : nsRange
}

/// `**bold**` and `*italic*` runs, so a markdown article can emphasize words
/// without changing the source.
private func markdownEmphasis(in text: String) -> [LineDecoration.Run] {
  let string = text as NSString
  let pattern = #"\*\*(.+?)\*\*|\*(.+?)\*"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return []
  }
  return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap {
    match in
    if match.range(at: 1).location != NSNotFound {
      return LineDecoration.Run(range: match.range(at: 1), style: .bold)
    }
    if match.range(at: 2).location != NSNotFound {
      return LineDecoration.Run(range: match.range(at: 2), style: .italic)
    }
    return nil
  }
}
