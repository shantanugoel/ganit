import Foundation

/// An original failing table cell that a sheet line's failure comes from: a
/// failed cell a qualified operand read, a cycle participant's failing read,
/// or the first input a blocked cell waited on. A whole table that could not
/// be calculated has no column.
public struct TableCellFailureOrigin: Hashable, Sendable {
  public let table: TableID
  /// `nil` for a header cell, or for a whole table.
  public let row: RowID?
  /// `nil` for a whole table.
  public let column: ColumnID?
  /// The failing read in the cell's own source or inherited rule, when the
  /// cell has one.
  public let formulaRange: SourceRange?

  init(table: TableID, row: RowID?, column: ColumnID?, formulaRange: SourceRange?) {
    self.table = table
    self.row = row
    self.column = column
    self.formulaRange = formulaRange
  }

  init(_ origin: TableFailureOrigin) {
    self.init(
      table: origin.address.table, row: origin.address.row, column: origin.address.column,
      formulaRange: origin.range)
  }

  /// At most this many causes are carried for one failure, in canonical
  /// order; a reader blocked on a large failed range names its first ones.
  static let carriedLimit = 8
}

/// A column of a table result, in display order.
public struct TableResultColumn: Hashable, Sendable {
  public let id: ColumnID
  /// Literal header text.
  public let header: String
  /// The column's totals footer, or `nil` without one. Operands read data
  /// rows only.
  public let total: TableTotal?
}

/// What a table cell holds in one generation.
public enum TableCellValue: Hashable, Sendable {
  case value(EngineValue)
  case text(String)
  case blank
  /// The cell failed; `origins` are its original causes.
  case failure(origins: [TableCellFailureOrigin])
}

/// One table block's result in a sheet evaluation: an immutable read-only
/// view for editors and exports, keyed by the table's identity and its
/// block's source span. A quarantined block has no identity and no values.
public struct TableResultSnapshot: Sendable {
  /// `nil` for a block with diagnostics, which is never calculated.
  public let id: TableID?
  public let name: String?
  /// The block in sheet UTF-8 offsets, including the closer's terminator.
  public let utf8Range: Range<Int>
  /// Zero-based physical source lines, opener and closer included.
  public let physicalLines: Range<Int>
  public let diagnostics: [TableSourceDiagnostic]
  public let columns: [TableResultColumn]
  /// Data rows in order; row 2 in A1 addresses is the first.
  public let rows: [RowID]
  /// Why a valid table has no values in this generation, such as a resource
  /// limit. Lines that read it fail explicitly.
  public let calculationFailure: EngineError?
  let block: TableBlockResult

  init(_ block: TableBlockResult) {
    self.block = block
    id = block.projection?.id
    name = block.projection?.name
    utf8Range = block.utf8Range
    physicalLines = block.physicalLines
    diagnostics = block.diagnostics
    columns =
      block.projection?.columns.map {
        TableResultColumn(id: $0.id, header: $0.header, total: $0.total)
      } ?? []
    rows = block.projection?.rows ?? []
    calculationFailure = block.calculationFailure
  }

  /// Whether this generation calculated values for the table.
  public var isCalculated: Bool { block.calculation != nil }

  /// The earliest moment a cell that read the clock can change, or `nil`.
  public var nextRecalculation: Date? { block.calculation?.nextRecalculation }

  /// A cell's value, a header's text for a `nil` row, or `nil` outside the
  /// table or when it was not calculated.
  public func value(row: RowID?, column: ColumnID) -> TableCellValue? {
    guard let id, let snapshot = block.calculation,
      let result = snapshot.result(at: TableCellAddress(table: id, row: row, column: column))
    else { return nil }
    switch result {
    case .scalar(let value): return .value(value)
    case .text(let text): return .text(text)
    case .blank: return .blank
    case .failure(let failure):
      return .failure(
        origins: failure.origins(prefix: TableCellFailureOrigin.carriedLimit).map(
          TableCellFailureOrigin.init))
    }
  }

