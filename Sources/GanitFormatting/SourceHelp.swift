import Foundation
import GanitEngine

/// What hovering or right-clicking a place in a line can explain.
public struct SourceHelp: Equatable, Sendable {
  public let tooltip: String
  public let topicID: String?
  public let menuTitle: String

  public init(tooltip: String, topicID: String?, menuTitle: String) {
    self.tooltip = tooltip
    self.topicID = topicID
    self.menuTitle = menuTitle
  }
}

/// Resolves a function, keyword, or diagnostic at a point in a line of source.
public enum SourceHelpLookup {
  public static func at(
    utf16Offset: Int,
    in line: String,
    diagnostic: FormattedDiagnostic?,
    configuration: LexingConfiguration = .englishUnitedStates
  ) -> SourceHelp? {
    guard utf16Offset >= 0, utf16Offset <= (line as NSString).length else {
      return nil
    }
    let utf8Offset = (line as NSString).substring(to: utf16Offset).utf8.count
    let problem = diagnostic.flatMap { diagnostic -> String? in
      diagnostic.ranges.contains {
        let visible = visibleRange($0, in: line)
        return visible.contains(utf16Offset)
          || utf16Offset > 0 && visible.contains(utf16Offset - 1)
      }
        ? diagnostic.message : nil
    }
    let topic = topic(at: utf8Offset, in: line, configuration: configuration)
    if let topic {
      var lines = [topic.signature ?? topic.title, topic.summary]
      if let problem {
        lines.append(problem)
      }
      return SourceHelp(
        tooltip: lines.joined(separator: "\n"),
        topicID: topic.id,
        menuTitle: String(
          format: String(
            localized: "help.menu.topic",
            defaultValue: "Help: %@",
            bundle: FormattingResources.bundle
          ),
          topic.signature ?? topic.title
        )
      )
    }
    if let problem {
      return SourceHelp(
        tooltip: problem,
        topicID: nil,
        menuTitle: String(
          localized: "help.menu.problem",
          defaultValue: "Show Interpretation",
          bundle: FormattingResources.bundle
        )
      )
    }
    return nil
  }

  private static func topic(
    at utf8Offset: Int,
    in line: String,
    configuration: LexingConfiguration
  ) -> LanguageTopic? {
    let tokens = Lexer(source: line, configuration: configuration).lex().tokens
    for token in tokens {
      guard token.range.lowerBound <= utf8Offset, utf8Offset < token.range.upperBound,
        case .identifier(let name) = token.kind
      else {
        continue
      }
      return LanguageReference.topic(named: name)
    }
    return nil
  }

  private static func visibleRange(_ range: SourceRange, in text: String) -> NSRange {
    let utf8 = text.utf8
    let lower = utf8.index(utf8.startIndex, offsetBy: min(range.lowerBound, utf8.count))
    let upper = utf8.index(utf8.startIndex, offsetBy: min(range.upperBound, utf8.count))
    let location = text.utf16.distance(from: text.utf16.startIndex, to: lower)
    let length = text.utf16.distance(from: lower, to: upper)
    if length > 0 {
      return NSRange(location: location, length: length)
    }
    let string = text as NSString
    if location > 0 {
      return string.rangeOfComposedCharacterSequence(at: location - 1)
    }
    return string.length > 0
      ? string.rangeOfComposedCharacterSequence(at: 0) : NSRange(location: 0, length: 0)
  }
}

extension NSRange {
  fileprivate func contains(_ offset: Int) -> Bool {
    offset >= location && offset < location + max(length, 1)
  }
}
