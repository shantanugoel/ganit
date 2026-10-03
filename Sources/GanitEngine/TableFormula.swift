import Foundation

/// A cell identity is the durable table/row/column tuple, including distinct
/// headers. Coordinates and formatted values are never its identity.
struct TableCellAddress: Hashable, Sendable {
  let table: TableID
  let row: RowID?
  let column: ColumnID
}

/// A range describes membership, not a copied list of scalar arguments.
struct TableRangeOperand: Hashable, Sendable {
  let target: TableReferenceTarget
}

/// Tables extend the operand domain without extending EngineValue or
/// coercing blanks, text or failed references into numbers.
enum TableOperand: Hashable, Sendable {
  case scalar(EngineValue)
  case text(String)
  case blank
  case range(TableRangeOperand)
  case failure(TableFormulaDiagnostic)
}

struct TableFormulaDiagnostic: Error, Hashable, Sendable {
  enum Code: String, Hashable, Sendable {
    case malformedReference, missingTable, invisibleTable, missingColumn
    case outOfBounds, mixedTableRange, staleBinding, brokenReference
    case missingInheritedVariable, inheritedFailure, bareAggregate, scalarRequired
  }
  let code: Code
  let range: SourceRange
}

struct TableCoordinate: Hashable, Sendable {
  /// A1 uses one-based axes: row 1 is the header.
  let row: Int
  let column: Int
  let rowLocked: Bool
  let columnLocked: Bool
}

enum TableReferenceSyntax: Hashable, Sendable {
  case cell(table: String?, coordinate: TableCoordinate)
  case rectangle(table: String?, first: TableCoordinate, last: TableCoordinate)
  case columns(table: String?, first: Int, last: Int, locks: [Bool])
  case rows(table: String?, first: Int, last: Int, locks: [Bool])
  case namedColumn(table: String, column: String)
  case currentRow(column: String)
  case inherited(String)
  case broken(String)
}

struct TableReferenceOccurrence: Hashable, Sendable {
  let syntax: TableReferenceSyntax
  let range: SourceRange
  /// Contains a character ordinary variables cannot contain, so callers
  /// cannot accidentally shadow an operand slot.
  var slot: String { "\u{1f}table\(range.lowerBound)" }
}

struct TableBoundReference: Hashable, Sendable {
  let occurrence: TableReferenceOccurrence
  let target: TableReferenceTarget?
  let locks: [Bool]
  let inheritedName: String?
  let deleted: Bool
}

/// Visibility is captured at the table entry by the mixed-sheet fold. The
/// binder may resolve the current table or visible earlier tables only.
struct TableFormulaScope: Sendable {
  let current: TableModel?
  let visible: [TableModel]
  let inherited: [String: EngineValue?]
}

struct TableFormulaSyntax: Sendable {
  let source: String
  let tableFormula: Bool
  let references: [TableReferenceOccurrence]
  let tokens: [Token]
  let diagnostics: [SyntaxDiagnostic]

  /// The reference pass precedes value-kind-directed parsing. Formula `=`
  /// and reference spans are masked only for lexing, with original byte and
  /// grapheme coordinates restored on every token.
  static func discover(
    _ source: String, tableFormula: Bool = true,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default
  ) throws -> Self {
    guard source.utf8.count <= limits.maximumSourceUTF8Length else {
      let range = SourceRange(
        lowerBound: 0, upperBound: source.utf8.count,
        graphemeLowerBound: 0, graphemeUpperBound: source.count)
      return Self(
        source: source, tableFormula: tableFormula, references: [],
        tokens: [Token(kind: .endOfFile, range: range)],
        diagnostics: [SyntaxDiagnostic(code: .resourceLimitExceeded, range: range)])
    }
    var scanner = TableReferenceScanner(source: source, tableFormula: tableFormula)
    let references = try scanner.scan()
    var bytes = Array(source.utf8)
    if tableFormula, bytes.first == UInt8(ascii: "=") { bytes[0] = 32 }
    for reference in references {
      for index in reference.range.lowerBound..<reference.range.upperBound { bytes[index] = 32 }
    }
    let lexing = Lexer(
      source: String(decoding: bytes, as: UTF8.self),
      configuration: configuration, limits: limits
    ).lex()
    let positions = originalGraphemes(source)
    func original(_ range: SourceRange) -> SourceRange {
      SourceRange(
        lowerBound: range.lowerBound, upperBound: range.upperBound,
        graphemeLowerBound: positions[range.lowerBound],
        graphemeUpperBound: positions[range.upperBound])
    }
    let operands = references.map { Token(kind: .identifier($0.slot), range: $0.range) }
    let tokens = (lexing.tokens.map { Token(kind: $0.kind, range: original($0.range)) } + operands)
      .sorted { $0.range.lowerBound < $1.range.lowerBound }
    var diagnostics = lexing.diagnostics.map {
      SyntaxDiagnostic(code: $0.code, severity: $0.severity, range: original($0.range))
    }
    // Masked reference operands still count toward the existing syntax budget.
    if tokens.count - 1 + diagnostics.count > limits.maximumTokenCount,
      !diagnostics.contains(where: { $0.code == .resourceLimitExceeded })
    {
      diagnostics.append(SyntaxDiagnostic(code: .resourceLimitExceeded, range: tokens.last!.range))
    }
    return Self(
      source: source, tableFormula: tableFormula, references: references,
      tokens: tokens, diagnostics: diagnostics)
  }

