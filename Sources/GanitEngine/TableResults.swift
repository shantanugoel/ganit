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
      block.projection?.columns.map { TableResultColumn(id: $0.id, header: $0.header) } ?? []
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

  package func aggregate(_ function: TableTotal, rectangle: TableCellRectangle) -> EngineValue? {
    guard let snapshot = block.calculation,
      rectangle.rows.lowerBound >= 0, rectangle.rows.upperBound <= rows.count,
      rectangle.columns.lowerBound >= 0, rectangle.columns.upperBound <= columns.count,
      let operation = TableRangeFunction(name: function.rawValue) else { return nil }
    var values: [EngineValue] = []
    for row in rectangle.rows { for column in rectangle.columns {
      switch value(row: rows[row], column: columns[column].id) {
      case .value(let scalar): values.append(scalar)
      case .text, .blank: break
      default: return nil
      }
    } }
    let reduced = TableRangeReducer(context: snapshot.context, limits: .default).reduce(operation, values) {
      tableTypedZero(snapshot.table, axes: snapshot.axes, columns: rectangle.columns.map { columns[$0].id },
        engine: CalculationEngine(), context: snapshot.context, scalarBudget: nil)
    }
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