  package func cellError(row: RowID, column: ColumnID) -> EngineError? {
    guard let id,
      case .failure(let failure) = block.calculation?.result(
        at: TableCellAddress(table: id, row: row, column: column))
    else { return nil }
    return failure.engineError
  }
  package func cellProblem(row: RowID, column: ColumnID) -> String? {
    guard let id, let snapshot = block.calculation,
      case .failure(let failure) = snapshot.result(at: .init(table: id, row: row, column: column))
    else { return nil }
    let source = snapshot.sources[.init(table: id, row: row, column: column)] ?? ""
    let part = failure.referenceDiagnostic?.range.text(in: source).map(String.init) ?? ""
    switch failure.referenceDiagnostic?.code {
    case .unsupportedFunction:
      return
        "The function \(part) is not supported in tables. Use arithmetic or a supported aggregate such as =SUM(B2:B6)."
    case .unsupportedComparison:
      return
        "The comparison \(part) is not supported in tables. Calculate the difference to compare two values."
    case .assistantPrompt: return "Assistant prompts are not supported in table formulas."
    default: break
    }
    switch failure.code {
    case .scalarRequired:
      let reference = failure.sourceRange.text(in: source).map(String.init) ?? "This reference"
      switch failure.scalarInput {
      case .textColumn(let header):
        return
          "\(reference) contains text because column \"\(header)\" uses Text input. This formula requires a value. Change the column's Input Type to Automatic or Value."
      case .text:
        return
          "\(reference) contains text. This formula requires a value. Replace the text with a number or another value."
      case .header:
        return
          "\(reference) refers to a column header, which contains text. This formula requires a value. Use a data cell from row 2 or below."
      case .blank:
        return
          "\(reference) is blank. This formula requires a value. Enter a number or another value in that cell."
      case nil:
        return
          "This formula requires a value. Check the highlighted reference for text or a blank cell."
      }
    case .inputRequiresFormula: return "Start arithmetic input with =. For example, =" + source
    case .unsupportedRangeOperation:
      return
        "This range argument pattern is not supported. Use one range per aggregate, for example =SUM(B2:B3) + SUM(B5:B6)."
    case .cycle: return "These cells refer to each other. Remove a reference to stop the cycle."
    case .blocked: return "An input has an error. Go to the original failure."
    case .emptyRange: return "This range has no numeric values."
    case .invalidLiteral: return "Use Automatic or Text input for a label. Start a formula with =."
    default:
      return failure.engineError == nil
        ? "The input or reference is invalid. Check the highlighted source." : nil
    }
  }

  package func problemRange(row: RowID, column: ColumnID) -> NSRange? {
    guard let id, let snapshot = block.calculation,
      case .failure(let failure) = snapshot.result(at: .init(table: id, row: row, column: column)),
      let source = snapshot.sources[.init(table: id, row: row, column: column)],
      let range = (failure.referenceDiagnostic?.range ?? failure.sourceRange).text(in: source),
      let found = source.range(of: String(range))
    else { return nil }
    return NSRange(found, in: source)
  }

  package var noteDefinitions: [(String, EngineValue)] {
    block.calculation?.noteDefinitions ?? []
  }

  package func percentageValue(_ value: EngineValue, column: ColumnID) -> EngineValue {
    guard block.projection?.columns.first(where: { $0.id == column })?.percentageDecimals != nil,
      case .number(let number) = value, let context = block.calculation?.context,
      let points = try? NumericOperations(context: context, limits: .default).applying(
        .multiply, left: number, right: .integer(IntegerValue(100)))
    else { return value }
    return .percentage(PercentageValue(points: points))
  }

  package func interpretation(row: RowID, column: ColumnID) -> [(String, String)] {
    guard let id, let snapshot = block.calculation else { return [] }
    let address = TableCellAddress(table: id, row: row, column: column)
    var details: [(String, String)] = []
    if let source = snapshot.sources[address] { details.append(("Source", source)) }
    if case .failure(let failure) = snapshot.result(at: address) {
      details.append(
        (
          "Problem",
          failure.referenceDiagnostic?.code.rawValue ?? failure.engineError?.code.rawValue
            ?? failure.code.rawValue
        ))
    }
    if let provenance = snapshot.provenance[address] {
      if let clock = provenance.clock { details.append(("Clock", String(describing: clock))) }
      for rate in provenance.rateUses {
        details.append(("Currency rate", String(describing: rate)))
      }
      for finance in provenance.financeUses {
        details.append(("Finance assumption", finance.rawValue))
      }
    }
    return details
  }
  package func percentageDecimals(column: ColumnID) -> Int? {
    block.projection?.columns.first(where: { $0.id == column })?.percentageDecimals
  }