  /// Reuse a ledger only when its exact formula and every recognized operand
  /// agree. A surviving identity cannot silently override different readable
  /// coordinates; deleted markers can never rebind to a reused coordinate.
  func bind(scope: TableFormulaScope, ledger: TableLedgerEntry? = nil) throws
    -> [TableBoundReference]
  {
    if let ledger, !ledger.fingerprint.utf8.elementsEqual(source.utf8) {
      throw problem(.staleBinding, references.first?.range ?? tokens.last!.range)
    }
    var bindings: [TableBoundReference] = []
    var ledgerIndex = 0
    for occurrence in references {
      if case .inherited(let name) = occurrence.syntax {
        let normalized = name.lowercased().split(whereSeparator: \.isWhitespace).joined(
          separator: " ")
        guard scope.inherited.keys.contains(normalized) else {
          throw problem(.missingInheritedVariable, occurrence.range)
        }
        bindings.append(
          TableBoundReference(
            occurrence: occurrence, target: nil, locks: [],
            inheritedName: normalized, deleted: false))
        continue
      }
      let persisted = ledger.flatMap {
        ledgerIndex < $0.bindings.count ? $0.bindings[ledgerIndex] : nil
      }
      ledgerIndex += 1
      if case .broken(let marker) = occurrence.syntax {
        guard let persisted, persisted.isDeleted,
          persisted.operand == occurrence.range.lowerBound..<occurrence.range.upperBound,
          persisted.brokenMarker == marker
        else {
          throw problem(.brokenReference, occurrence.range)
        }
        bindings.append(
          TableBoundReference(
            occurrence: occurrence, target: persisted.target,
            locks: persisted.locks, inheritedName: nil, deleted: true))
        continue
      }
      let (target, locks) = try resolve(occurrence, scope: scope)
      if let ledger {
        guard let persisted, !persisted.isDeleted, persisted.target == target,
          persisted.locks == locks,
          persisted.operand == occurrence.range.lowerBound..<occurrence.range.upperBound
        else {
          throw problem(.staleBinding, occurrence.range)
        }
        _ = ledger
      }
      bindings.append(
        TableBoundReference(
          occurrence: occurrence, target: target,
          locks: locks, inheritedName: nil, deleted: false))
    }
    if let ledger, ledgerIndex != ledger.bindings.count {
      throw problem(.staleBinding, references.last?.range ?? tokens.last!.range)
    }
    return bindings
  }

