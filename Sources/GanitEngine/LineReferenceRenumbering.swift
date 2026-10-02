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
    edits(replacing: [range], in: old, with: [replacement], configuration: configuration)
  }

  /// Ranges are nonoverlapping UTF-16 ranges in the old source, as supplied
  /// by NSTextView's multiple-range editing delegate.
  public static func edits(
    replacing ranges: [NSRange], in old: String, with replacements: [String],
    configuration: LexingConfiguration
  ) -> [(range: NSRange, number: String)] {
    precondition(ranges.count == replacements.count)
    let changes = zip(ranges, replacements).sorted { $0.0.location < $1.0.location }
    let oldText = old as NSString
    if changes.count == 1, let (range, replacement) = changes.first,
      !hasNewline(oldText.substring(with: range)), !hasNewline(replacement)
    {
      if !replacement.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
      let span = oldText.lineRange(for: range)
      let local = NSRange(location: range.location - span.location, length: range.length)
      let changed = (oldText.substring(with: span) as NSString)
        .replacingCharacters(in: local, with: replacement)
      if !changed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    }
    let updated = NSMutableString(string: old)
    for (range, replacement) in changes.reversed() {
      updated.replaceCharacters(in: range, with: replacement)
    }
    let newText = updated as String
    let oldLines = SheetSource(old).lines
    let newLines = SheetSource(newText).lines
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
      offset
        + changes.reduce(0) { delta, change in
          delta + (offset >= change.0.upperBound ? change.1.utf16.count - change.0.length : 0)
        }
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
      var cursor = firstOffset
      for (range, _) in changes {
        guard range.location < endOffset,
          range.upperBound > firstOffset
            || (range.length == 0 && range.location >= firstOffset && range.location < endOffset)
        else { continue }
        if cursor < range.location {
          anchors.append(moved(cursor))
          anchors.append(moved(min(endOffset, range.location) - 1))
        }
        cursor = max(cursor, range.upperBound)
      }
      if cursor < endOffset {
        anchors.append(moved(cursor))
        anchors.append(moved(endOffset - 1))
      }
      if anchors.isEmpty {
        // Replacing one expression preserves its identity. A multiline
        // deletion or replacement cannot identify a surviving target.
        guard
          let (range, replacement) = changes.first(where: {
            $0.0.location <= firstOffset && $0.0.upperBound >= endOffset
          }), !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !hasNewline(oldText.substring(with: range))
        else {
          targets.append(.broken(.deleted))
          continue
        }
        let written = replacement as NSString
        let first = written.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        let last = written.rangeOfCharacter(
          from: .whitespacesAndNewlines.inverted, options: .backwards)
        let start = moved(range.location)
        anchors = [start + first.location, start + last.upperBound - 1]
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

    // Table block lines are never prose: their references are rewritten with
    // their ledger by table edits, so even quarantined blocks stay untouched.
    // A reference is skipped when its line is in a block before the edit or
    // ends up in one after it. Text leaving a block (as when its opener is
    // deleted) is therefore not rewritten retroactively either; it keeps the
    // numbers it had while quarantined.
    var oldTableLines = IndexSet()
    for span in TableSourceDocument.blockLines(in: oldLines) {
      oldTableLines.insert(integersIn: span.lines)
    }
    var newTableLines = IndexSet()
    for span in TableSourceDocument.blockLines(in: newLines) {
      newTableLines.insert(integersIn: span.lines)
    }
    var edits: [(range: NSRange, number: String)] = []
    for (index, line) in oldLines.enumerated() where !oldTableLines.contains(index) {
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
        guard changes.allSatisfy({ range, _ in
          referenceEnd <= range.location || referenceStart >= range.upperBound
        }), !newTableLines.contains(lineNumber(at: moved(referenceStart)) - 1)
        else { continue }
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