  package func reviewRows() -> [Int] {
    guard let snapshot = block.calculation else { return Array(rows.indices) }
    let table = snapshot.table
    var shown = Array(rows.indices).filter { row in
      table.columns.allSatisfy { column in
        guard let filter = column.reviewFilter, !filter.isEmpty else { return true }
        let source =
          snapshot.sources[.init(table: table.id, row: rows[row], column: column.id)] ?? ""
        if case .value(.money(let money)) = value(row: rows[row], column: column.id),
          money.currency.localizedCaseInsensitiveContains(filter)
        {
          return true
        }
        if case .text(let text) = value(row: rows[row], column: column.id) {
          return text.localizedCaseInsensitiveContains(filter)
        }
        return source.localizedCaseInsensitiveContains(filter)
      }
    }
    if let column = table.columns.first(where: { $0.reviewSort != nil }) {
      let reducer = TableRangeReducer(context: snapshot.context, limits: .default)
      // Keep incompatible value groups separate. Within each group the
      // comparison is typed; ties retain source order.
      var representatives: [TableCellValue] = []
      var groups: [Int: Int] = [:]
      for row in shown {
        let cell = value(row: rows[row], column: column.id) ?? .blank
        let index = representatives.firstIndex { candidate in
          switch (candidate, cell) {
          case (.value(let a), .value(let b)): return (try? reducer.ordering(a, b)) != nil
          case (.text, .text), (.blank, .blank), (.failure, .failure): return true
          default: return false
          }
        }
        groups[row] = index ?? representatives.count
        if index == nil { representatives.append(cell) }
      }
      shown.sort { left, right in
        let a = value(row: rows[left], column: column.id)
        let b = value(row: rows[right], column: column.id)
        switch (a, b) {
        case (.blank, .blank), (.failure, .failure): return left < right
        case (.blank, .failure): return true
        case (.failure, .blank): return false
        case (.blank, _), (.failure, _): return false
        case (_, .blank), (_, .failure): return true
        default: break
        }
        if groups[left] != groups[right] {
          return groups[left, default: 0] < groups[right, default: 0]
        }
        let order: Int
        switch (a, b) {
        case (.value(let a), .value(let b)): order = (try? reducer.ordering(a, b)) ?? 0
        case (.text(let a), .text(let b)): order = a.localizedStandardCompare(b).rawValue
        case (.blank, .blank), (.failure, .failure): order = 0
        case (.blank, _), (.failure, _): return false
        case (_, .blank), (_, .failure): return true
        default: order = 0
        }
        if order == 0 { return left < right }
        return column.reviewSort == "descending" ? order > 0 : order < 0
      }
    }
    return shown
  }

  package func currencyTotals(column: ColumnID) -> [(String, EngineValue)]? {
    guard let snapshot = block.calculation else { return nil }
    var groups: [String: [EngineValue]] = [:]
    for row in rows {
      switch value(row: row, column: column) {
      case .value(.money(let money)): groups[money.currency, default: []].append(.money(money))
      case .blank, .text: break
      default: return nil
      }
    }
    guard groups.count > 1 else { return nil }
    let reducer = TableRangeReducer(context: snapshot.context, limits: .default)
    return groups.keys.sorted().compactMap { currency in
      if case .success(let sum) = reducer.reduce(.sum, groups[currency]!, typedZero: { nil }) {
        return (currency, sum)
      }
      return nil
    }
  }

  package func aggregate(_ function: TableTotal, rectangle: TableCellRectangle) -> EngineValue? {
    guard let snapshot = block.calculation,
      rectangle.rows.lowerBound >= 0, rectangle.rows.upperBound <= rows.count,
      rectangle.columns.lowerBound >= 0, rectangle.columns.upperBound <= columns.count,
      let operation = TableRangeFunction(name: function.rawValue)
    else { return nil }
    var values: [EngineValue] = []
    for row in rectangle.rows {
      for column in rectangle.columns {
        switch snapshot.result(
          at: TableCellAddress(table: snapshot.table.id, row: rows[row], column: columns[column].id)
        ) {
        case .scalar(let scalar): values.append(scalar)
        case .text, .blank: break
        default: return nil
        }
      }
    }
    let reduced = TableRangeReducer(context: snapshot.context, limits: .default).reduce(
      operation, values
    ) {
      tableTypedZero(
        snapshot.table, axes: snapshot.axes, columns: rectangle.columns.map { columns[$0].id },
        engine: CalculationEngine(), context: snapshot.context, scalarBudget: nil)
    }
    if case .success(let value) = reduced { return value }
    return nil
  }