  /// Scalar/range slots enter the existing AST as identifiers; table graph
  /// evaluation supplies their outcomes later. No second arithmetic parser.
  func parse(
    context: EvaluationContext, operandKinds: [String: EngineValueKind] = [:],
    inheritedKinds: [String: EngineValueKind] = [:], catalog: UnitCatalog? = nil,
    limits: SyntaxLimits = .default
  ) throws -> ParsingResult {
    var kinds = inheritedKinds
    // Collapsed aggregate operands are slots too, outside `references`.
    for (slot, kind) in operandKinds where slot.hasPrefix("\u{1f}") { kinds[slot] = kind }
    for reference in references { kinds[reference.slot] = operandKinds[reference.slot] ?? .number }
    let parsing = Parser(
      source: source, configuration: context.lexingConfiguration, limits: limits,
      catalog: catalog, variables: kinds, dollarCurrency: context.dollarCurrency,
      ambiguousSuffixes: context.ambiguousSuffixes
    ).parse(tokens: tokens, diagnostics: diagnostics)
    if tableFormula, let expression = parsing.expression {
      var pending = [expression]
      while let next = pending.popLast() {
        if case .reference(let reference, let range) = next {
          switch reference {
          case .previous, .aggregate: throw problem(.bareAggregate, range)
          default: break
          }
        }
        // Keywords are case-insensitive in table formulas (`SUM`, `Previous`);
        // a visible inherited name keeps its variable meaning.
        if case .identifier(let name, let range) = next,
          referenceKeywords[name.lowercased()] != nil, kinds[name.lowercased()] == nil
        {
          throw problem(.bareAggregate, range)
        }
        pending.append(contentsOf: next.tableChildren)
      }
    }
    return parsing
  }

  private func resolve(_ occurrence: TableReferenceOccurrence, scope: TableFormulaScope) throws
    -> (TableReferenceTarget, [Bool])
  {
    func table(_ name: String?) throws -> TableModel {
      if let name {
        if let current = scope.current, current.name.lowercased() == name.lowercased() {
          return current
        }
        guard let found = scope.visible.first(where: { $0.name.lowercased() == name.lowercased() })
        else {
          throw problem(.invisibleTable, occurrence.range)
        }
        return found
      }
      guard let current = scope.current else { throw problem(.missingTable, occurrence.range) }
      return current
    }
    func column(_ index: Int, _ table: TableModel) throws -> ColumnID {
      guard index > 0, index <= table.columns.count else {
        throw problem(.outOfBounds, occurrence.range)
      }
      return table.columns[index - 1].id
    }
    func row(_ index: Int, _ table: TableModel) throws -> RowID {
      guard index >= 2, index <= table.rows.count + 1 else {
        throw problem(.outOfBounds, occurrence.range)
      }
      return table.rows[index - 2]
    }
    func named(_ name: String, _ table: TableModel) throws -> ColumnID {
      guard let column = table.columns.first(where: { $0.header.lowercased() == name.lowercased() })
      else {
        throw problem(.missingColumn, occurrence.range)
      }
      return column.id
    }
    switch occurrence.syntax {
    case .cell(let qualifier, let coordinate):
      let t = try table(qualifier)
      return (
        .cell(
          table: t.id, row: coordinate.row == 1 ? nil : try row(coordinate.row, t),
          column: try column(coordinate.column, t)),
        [coordinate.rowLocked, coordinate.columnLocked]
      )
    case .rectangle(let qualifier, let first, let last):
      let t = try table(qualifier)
      guard first.row <= last.row, first.column <= last.column else {
        throw problem(.outOfBounds, occurrence.range)
      }
      return (
        .rectangle(
          table: t.id, rows: .interval(first: try row(first.row, t), last: try row(last.row, t)),
          columns: .interval(first: try column(first.column, t), last: try column(last.column, t))),
        [first.rowLocked, first.columnLocked, last.rowLocked, last.columnLocked]
      )
    case .columns(let qualifier, let first, let last, let locks):
      let t = try table(qualifier)
      guard first <= last else { throw problem(.outOfBounds, occurrence.range) }
      return (
        .columns(table: t.id, .interval(first: try column(first, t), last: try column(last, t))),
        locks
      )
    case .rows(let qualifier, let first, let last, let locks):
      let t = try table(qualifier)
      guard first <= last else { throw problem(.outOfBounds, occurrence.range) }
      return (
        .rows(table: t.id, .interval(first: try row(first, t), last: try row(last, t))), locks
      )
    case .namedColumn(let qualifier, let name):
      let t = try table(qualifier)
      return (.namedColumn(table: t.id, column: try named(name, t)), [])
    case .currentRow(let name):
      return (.currentRow(column: try named(name, table(nil))), [])
    case .inherited, .broken: preconditionFailure("Handled before live binding")
    }
  }
}

private func problem(_ code: TableFormulaDiagnostic.Code, _ range: SourceRange)
  -> TableFormulaDiagnostic
{
  TableFormulaDiagnostic(code: code, range: range)
}

