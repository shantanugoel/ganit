import Foundation

/// Rewrites references to surviving lines and marks removed or ambiguous targets.
/// The returned ranges are in the text after the user's edit. Only references
/// surviving from the old source are rewritten; pasted references stay as written.
///
/// Deliberate `@N`/`line N` reads in a table's formulas follow their targets
/// the same way, through the table transformation path, when the edit leaves
/// the table's block untouched; the replacement is then a block patch rather
/// than a number. An edit that removes a valid table's whole block deletes
/// the table: references to it from other untouched tables and prose become
/// broken markers, as `TableSourceDocument.deleteTable` writes them. Edits
/// are in ascending, nonoverlapping order.
public enum LineReferenceRenumbering {
  private enum Target {
    case line(Int)
    case broken(BrokenLineReferenceReason)
  }

  public static func edits(
    replacing range: NSRange, in old: String, with replacement: String,
    configuration: LexingConfiguration
  ) -> [(range: NSRange, replacement: String)] {
    edits(replacing: [range], in: old, with: [replacement], configuration: configuration)
  }

  /// Ranges are nonoverlapping UTF-16 ranges in the old source, as supplied
  /// by NSTextView's multiple-range editing delegate.
  public static func edits(
    replacing ranges: [NSRange], in old: String, with replacements: [String],
    configuration: LexingConfiguration
  ) -> [(range: NSRange, replacement: String)] {
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
    let oldBlocks = TableSourceDocument.blockLines(in: oldLines)
    let newBlocks = TableSourceDocument.blockLines(in: newLines)
    var oldTableLines = IndexSet()
    for span in oldBlocks {
      oldTableLines.insert(integersIn: span.lines)
    }
    var newTableLines = IndexSet()
    for span in newBlocks {
      newTableLines.insert(integersIn: span.lines)
    }
    var edits: [(range: NSRange, replacement: String)] = []
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
        guard
          changes.allSatisfy({ range, _ in
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
    guard !oldBlocks.isEmpty else { return edits }
    // Prose lines no change touches and that stay prose may have operands
    // rewritten.
    func untouched(_ index: Int) -> Bool {
      let start = oldStarts[index]
      let end = start + oldLines[index].text.utf16.count
      return changes.allSatisfy { range, _ in
        range.length > 0
          ? range.upperBound <= start || range.location >= end
          : range.location < start || range.location > end
      } && !newTableLines.contains(lineNumber(at: moved(start)) - 1)
    }
    edits += tableFormulaEdits(
      old: old, lines: oldLines, starts: oldStarts, blocks: oldBlocks, newBlocks: newBlocks,
      newStarts: newStarts, changes: changes, moved: moved, configuration: configuration,
      untouchedProse: untouched
    ) { number in
      guard number >= 1, number <= targets.count else { return nil }
      switch targets[number - 1] {
      case .line(let updated) where updated != number: return .number(updated)
      case .broken(let reason): return .marker("@" + reason.rawValue)
      default: return nil
      }
    }
    return edits.sorted { $0.range.location < $1.range.location }
  }

  /// Formula rewrites in every valid block the edit leaves byte for byte:
  /// no change touches it and the same block starts at its moved position.
  /// A cheap scan skips blocks without line reads when no table was deleted.
  /// Deletion checks every untouched block, including fresh formulas without
  /// saved bindings. A valid table whose whole block one
  /// change removes, without writing its identity back, is deleted: its
  /// readers in untouched blocks and untouched prose lines break.
  private static func tableFormulaEdits(
    old: String, lines: [SheetLine], starts: [Int],
    blocks: [(lines: Range<Int>, terminated: Bool)],
    newBlocks: [(lines: Range<Int>, terminated: Bool)], newStarts: [Int],
    changes: [(NSRange, String)], moved: (Int) -> Int, configuration: LexingConfiguration,
    untouchedProse: (Int) -> Bool, rewrite: (Int) -> LineReferenceRewrite?
  ) -> [(range: NSRange, replacement: String)] {
    func utf16Range(_ span: Range<Int>) -> NSRange {
      let last = lines[span.upperBound - 1]
      let end =
        starts[span.upperBound - 1] + last.text.utf16.count
        + (last.terminator?.rawValue.utf16.count ?? 0)
      return NSRange(location: starts[span.lowerBound], length: end - starts[span.lowerBound])
    }
    // Blocks whose opener through closer text one change replaces.
    var removing: [Int: String] = [:]
    for (index, span) in blocks.enumerated() where span.terminated {
      let start = starts[span.lines.lowerBound]
      let end =
        starts[span.lines.upperBound - 1] + lines[span.lines.upperBound - 1].text.utf16.count
      if let change = changes.first(where: { $0.0.location <= start && $0.0.upperBound >= end }) {
        removing[index] = change.1
      }
    }
    var document: TableSourceDocument?
    var removed: [TableID: TableModel] = [:]
    if !removing.isEmpty {
      let decoded = TableSourceDocument(old)
      document = decoded
      if decoded.blocks.count == blocks.count {
        for (index, replacement) in removing {
          // Text that writes the identity back, such as the same block
          // pasted over itself, keeps the table.
          guard let table = decoded.blocks[index].table,
            !replacement.contains(table.id.string)
          else { continue }
          removed[table.id] = table
        }
      }
    }
    let newSpans = Set(newBlocks.map { [newStarts[$0.lines.lowerBound], $0.lines.count] })
    var candidates = Set<Int>()
    for (index, span) in blocks.enumerated() where span.terminated {
      let range = utf16Range(span.lines)
      guard
        changes.allSatisfy({ change, _ in
          change.length > 0
            ? change.upperBound <= range.location || change.location >= range.upperBound
            : change.location <= range.location || change.location >= range.upperBound
        }), newSpans.contains([moved(range.location), span.lines.count]),
        !removed.isEmpty || lines[span.lines.dropFirst()].contains(where: { mayReadLines($0.text) })
      else { continue }
      candidates.insert(index)
    }
    var edits: [(range: NSRange, replacement: String)] = []
    if !removed.isEmpty, let document {
      for (line, range, marker) in document.proseBreaks(
        removed: removed, configuration: configuration, skips: { !untouchedProse($0) })
      {
        let text = lines[line].text
        let lower = starts[line] + utf16Offset(range.lowerBound, in: text)
        let upper = starts[line] + utf16Offset(range.upperBound, in: text)
        edits.append((NSRange(location: moved(lower), length: upper - lower), marker))
      }
    }
    guard !candidates.isEmpty else { return edits }
    let decoded = document ?? TableSourceDocument(old)
    guard decoded.blocks.count == blocks.count else { return edits }
    for (index, patches) in decoded.followingLineReferences(
      configuration: configuration, includes: candidates.contains, removed: removed,
      rewrite: rewrite)
    {
      let block = decoded.blocks[index]
      let start = utf16Range(blocks[index].lines).location
      let shift = moved(start) - start
      let raw = block.rawSource.utf8
      func utf16Offset(_ utf8: Int) -> Int {
        String(decoding: raw.prefix(utf8 - block.utf8Range.lowerBound), as: UTF8.self).utf16.count
      }
      for patch in patches {
        let lower = utf16Offset(patch.utf8Range.lowerBound)
        let upper = utf16Offset(patch.utf8Range.upperBound)
        edits.append(
          (NSRange(location: start + shift + lower, length: upper - lower), patch.replacement))
      }
    }
    return edits
  }

  /// Whether a block line could hold `@N` or `line N`.
  private static func mayReadLines(_ text: String) -> Bool {
    var previous: UInt8 = 0
    for byte in text.utf8 {
      if previous == UInt8(ascii: "@"), (48...57).contains(byte) { return true }
      previous = byte
    }
    return text.contains("line")
  }

  private static func hasNewline(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
  }

  private static func utf16Offset(_ offset: Int, in source: String) -> Int {
    String(decoding: source.utf8.prefix(offset), as: UTF8.self).utf16.count
  }
}
