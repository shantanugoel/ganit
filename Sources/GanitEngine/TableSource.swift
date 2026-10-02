import Foundation

public struct TableSourceDiagnostic: Hashable, Sendable {
  /// Stable reasons a block has no projection. UI presents these codes;
  /// `detail` is developer-facing and never contains sheet text.
  public enum Code: String, Hashable, Sendable {
    /// A misspelled opener, invalid JSON, or a missing, mistyped or misshaped
    /// known field.
    case malformed
    /// A well-formed opener naming a version other than 1.
    case unsupportedVersion
    /// An opener without a closer; quarantined through the end of the sheet.
    case unterminated
    /// A well-shaped payload that breaks a table rule.
    case invalidRecord
    /// An identity used twice, in one block or across the sheet.
    case duplicateIdentity
    /// Two tables whose names are equal ignoring case.
    case duplicateName
    /// A ledger that disagrees with its formula source.
    case staleBinding
    /// A live binding or record naming an identity that does not exist.
    case orphanTarget
    /// The sheet's tables exceed the provisional populated-cell ceiling.
    case cellLimit
    /// The sheet exceeds the source byte limit.
    case sourceLimit
  }

  public let code: Code
  public let detail: String
  /// The block, or its payload for payload errors, in sheet UTF-8 offsets.
  public let utf8Range: Range<Int>
}

/// One delimited table block. Its bytes are the canonical store: a malformed
/// or unknown block keeps them unchanged, has no projection and is
/// quarantined from ordinary calculation.
struct TableSourceBlock: Equatable, Sendable {
  /// The opener's version, or `nil` when the opener is misspelled.
  let version: Int?
  /// Zero-based physical source lines, opener and closer included.
  let physicalLines: Range<Int>
  /// The block in sheet UTF-8 offsets, including the closer's terminator.
  let utf8Range: Range<Int>
  /// The JSON payload between the opener's terminator and the closer line.
  let payloadUTF8Range: Range<Int>
  let rawSource: String
  /// The payload's syntax tree; its ranges are relative to the payload.
  let json: TableJSON?
  /// The validated projection, or `nil` whenever any diagnostic applies.
  var table: TableModel?
  var diagnostics: [TableSourceDiagnostic]
  /// The block-level projection and diagnostics, before sheet-wide checks.
  let candidate: TableModel?
  let localDiagnostics: [TableSourceDiagnostic]
  /// Whether the block's diagnostics are complete without sheet context. A
  /// block from an oversized sheet skipped its payload and is never reused.
  let isReusable: Bool

  /// Blocks are equal only when their bytes are; Swift string equality would
  /// treat canonically equivalent but different source as the same.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawSource.utf8.elementsEqual(rhs.rawSource.utf8) && lhs.version == rhs.version
      && lhs.physicalLines == rhs.physicalLines && lhs.utf8Range == rhs.utf8Range
      && lhs.payloadUTF8Range == rhs.payloadUTF8Range && lhs.json == rhs.json
      && lhs.table == rhs.table && lhs.diagnostics == rhs.diagnostics
      && lhs.candidate == rhs.candidate && lhs.localDiagnostics == rhs.localDiagnostics
      && lhs.isReusable == rhs.isReusable
  }

  /// A payload node's span in sheet UTF-8 offsets.
  func sheetRange(of node: TableJSON) -> Range<Int> {
    let start = payloadUTF8Range.lowerBound
    return (start + node.utf8Range.lowerBound)..<(start + node.utf8Range.upperBound)
  }

  /// Replaces one existing JSON value without rewriting unknown fields,
  /// formatting or other records. A formula edit must also replace its
  /// owner's ledger entry in the same transaction; otherwise the result is
  /// diagnosed as stale and has no projection.
  func patch(replacing node: TableJSON, withJSON replacement: String) throws -> TableSourcePatch {
    _ = try TableJSON.parse(replacement)
    return TableSourcePatch(
      utf8Range: sheetRange(of: node), expected: try payloadText(node.utf8Range),
      replacement: replacement)
  }

  /// Appends one JSON value to an existing array, such as a new row pointer.
  func patch(appending element: String, to array: TableJSON) throws -> TableSourcePatch {
    _ = try TableJSON.parse(element)
    guard let items = array.array else { throw TableCodecError.stalePatch }
    let close = (array.utf8Range.upperBound - 1)..<array.utf8Range.upperBound
    return TableSourcePatch(
      utf8Range: sheetRange(of: TableJSON(value: .null, utf8Range: close)),
      expected: try payloadText(close), replacement: (items.isEmpty ? "" : ",") + element + "]")
  }

  private func payloadText(_ range: Range<Int>) throws -> String {
    guard range.lowerBound >= 0, range.upperBound <= payloadUTF8Range.count else {
      throw TableCodecError.stalePatch
    }
    let offset = payloadUTF8Range.lowerBound - utf8Range.lowerBound
    let slice = rawSource.utf8.dropFirst(offset + range.lowerBound).prefix(range.count)
    return String(decoding: slice, as: UTF8.self)
  }
}

