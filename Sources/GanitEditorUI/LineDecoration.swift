import AppKit
import GanitEngine

/// Visual emphasis for a range of one line, applied as TextKit rendering
/// attributes so the text storage and its offsets never change.
struct LineDecoration: Equatable {
  enum Style: Equatable {
    /// Comments and labels.
    case secondary
    /// Dividers and heading markers.
    case tertiary
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
  init(text: String, syntax: LineSyntax, result: CalculationResult?, isEditing: Bool) {
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
        runs.append(Run(range: NSRange(location: location, length: 1), style: .tertiary))
      }
    case .comment(let range):
      add(range, .secondary)
    case .calculation(let label, _, _, let comment):
      label.map { add($0, .secondary) }
      comment.map { add($0, .secondary) }
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
      return [.foregroundColor: NSColor.secondaryLabelColor]
    case .tertiary:
      return [.foregroundColor: NSColor.tertiaryLabelColor]
    case .error, .warning:
      return [:]
    }
  }

  /// The color of a dotted underline, so the state does not rely on text
  /// color alone.
  var underlineColor: NSColor? {
    switch self {
    case .secondary, .tertiary:
      return nil
    case .error:
      return .systemRed
    case .warning:
      return .systemOrange
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
