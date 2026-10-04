import Foundation

/// How a deliberate `@N`/`line N` read changes when the prose lines around it
/// move: its number follows a surviving target, and a removed or ambiguous
/// target becomes a broken marker, exactly as in prose.
enum LineReferenceRewrite: Hashable, Sendable {
  case number(Int)
  /// `@deleted` or `@split`, replacing the whole reference.
  case marker(String)
}

extension TableSourceDocument {
  /// Deliberate `@N`/`line N` reads of prose in valid tables' formulas follow
  /// their targets through the table transformation path: each changed
  /// owner's source, its ledger fingerprint and the spans of its later bound
  /// operands are rewritten together, so the block never becomes stale.
  /// Text cells, headers, identities and reference operands are never
  /// scanned; quarantined blocks and blocks `includes` rejects are left
  /// byte for byte. Returns each rewritten block's index with its patches,
  /// in this document's UTF-8 offsets. Bindings to `removed` tables break
  /// first, in the same patches.
  func followingLineReferences(
    configuration: LexingConfiguration, includes: (Int) -> Bool,
    removed: [TableID: TableModel] = [:],
    rewrite: (Int) -> LineReferenceRewrite?
  ) -> [(block: Int, patches: [TableSourcePatch])] {
    var result: [(block: Int, patches: [TableSourcePatch])] = []
    for (index, block) in blocks.enumerated() where includes(index) {
      guard let table = block.table else { continue }
      var changed =
        removed.isEmpty
        ? table : Self.breaking(table, removed: removed, visible: visible(at: table.id))
      func follow(_ owner: TableFormulaOwner, _ source: String) -> String? {
        guard
          let (text, edits) = Self.followingLineReferences(
            in: source, configuration: configuration, rewrite: rewrite)
        else { return nil }
        // A rewritten read never overlaps a bound operand: operands are
        // masked from the tokens it is found in.
        if let entry = changed.ledger.firstIndex(where: { $0.owner == owner }) {
          changed.ledger[entry].fingerprint = text
          for binding in changed.ledger[entry].bindings.indices {
            let operand = changed.ledger[entry].bindings[binding].operand
            let shift = edits.filter { $0.range.upperBound <= operand.lowerBound }
              .reduce(0) { $0 + $1.delta }
            changed.ledger[entry].bindings[binding].operand =
              (operand.lowerBound + shift)..<(operand.upperBound + shift)
          }
        }
        return text
      }
      for column in changed.columns.indices {
        guard let rule = changed.columns[column].rule,
          let text = follow(.rule(column: changed.columns[column].id), rule)
        else { continue }
        changed.columns[column].rule = text
      }
      for cell in changed.cells.indices where changed.cells[cell].isFormula {
        let owner = TableFormulaOwner.cell(
          row: changed.cells[cell].row, column: changed.cells[cell].column)
        guard let text = follow(owner, changed.cells[cell].source) else { continue }
        changed.cells[cell].source = text
      }
      guard changed != table, let patches = try? block.patches(for: changed),
        Self.isValid(block, patched: patches)
      else { continue }
      result.append((index, patches))
    }
    return result
  }

  /// A formula's source with its deliberate line reads rewritten, and each
  /// rewrite's original UTF-8 range and length change, or `nil` when nothing
  /// changes.
  static func followingLineReferences(
    in source: String, configuration: LexingConfiguration,
    rewrite: (Int) -> LineReferenceRewrite?
  ) -> (text: String, edits: [(range: Range<Int>, delta: Int)])? {
    guard source.utf8.contains(where: { $0 == UInt8(ascii: "@") || $0 == UInt8(ascii: "l") }),
      let syntax = try? TableFormulaSyntax.discover(source, configuration: configuration)
    else { return nil }
    let tokens = syntax.tokens
    var edits: [(range: Range<Int>, replacement: String)] = []
    for (word, number) in zip(tokens, tokens.dropFirst()) {
      let compact = word.kind == .at && word.range.upperBound == number.range.lowerBound
      guard word.kind == .identifier("line") || compact,
        case .number(.integer(let digits, .decimal)) = number.kind, let target = Int(digits),
        let replacement = rewrite(target)
      else { continue }
      switch replacement {
      case .number(let updated):
        edits.append((number.range.lowerBound..<number.range.upperBound, String(updated)))
      case .marker(let marker):
        edits.append((word.range.lowerBound..<number.range.upperBound, marker))
      }
    }
    guard !edits.isEmpty else { return nil }
    var bytes = Array(source.utf8)
    for edit in edits.reversed() { bytes.replaceSubrange(edit.range, with: edit.replacement.utf8) }
    return (
      String(decoding: bytes, as: UTF8.self),
      edits.map { ($0.range, $0.replacement.utf8.count - $0.range.count) }
    )
  }

  /// Whether the block, patched alone, still decodes to a table. Sheet-wide
  /// checks are unaffected: identities, names and targets do not change.
  private static func isValid(_ block: TableSourceBlock, patched patches: [TableSourcePatch])
    -> Bool
  {
    let start = block.utf8Range.lowerBound
    let local = patches.map {
      TableSourcePatch(
        utf8Range: ($0.utf8Range.lowerBound - start)..<($0.utf8Range.upperBound - start),
        expected: $0.expected, replacement: $0.replacement)
    }
    guard let text = try? TableSourcePatch.applying(local, to: block.rawSource),
      let decoded = TableSourceDocument(text).blocks.first
    else { return false }
    return decoded.candidate != nil && decoded.localDiagnostics.isEmpty
  }
}