/// Table blocks recognized in a sheet's physical lines.
///
/// Segmentation runs before ordinary or Markdown classification. Every block,
/// valid or not, occupies physical lines with no scalar answers. A sheet in
/// which no line starts with `@ganit-table` does no further table work.
public struct TableSourceDocument: Sendable {
  /// The only supported block version. Other versions are diagnosed and
  /// quarantined; no earlier version is read.
  public static let currentBlockVersion = 1
  static let opener = "@ganit-table 1"
  static let closer = "@end-ganit-table"
  /// The provisional populated-cell ceiling across all tables in one sheet.
  static let maximumPopulatedCells = 4_000

  /// What one segmentation did, so tests can tell reuse from decoding.
  struct Work: Hashable, Sendable {
    var blocks = 0
    var decoded = 0
    var reused = 0
  }

  let lines: [SheetLine]
  let blocks: [TableSourceBlock]
  let work: Work

  var diagnostics: [TableSourceDiagnostic] { blocks.flatMap(\.diagnostics) }
  /// The source text, rebuilt on demand.
  var source: String { lines.map { $0.text + ($0.terminator?.rawValue ?? "") }.joined() }

  init(_ text: String) {
    self.init(SheetSource(text))
  }

  /// Segments `sheet`. A block whose bytes equal one of `previous` reuses
  /// its parse; byte comparison needs no copy of the block.
  init(_ sheet: SheetSource, reusing previous: [TableSourceBlock] = []) {
    let lines = sheet.lines
    self.lines = lines
    let spans = Self.blockLines(in: lines)
    var work = Work(blocks: spans.count)
    guard !spans.isEmpty else {
      blocks = []
      self.work = work
      return
    }
    // The byte limit is checked first, so oversized source decodes nothing.
    let sourceLength = lines.last.map(end) ?? 0
    let overLimit = sourceLength > SyntaxLimits.default.maximumSourceUTF8Length
    var reusable: [Int: [TableSourceBlock]] = [:]
    for block in previous where !overLimit && block.isReusable {
      reusable[block.utf8Range.count, default: []].append(block)
    }
    var found: [TableSourceBlock] = []
    for (span, terminated) in spans {
      let start = lines[span.lowerBound].range.lowerBound
      let range = start..<end(of: lines[span.upperBound - 1])
      if let match = reusable[range.count]?.first(where: { Self.bytes(of: $0, equal: lines[span]) })
      {
        work.reused += 1
        found.append(match.moved(to: range, lines: span))
        continue
      }
      work.decoded += 1
      let payloadEnd = terminated ? lines[span.upperBound - 1].range.lowerBound : range.upperBound
      found.append(
        Self.decode(
          lines[span].map { $0.text + ($0.terminator?.rawValue ?? "") }.joined(), lines: span,
          range: range, payload: end(of: lines[span.lowerBound])..<payloadEnd,
          terminated: terminated, parsesPayload: !overLimit))
    }
    blocks = Self.checked(found, overLimit: overLimit)
    self.work = work
  }

  /// The physical lines of every block, valid or not, by scanning line starts
  /// only. An unterminated block runs to the last line.
  static func blockLines(in lines: [SheetLine]) -> [(lines: Range<Int>, terminated: Bool)] {
    var spans: [(lines: Range<Int>, terminated: Bool)] = []
    var index = 0
    while index < lines.count {
      guard isOpener(lines[index].text) else {
        index += 1
        continue
      }
      let opener = index
      index += 1
      while index < lines.count, !lines[index].text.utf8.elementsEqual(closer.utf8) {
        index += 1
      }
      let terminated = index < lines.count
      index = terminated ? index + 1 : lines.count
      spans.append((opener..<index, terminated))
    }
    return spans
  }