private func originalGraphemes(_ source: String) -> [Int] {
  var offsets = [Int](repeating: 0, count: source.utf8.count + 1)
  var byte = 0
  for (grapheme, character) in source.enumerated() {
    for offset in byte..<(byte + character.utf8.count) { offsets[offset] = grapheme }
    byte += character.utf8.count
    offsets[byte] = grapheme + 1
  }
  return offsets
}

/// Token-position scanner: headers and quoted identifiers are consumed as
/// complete operands, never searched for A1-looking substrings.
private struct TableReferenceScanner {
  let source: String
  let tableFormula: Bool
  private var characters: [Character] { Array(source) }

  mutating func scan() throws -> [TableReferenceOccurrence] {
    let chars = characters
    // Preserve the existing lexer's complete temporal token, including a
    // lexically recognized invalid clock (whose evaluator reports the error).
    // Unqualified 12:30 is a time; Table!12:30 explicitly selects data rows.
    let temporalRanges = Dictionary(
      uniqueKeysWithValues:
        Lexer(source: source).lex().tokens.compactMap { token -> (Int, Int)? in
          if case .temporal = token.kind { return (token.range.lowerBound, token.range.upperBound) }
          return nil
        })
    var byteOffsets = [0]
    for char in chars { byteOffsets.append(byteOffsets.last! + char.utf8.count) }
    func range(_ start: Int, _ end: Int) -> SourceRange {
      SourceRange(
        lowerBound: byteOffsets[start], upperBound: byteOffsets[end],
        graphemeLowerBound: start, graphemeUpperBound: end)
    }
    var index = 0
    var operand = true
    var result: [TableReferenceOccurrence] = []
    var promptDepth = 0
    var inPlaceholder = false
    var phraseWords: [String] = []
    var expressionDepth = 0
    var percentageChanges: [Int] = []
    if tableFormula, chars.first == "=" { index = 1 }
    while index < chars.count {
      if promptDepth > 0, !inPlaceholder {
        switch chars[index] {
        case "(": promptDepth += 1
        case ")": promptDepth -= 1
        case "{":
          inPlaceholder = true
          operand = true
        default: break
        }
        index += 1
        continue
      }
      if inPlaceholder, chars[index] == "}" {
        inPlaceholder = false
        operand = false
        index += 1
        continue
      }
      if chars[index].isWhitespace {
        index += 1
        continue
      }
      if operand, let end = temporalRanges[byteOffsets[index]] {
        while index < chars.count, byteOffsets[index] < end { index += 1 }
        operand = false
        continue
      }
      if operand, let match = try reference(chars, at: index, failureRange: range(index, index + 1))
      {
        result.append(TableReferenceOccurrence(syntax: match.0, range: range(index, match.1)))
        index = match.1
        operand = false
        continue
      }
      let char = chars[index]
      if "+-*/^&|√(,;−×·÷<>".contains(char) {
        if char == "(" { expressionDepth += 1 }
        operand = true
        index += 1
        continue
      }
      if char == ")" || char == "%" || char == "!" {
        if char == ")" { expressionDepth = max(0, expressionDepth - 1) }
        operand = false
        index += 1
        continue
      }
      if char == "@" {
        index += 1
        while index < chars.count, chars[index].isLetter || chars[index].isNumber { index += 1 }
        operand = false
        continue
      }
      if char.isLetter || char == "_" {
        let start = index
        while index < chars.count,
          chars[index].isLetter || chars[index].isNumber || chars[index] == "_"
        { index += 1 }
        let word = String(chars[start..<index]).lowercased()
        if word == assistantFunctionName {
          var next = index
          while next < chars.count, chars[next].isWhitespace { next += 1 }
          if next < chars.count, chars[next] == "(" {
            promptDepth = 1
            index = next + 1
            operand = false
            continue
          }
        }
        if word == "from", Array(phraseWords.suffix(2)) == ["percentage", "change"] {
          percentageChanges.append(expressionDepth)
        }
        let percentageTo = word == "to" && percentageChanges.last == expressionDepth
        if percentageTo { percentageChanges.removeLast() }
        phraseWords.append(word)
        if phraseWords.count > 2 { phraseWords.removeFirst() }
        operand = ["of", "off", "on", "is", "after", "from"].contains(word) || percentageTo
        continue
      }
      if char.isNumber || char == "." {
        // Keep ordinary temporal literals, radix numbers and decimals together.
        while index < chars.count,
          chars[index].isNumber || chars[index].isLetter || ".:".contains(chars[index])
        { index += 1 }
        operand = false
        continue
      }
      // Currency symbols are prefixes of the existing money production.
      if "$€£¥₹".contains(char) {
        index += 1
        continue
      }
      operand = false
      index += 1
    }
    return result
  }

