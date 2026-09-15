/// Identifies a line independently of its current position in a sheet.
public struct LineID: Hashable, Sendable {
  public let rawValue: UInt64
}

public enum LineTerminator: String, Hashable, Sendable {
  case lineFeed = "\n"
  case carriageReturnLineFeed = "\r\n"
  case carriageReturn = "\r"
}

public struct SheetLine: Hashable, Sendable {
  public let id: LineID
  public let text: String
  public let terminator: LineTerminator?
  /// The range of `text`, excluding its terminator, in sheet coordinates.
  public let range: SourceRange
}

/// Sheet source segmented into logical lines with stable identities.
///
/// Every source has at least one line. Only the final line lacks a
/// terminator, so joining each line's text and terminator reproduces the
/// source exactly.
public struct SheetSource: Sendable {
  public private(set) var lines: [SheetLine] = []
  private var nextID: UInt64 = 0

  public init(_ text: String) {
    lines = makeLines(
      segments(of: text, includesEnd: true),
      reusing: [],
      matching: [],
      utf8Start: 0,
      graphemeStart: 0
    )
  }

  public var text: String {
    lines.map { $0.text + ($0.terminator?.rawValue ?? "") }.joined()
  }

  /// Replaces a half-open UTF-8 range of the sheet source.
  ///
  /// Only lines touched by the edit are resegmented. Unchanged leading and
  /// trailing lines within that span keep their IDs, as do remaining lines
  /// in order; any additional lines receive new IDs.
  public mutating func replace(
    utf8Range: Range<Int>,
    with replacement: String
  ) {
    // An edit at a line start can merge with the previous terminator, as when
    // `\n` is inserted after `\r`.
    let containing = lineIndex(containing: utf8Range.lowerBound)
    let first =
      utf8Range.lowerBound == lines[containing].range.lowerBound
      ? max(containing - 1, 0) : containing
    let last = lineIndex(containing: utf8Range.upperBound)
    let span = Array(lines[first...last])
    let spanStart = span[0].range.lowerBound
    var bytes = Array(
      span.map { $0.text + ($0.terminator?.rawValue ?? "") }.joined().utf8
    )
    let lower = utf8Range.lowerBound - spanStart
    let upper = utf8Range.upperBound - spanStart
    precondition(
      upper <= bytes.count && isScalarBoundary(lower, in: bytes)
        && isScalarBoundary(upper, in: bytes),
      "Edit range must lie on Unicode scalar boundaries within the source"
    )
    bytes.replaceSubrange(lower..<upper, with: Array(replacement.utf8))

    let replaced = makeLines(
      segments(
        of: String(decoding: bytes, as: UTF8.self),
        includesEnd: last == lines.count - 1
      ),
      reusing: span.map(\.id),
      matching: span.map(\.text),
      utf8Start: spanStart,
      graphemeStart: span[0].range.graphemeLowerBound
    )
    let oldEnd = end(of: span[span.count - 1])
    let newEnd = end(of: replaced[replaced.count - 1])
    let shifted = lines[(last + 1)...].map {
      shift($0, utf8: newEnd.utf8 - oldEnd.utf8, grapheme: newEnd.grapheme - oldEnd.grapheme)
    }
    lines.replaceSubrange(first..., with: replaced + shifted)
  }

  private func lineIndex(containing offset: Int) -> Int {
    precondition(
      offset >= 0 && offset <= end(of: lines[lines.count - 1]).utf8,
      "Edit offset is outside the source"
    )
    var low = 0
    var high = lines.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if lines[middle].range.lowerBound <= offset {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return low
  }

  private mutating func makeLines(
    _ segments: [(text: Substring, terminator: LineTerminator?)],
    reusing ids: [LineID],
    matching texts: [String],
    utf8Start: Int,
    graphemeStart: Int
  ) -> [SheetLine] {
    var assigned = [LineID?](repeating: nil, count: segments.count)
    var oldLower = 0
    var newLower = 0
    while oldLower < ids.count, newLower < segments.count,
      texts[oldLower] == segments[newLower].text
    {
      assigned[newLower] = ids[oldLower]
      oldLower += 1
      newLower += 1
    }
    var oldUpper = ids.count
    var newUpper = segments.count
    while oldUpper > oldLower, newUpper > newLower,
      texts[oldUpper - 1] == segments[newUpper - 1].text
    {
      assigned[newUpper - 1] = ids[oldUpper - 1]
      oldUpper -= 1
      newUpper -= 1
    }
    for offset in 0..<min(oldUpper - oldLower, newUpper - newLower) {
      assigned[newLower + offset] = ids[oldLower + offset]
    }

    var utf8 = utf8Start
    var grapheme = graphemeStart
    return segments.enumerated().map { index, segment in
      let text = String(segment.text)
      let range = SourceRange(
        lowerBound: utf8,
        upperBound: utf8 + text.utf8.count,
        graphemeLowerBound: grapheme,
        graphemeUpperBound: grapheme + text.count
      )
      // Grapheme clusters never span a line terminator, and each terminator
      // is exactly one grapheme.
      utf8 = range.upperBound + (segment.terminator?.rawValue.utf8.count ?? 0)
      grapheme = range.graphemeUpperBound + (segment.terminator == nil ? 0 : 1)
      return SheetLine(
        id: assigned[index] ?? newID(),
        text: text,
        terminator: segment.terminator,
        range: range
      )
    }
  }

  private mutating func newID() -> LineID {
    defer { nextID += 1 }
    return LineID(rawValue: nextID)
  }
}

/// Splits text at `\n`, `\r\n`, and `\r`. The final unterminated remainder is
/// a line only when the text reaches the end of the sheet.
private func segments(
  of text: String,
  includesEnd: Bool
) -> [(text: Substring, terminator: LineTerminator?)] {
  var result: [(text: Substring, terminator: LineTerminator?)] = []
  let scalars = text.unicodeScalars
  var start = scalars.startIndex
  var index = start
  while index < scalars.endIndex {
    let scalar = scalars[index]
    guard scalar == "\n" || scalar == "\r" else {
      index = scalars.index(after: index)
      continue
    }
    var next = scalars.index(after: index)
    var terminator = LineTerminator.lineFeed
    if scalar == "\r" {
      terminator = .carriageReturn
      if next < scalars.endIndex, scalars[next] == "\n" {
        terminator = .carriageReturnLineFeed
        next = scalars.index(after: next)
      }
    }
    result.append((text[start..<index], terminator))
    start = next
    index = next
  }
  if includesEnd {
    result.append((text[start...], nil))
  }
  return result
}

private func end(of line: SheetLine) -> (utf8: Int, grapheme: Int) {
  guard let terminator = line.terminator else {
    return (line.range.upperBound, line.range.graphemeUpperBound)
  }
  return (
    line.range.upperBound + terminator.rawValue.utf8.count,
    line.range.graphemeUpperBound + 1
  )
}

private func shift(_ line: SheetLine, utf8: Int, grapheme: Int) -> SheetLine {
  SheetLine(
    id: line.id,
    text: line.text,
    terminator: line.terminator,
    range: SourceRange(
      lowerBound: line.range.lowerBound + utf8,
      upperBound: line.range.upperBound + utf8,
      graphemeLowerBound: line.range.graphemeLowerBound + grapheme,
      graphemeUpperBound: line.range.graphemeUpperBound + grapheme
    )
  )
}

private func isScalarBoundary(_ offset: Int, in bytes: [UInt8]) -> Bool {
  offset >= 0 && (offset == bytes.count || bytes[offset] & 0b1100_0000 != 0b1000_0000)
}