  /// Whether a physical line opens a block, valid or not: `@ganit-table`
  /// followed by the end of the line, a space or a tab.
  static func isOpener(_ text: String) -> Bool {
    let utf8 = text.utf8
    guard utf8.first == UInt8(ascii: "@"), utf8.starts(with: "@ganit-table".utf8) else {
      return false
    }
    let next = utf8.dropFirst(12).first
    return next == nil || next == 32 || next == 9
  }

  private static func bytes(of block: TableSourceBlock, equal lines: ArraySlice<SheetLine>)
    -> Bool
  {
    var raw = block.rawSource.utf8.makeIterator()
    for line in lines {
      for byte in line.text.utf8 where raw.next() != byte { return false }
      for byte in (line.terminator?.rawValue ?? "").utf8 where raw.next() != byte { return false }
    }
    return raw.next() == nil
  }

  /// Maps sheet UTF-8 offsets to the UTF-16 offsets of a text view, or `nil`
  /// when an offset splits a Unicode scalar or lies outside the source.
  func utf16Range(forUTF8 range: Range<Int>) -> NSRange? {
    let text = source
    let utf8 = text.utf8
    guard range.lowerBound >= 0, range.upperBound <= utf8.count else { return nil }
    let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
    let upper = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
    guard lower.samePosition(in: text.unicodeScalars) != nil,
      upper.samePosition(in: text.unicodeScalars) != nil
    else { return nil }
    return NSRange(
      location: text.utf16.distance(from: text.utf16.startIndex, to: lower),
      length: text.utf16.distance(from: lower, to: upper))
  }

  /// Maps UTF-16 offsets back to sheet UTF-8 offsets, or `nil` when an
  /// offset splits a surrogate pair or lies outside the source.
  func utf8Range(forUTF16 range: NSRange) -> Range<Int>? {
    let text = source
    let utf16 = text.utf16
    guard range.location >= 0, range.length >= 0, range.location <= utf16.count,
      range.length <= utf16.count - range.location
    else { return nil }
    let lower = utf16.index(utf16.startIndex, offsetBy: range.location)
    let upper = utf16.index(lower, offsetBy: range.length)
    guard lower.samePosition(in: text.unicodeScalars) != nil,
      upper.samePosition(in: text.unicodeScalars) != nil
    else { return nil }
    let start = text.utf8.distance(from: text.utf8.startIndex, to: lower)
    return start..<(start + text.utf8.distance(from: lower, to: upper))
  }

  private static func decode(
    _ raw: String, lines: Range<Int>, range: Range<Int>, payload: Range<Int>, terminated: Bool,
    parsesPayload: Bool
  ) -> TableSourceBlock {
    let openerText = raw.utf8.prefix { $0 != 10 && $0 != 13 }
    let suffix = Array(openerText.dropFirst(12))
    let digits = suffix.dropFirst()
    let isVersion =
      suffix.first == 32 && !digits.isEmpty && digits.allSatisfy { (48...57).contains($0) }
      && (digits.count == 1 || digits.first != 48)
    let version = isVersion ? Int(String(decoding: digits, as: UTF8.self)) : nil
    var diagnostic: TableSourceDiagnostic?
    var json: TableJSON?
    var candidate: TableModel?
    var isReusable = true
    if !terminated {
      diagnostic = TableSourceDiagnostic(
        code: .unterminated, detail: "The block has no closer; quarantined to the end",
        utf8Range: range)
    } else if !isVersion {
      diagnostic = TableSourceDiagnostic(
        code: .malformed, detail: "The opener is not `@ganit-table <version>`", utf8Range: range)
    } else if version != currentBlockVersion {
      diagnostic = TableSourceDiagnostic(
        code: .unsupportedVersion, detail: "Only table block version 1 is supported",
        utf8Range: range)
    } else if !parsesPayload {
      isReusable = false
    } else {
      let offset = payload.lowerBound - range.lowerBound
      do {
        let tree = try TableJSON.parse(Array(raw.utf8.dropFirst(offset).prefix(payload.count)))
        json = tree
        candidate = try TableModel(payload: tree)
      } catch let error as TableBlockError {
        diagnostic = TableSourceDiagnostic(
          code: error.code, detail: error.detail, utf8Range: payload)
      } catch {
        diagnostic = TableSourceDiagnostic(
          code: .malformed, detail: "The payload is not strict JSON", utf8Range: payload)
      }
    }
    let local = diagnostic.map { [$0] } ?? []
    return TableSourceBlock(
      version: version, physicalLines: lines, utf8Range: range, payloadUTF8Range: payload,
      rawSource: raw, json: json, table: candidate, diagnostics: local, candidate: candidate,
      localDiagnostics: local, isReusable: isReusable)
  }