  private func reference(_ chars: [Character], at start: Int, failureRange: SourceRange) throws
    -> (TableReferenceSyntax, Int)?
  {
    func invalid() -> TableFormulaDiagnostic { problem(.malformedReference, failureRange) }
    func asciiLetter(_ c: Character) -> Bool {
      c.unicodeScalars.count == 1 && c.isASCII && c.isLetter
    }
    func word(_ offset: Int) -> (String, Int)? {
      guard offset < chars.count, asciiLetter(chars[offset]) || chars[offset] == "_" else {
        return nil
      }
      var end = offset + 1
      while end < chars.count,
        asciiLetter(chars[end]) || (chars[end].isASCII && chars[end].isNumber) || chars[end] == "_"
      {
        end += 1
      }
      return (String(chars[offset..<end]), end)
    }
    func identifier(_ offset: Int) throws -> (String, Int)? {
      guard offset < chars.count else { return nil }
      if chars[offset] != "`" { return word(offset) }
      var value = ""
      var cursor = offset + 1
      while cursor < chars.count {
        if chars[cursor] == "`" {
          if cursor + 1 < chars.count, chars[cursor + 1] == "`" {
            value.append("`")
            cursor += 2
          } else {
            return (value, cursor + 1)
          }
        } else {
          value.append(chars[cursor])
          cursor += 1
        }
      }
      throw invalid()
    }
    func bracket(_ offset: Int) throws -> (String, Int) {
      guard offset < chars.count, chars[offset] == "[" else { throw invalid() }
      var value = ""
      var cursor = offset + 1
      while cursor < chars.count {
        if chars[cursor] == "]" { return (value, cursor + 1) }
        if chars[cursor] == "\\" {
          cursor += 1
          guard cursor < chars.count, chars[cursor] == "]" || chars[cursor] == "\\" else {
            throw invalid()
          }
        }
        value.append(chars[cursor])
        cursor += 1
      }
      throw invalid()
    }
    struct Axis {
      let value: Int
      let locked: Bool
      let end: Int
      let overflow: Bool
    }
    func axis(_ offset: Int, letters: Bool) throws -> Axis? {
      var cursor = offset
      let locked = cursor < chars.count && chars[cursor] == "$"
      if locked { cursor += 1 }
      let begin = cursor
      var value = 0
      var overflow = false
      while cursor < chars.count,
        letters ? asciiLetter(chars[cursor]) : chars[cursor].isASCII && chars[cursor].isNumber
      {
        let digit =
          letters
          ? Int(chars[cursor].uppercased().unicodeScalars.first!.value - 64)
          : Int(String(chars[cursor]))!
        let base = letters ? 26 : 10
        if value > (Int.max - digit) / base { overflow = true }
        if !overflow { value = value * base + digit }
        cursor += 1
      }
      guard cursor > begin else { return nil }
      return Axis(value: value, locked: locked, end: cursor, overflow: overflow)
    }
    func coordinate(_ offset: Int) throws -> (TableCoordinate, Int)? {
      guard let col = try axis(offset, letters: true), let row = try axis(col.end, letters: false)
      else { return nil }
      guard !col.overflow, !row.overflow else { throw invalid() }
      return (
        TableCoordinate(
          row: row.value, column: col.value, rowLocked: row.locked, columnLocked: col.locked),
        row.end
      )
    }
    func boundary(_ offset: Int) -> Bool {
      offset == chars.count
        || !(chars[offset].isLetter || chars[offset].isNumber || chars[offset] == "_")
    }
    if chars[start] == "#", String(chars[start...]).hasPrefix("#REF!{") {
      guard let close = chars[(start + 6)...].firstIndex(of: "}") else { throw invalid() }
      return (.broken(String(chars[start...close])), close + 1)
    }
    if tableFormula, chars[start] == "[", start + 1 < chars.count, chars[start + 1] == "@" {
      if start + 2 < chars.count, chars[start + 2] == "[" {
        let (name, end) = try bracket(start + 2)
        guard end < chars.count, chars[end] == "]" else { throw invalid() }
        return (.currentRow(column: name), end + 1)
      }
      let (name, end) = try bracket(start)
      return (.currentRow(column: String(name.dropFirst())), end)
    }
    var qualifier: String?
    var index = start
    if let (name, end) = try identifier(start), end < chars.count {
      // A call-name token is resolved by the shared parser, even when its
      // spelling looks like an address (log2, atan2, custom names with digits).
      var next = end
      while next < chars.count, chars[next].isWhitespace { next += 1 }
      if chars[start] != "`", next < chars.count, chars[next] == "(" { return nil }
      if chars[end] == "[" {
        let (header, close) = try bracket(end)
        if tableFormula, name.lowercased() == "sheet" { return (.inherited(header), close) }
        return (.namedColumn(table: name, column: header), close)
      }
      if chars[end] == "!", end + 1 < chars.count {
        // Factorial remains ordinary syntax unless followed by an address.
        let beginsCoordinate = try coordinate(end + 1) != nil
        let letterAxis = try axis(end + 1, letters: true)
        let rowAxis = try axis(end + 1, letters: false)
        let beginsAxis = [letterAxis, rowAxis].compactMap { $0 }.contains {
          $0.end < chars.count && chars[$0.end] == ":"
        }
        if beginsCoordinate || beginsAxis {
          qualifier = name
          index = end + 1
        }
      }
    }
    guard tableFormula || qualifier != nil else { return nil }
    if let (first, end) = try coordinate(index), boundary(end) {
      if end < chars.count, chars[end] == ":" {
        var secondIndex = end + 1
        if let (name, namedEnd) = try identifier(secondIndex), namedEnd < chars.count,
          chars[namedEnd] == "!"
        {
          guard name.lowercased() == qualifier?.lowercased() else {
            throw problem(.mixedTableRange, failureRange)
          }
          secondIndex = namedEnd + 1
        }
        guard let (last, close) = try coordinate(secondIndex), boundary(close) else {
          throw invalid()
        }
        return (.rectangle(table: qualifier, first: first, last: last), close)
      }
      return (.cell(table: qualifier, coordinate: first), end)
    }
    for letters in [true, false] {
      guard let first = try axis(index, letters: letters), first.end < chars.count,
        chars[first.end] == ":"
      else { continue }
      var secondIndex = first.end + 1
      if let (name, namedEnd) = try identifier(secondIndex), namedEnd < chars.count,
        chars[namedEnd] == "!"
      {
        guard name.lowercased() == qualifier?.lowercased() else {
          throw problem(.mixedTableRange, failureRange)
        }
        secondIndex = namedEnd + 1
      }
      guard let last = try axis(secondIndex, letters: letters), boundary(last.end) else {
        throw invalid()
      }
      guard !first.overflow, !last.overflow else { throw invalid() }
      let locks = [first.locked, last.locked]
      return (
        letters
          ? .columns(table: qualifier, first: first.value, last: last.value, locks: locks)
          : .rows(table: qualifier, first: first.value, last: last.value, locks: locks), last.end
      )
    }
    if qualifier != nil || chars[start] == "`" { throw invalid() }
    return nil
  }
}

extension Expression {
  /// Iterative semantic walks use these direct children, keeping source
  /// ranges from the shared AST rather than rediscovering syntax in tokens.
  var tableChildren: [Expression] {
    switch self {
    case .literal, .temporal, .identifier, .reference: return []
    case .relative(let value, _, _), .money(let value, _, _),
      .currencyConversion(let value, _, _), .zoneConversion(let value, _, _),
      .prefix(_, let value, _, _), .percentage(let value, _, _),
      .quantity(let value, _, _), .period(let value, _, _),
      .conversion(let value, _, _, _), .grouped(let value, _):
      return [value]
    case .infix(let left, _, let right, _, _),
      .percentageOperation(_, let left, let right, _, _):
      return [left, right]
    case .call(_, _, let arguments, _): return arguments
    case .assistantPrompt(let parts, _, _):
      return parts.compactMap {
        if case .placeholder(let value) = $0 { return value }
        return nil
      }
    }
  }
}
