import Foundation

/// Rewrites references to surviving lines and marks removed or ambiguous targets.
/// The returned ranges are in the text after the user's edit. Only references
/// surviving from the old source are rewritten; pasted references stay as written.
public enum LineReferenceRenumbering {
  private enum Target {
    case line(Int)
    case broken(BrokenLineReferenceReason)
  }

  public static func edits(
    replacing range: NSRange, in old: String, with replacement: String,
    configuration: LexingConfiguration
  ) -> [(range: NSRange, number: String)] {
    let oldText = old as NSString
    let removed = oldText.substring(with: range)
    if !hasNewline(removed), !hasNewline(replacement) {
      if !replacement.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
      let span = oldText.lineRange(for: range)
      let local = NSRange(location: range.location - span.location, length: range.length)
      let changed = (oldText.substring(with: span) as NSString)
        .replacingCharacters(in: local, with: replacement)
      if !changed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    }
    let newText = oldText.replacingCharacters(in: range, with: replacement)
    let oldLines = SheetSource(old).lines
    let newLines = SheetSource(newText).lines
    let delta = replacement.utf16.count - range.length
    func starts(_ lines: [SheetLine]) -> [Int] {
      var offset = 0
      return lines.map { line in
        defer { offset += line.text.utf16.count + (line.terminator?.rawValue.utf16.count ?? 0) }
        return offset
      }
    }
    let oldStarts = starts(oldLines)
    let newStarts = starts(newLines)
    func lineNumber(at offset: Int) -> Int {
      var low = 0
      var high = newStarts.count - 1
      while low < high {
        let middle = (low + high + 1) / 2
        if newStarts[middle] <= offset { low = middle } else { high = middle - 1 }
      }
      return low + 1
    }
    func moved(_ offset: Int) -> Int {
      offset >= range.upperBound ? offset + delta : offset
    }
    var targets: [Target] = []
    var occupants: [Int: [Int]] = [:]
    for (index, line) in oldLines.enumerated() {
      let start = oldStarts[index]
      let text = line.text as NSString
      let significant = text.rangeOfCharacter(from: .whitespaces.inverted)
      guard significant.location != NSNotFound else {
        targets.append(.line(lineNumber(at: max(0, moved(start)))))
        continue
      }
      let last = text.rangeOfCharacter(from: .whitespaces.inverted, options: .backwards)
      let firstOffset = start + significant.location
      let endOffset = start + last.upperBound
      var anchors: [Int] = []
      if firstOffset < range.location {
        anchors.append(firstOffset)
        anchors.append(min(endOffset, range.location) - 1)
      }
      if endOffset > range.upperBound {
        anchors.append(max(firstOffset, range.upperBound) + delta)
        anchors.append(endOffset - 1 + delta)
      }
      if anchors.isEmpty {
        // Replacing a line's expression normally keeps its references. Removing
        // it, or replacing it as part of a multiline selection, does not.
        let removed = oldText.substring(with: range)
        if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || hasNewline(removed)
        {
          targets.append(.broken(.deleted))
          continue
        }
        let written = replacement as NSString
        let first = written.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        let last = written.rangeOfCharacter(
          from: .whitespacesAndNewlines.inverted, options: .backwards)
        anchors = [range.location + first.location, range.location + last.upperBound - 1]
      }
      let numbers = Set(anchors.map { lineNumber(at: $0) })
      guard numbers.count == 1, let number = numbers.first else {
        targets.append(.broken(.split))
        continue
      }
      targets.append(.line(number))
      occupants[number, default: []].append(index)
    }
    // Joining two nonempty lines is as ambiguous as splitting one.
    for indices in occupants.values where indices.count > 1 {
      for index in indices { targets[index] = .broken(.split) }
    }

    var edits: [(range: NSRange, number: String)] = []
    for (index, line) in oldLines.enumerated() {
      guard case .calculation(_, _, let expression?, _) = LineSyntax(line.text),
        let expressionText = expression.text(in: line.text)
      else { continue }
      let tokens = Lexer(source: String(expressionText), configuration: configuration).lex().tokens
      for (word, number) in zip(tokens, tokens.dropFirst()) {
        let compact = word.kind == .at && word.range.upperBound == number.range.lowerBound
        guard word.kind == .identifier("line") || compact,
          case .number(.integer(let digits, .decimal)) = number.kind,
          let target = Int(digits), target >= 1, target <= targets.count
        else { continue }
        let base = expression.lowerBound
        let referenceStart =
          oldStarts[index] + utf16Offset(base + word.range.lowerBound, in: line.text)
        let referenceEnd =
          oldStarts[index] + utf16Offset(base + number.range.upperBound, in: line.text)
        // An edit inside a reference is the user's explicit choice.
        guard referenceEnd <= range.location || referenceStart >= range.upperBound else { continue }
        switch targets[target - 1] {
        case .line(let updated) where updated != target:
          let start = oldStarts[index] + utf16Offset(base + number.range.lowerBound, in: line.text)
          edits.append(
            (NSRange(location: moved(start), length: referenceEnd - start), String(updated)))
        case .broken(let reason):
          edits.append(
            (
              NSRange(location: moved(referenceStart), length: referenceEnd - referenceStart),
              "@" + reason.rawValue
            ))
        default: break
        }
      }
    }
    return edits
  }

  private static func hasNewline(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
  }

  private static func utf16Offset(_ offset: Int, in source: String) -> Int {
    String(decoding: source.utf8.prefix(offset), as: UTF8.self).utf16.count
  }
}