  /// Sheet-wide rules. A conflict withholds every affected projection rather
  /// than choosing a winner, and never changes source.
  private static func checked(_ blocks: [TableSourceBlock], overLimit: Bool)
    -> [TableSourceBlock]
  {
    var blocks = blocks
    func reject(_ index: Int, _ code: TableSourceDiagnostic.Code, _ detail: String) {
      blocks[index].table = nil
      if !blocks[index].diagnostics.contains(where: { $0.code == code }) {
        blocks[index].diagnostics.append(
          TableSourceDiagnostic(code: code, detail: detail, utf8Range: blocks[index].utf8Range))
      }
    }
    if overLimit {
      for index in blocks.indices {
        reject(index, .sourceLimit, "The sheet exceeds the source byte limit")
      }
      return blocks
    }
    var names: [String: [Int]] = [:]
    var owners: [UUID: [Int]] = [:]
    for (index, block) in blocks.enumerated() {
      guard let table = block.candidate else { continue }
      names[table.name.lowercased(), default: []].append(index)
      let bindings = table.ledger.flatMap { $0.bindings.compactMap(\.id?.uuid) }
      for uuid in [table.id.uuid] + table.rows.map(\.uuid) + table.columns.map(\.id.uuid) + bindings
      {
        owners[uuid, default: []].append(index)
      }
    }
    for group in names.values where group.count > 1 {
      for index in group {
        reject(index, .duplicateName, "Table names must be unique ignoring case")
      }
    }
    for group in owners.values where Set(group).count > 1 {
      for index in group { reject(index, .duplicateIdentity, "An identity is used by two tables") }
    }

    // Targets in other tables must exist among the valid tables. Rejecting a
    // table can orphan its readers, so repeat until nothing changes. This is
    // conservative: a rejected reader is never accepted again in the loop.
    var changed = true
    while changed {
      changed = false
      var tables: [TableID: (model: TableModel, axes: TableAxes)] = [:]
      for block in blocks {
        if let table = block.table { tables[table.id] = (table, TableAxes(table)) }
      }
      for index in blocks.indices {
        guard let table = blocks[index].table else { continue }
        do {
          for entry in table.ledger {
            for binding in entry.bindings {
              guard let id = binding.target.table, id != table.id else { continue }
              guard let target = tables[id] else {
                guard binding.isDeleted else {
                  throw TableBlockError(code: .orphanTarget, detail: "A target table is missing")
                }
                continue
              }
              try target.model.checkTarget(binding, target.axes)
            }
          }
        } catch let error as TableBlockError {
          reject(index, error.code, error.detail)
          changed = true
        } catch {}
      }
    }

    let populated = blocks.reduce(0) { $0 + ($1.candidate?.populatedCellCount ?? 0) }
    if populated > maximumPopulatedCells {
      for index in blocks.indices where blocks[index].candidate != nil {
        reject(index, .cellLimit, "The sheet's tables exceed 4,000 populated cells")
      }
    }
    return blocks
  }
}

extension TableSourceBlock {
  /// The same bytes at another position: the parse is reused and only
  /// sheet coordinates change.
  fileprivate func moved(to range: Range<Int>, lines: Range<Int>) -> TableSourceBlock {
    let shift = range.lowerBound - utf8Range.lowerBound
    let local = localDiagnostics.map {
      TableSourceDiagnostic(
        code: $0.code, detail: $0.detail,
        utf8Range: ($0.utf8Range.lowerBound + shift)..<($0.utf8Range.upperBound + shift))
    }
    return TableSourceBlock(
      version: version, physicalLines: lines, utf8Range: range,
      payloadUTF8Range: (payloadUTF8Range.lowerBound + shift)..<(payloadUTF8Range.upperBound
        + shift),
      rawSource: rawSource, json: json, table: candidate, diagnostics: local,
      candidate: candidate, localDiagnostics: local, isReusable: isReusable)
  }
}

private func end(of line: SheetLine) -> Int {
  line.range.upperBound + (line.terminator?.rawValue.utf8.count ?? 0)
}