  package func aggregate(_ function: TableTotal, rowIndices: [Int], columns indices: Range<Int>)
    -> EngineValue?
  {
    guard let snapshot = block.calculation,
      let operation = TableRangeFunction(name: function.rawValue),
      rowIndices.allSatisfy({ rows.indices.contains($0) }), indices.lowerBound >= 0,
      indices.upperBound <= columns.count
    else { return nil }
    var values: [EngineValue] = []
    for row in rowIndices {
      for column in indices {
        switch value(row: rows[row], column: columns[column].id) {
        case .value(let scalar): values.append(scalar)
        case .blank, .text: break
        default: return nil
        }
      }
    }
    let reduced = TableRangeReducer(context: snapshot.context, limits: .default).reduce(
      operation, values
    ) { nil }
    if case .success(let value) = reduced { return value }
    return nil
  }

  /// The qualified A1 address of a cell, such as `Items!C3`; the header row
  /// is 1. `nil` outside the table.
  public func address(row: RowID?, column: ColumnID) -> String? {
    guard let name, let columnIndex = columns.firstIndex(where: { $0.id == column }) else {
      return nil
    }
    var number = 1
    if let row {
      guard let index = rows.firstIndex(of: row) else { return nil }
      number = index + 2
    }
    return TableSourceDocument.identifier(name) + "!"
      + TableSourceDocument.letters(columnIndex) + String(number)
  }
}

extension SheetEvaluation {
  /// Every table block of this generation's source, in order.
  public var tableResults: [TableResultSnapshot] { tables.map(TableResultSnapshot.init) }

  /// The result of the table with this identity.
  public func tableResult(_ id: TableID) -> TableResultSnapshot? {
    table(id).map(TableResultSnapshot.init)
  }

  /// The result of the block containing a zero-based physical line.
  public func tableResult(atLine index: Int) -> TableResultSnapshot? {
    tables.first { $0.physicalLines.contains(index) }.map(TableResultSnapshot.init)
  }
}

extension TableSourceDocument {
  /// The source of a failure origin in `sheet`, in UTF-8 offsets: the cell's
  /// input record, its inherited column rule, a header, or the whole block
  /// for a table. Origins resolve by identity, so the current source is
  /// searched even when the evaluation that reported them is older; `nil`
  /// when the table is gone.
  public static func sourceRange(of origin: TableCellFailureOrigin, in sheet: SheetSource)
    -> Range<Int>?
  {
    let document = TableSourceDocument(sheet)
    guard
      let block = document.blocks.first(where: {
        ($0.table ?? $0.candidate)?.id == origin.table
      })
    else { return nil }
    guard let column = origin.column, let json = block.json,
      let ids = json["ids"]?.array?.map({ $0.string })
    else { return block.utf8Range }
    func pointer(_ uuid: UUID) -> Int? {
      ids.firstIndex { $0 == TableIdentity<TableIdentityKind>(uuid).string }
    }
    let columnPointer = pointer(column.uuid)
    let columnRecord = json["c"]?.array?.first { $0["i"]?.index == columnPointer }
    if let row = origin.row {
      let rowPointer = pointer(row.uuid)
      if let cell = json["x"]?.array?.first(where: {
        let address = $0["a"]?.array
        return address?.count == 2 && address?[0].index == rowPointer
          && address?[1].index == columnPointer
      }), let source = cell["s"] {
        return block.sheetRange(of: source)
      }
      if let rule = columnRecord?["f"] { return block.sheetRange(of: rule) }
    } else if let header = columnRecord?["h"] {
      return block.sheetRange(of: header)
    }
    return columnRecord.map(block.sheetRange(of:)) ?? block.utf8Range
  }
}
