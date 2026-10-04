import Foundation

/// A source projection for an editor. It is not a document store.
package struct TableEditingSnapshot: Sendable {
  package struct Column: Sendable {
    package let id: ColumnID
    package let header: String
    package let rule: String?
    package let input: TableInputPolicy
    package let total: TableTotal?
    package let unit: String?
    package let currency: String?
  }
  package let utf8Range: Range<Int>
  package let id: TableID
  package let name: String
  package let rows: [RowID]
  package let columns: [Column]
  private let cells: [TableCellPosition: String]
  package init?(_ document: TableSourceDocument, id: TableID) {
    guard let block = document.blocks.first(where: { $0.table?.id == id }), let table = block.table
    else {
      return nil
    }
    utf8Range = block.utf8Range
    self.id = id
    name = table.name
    rows = table.rows
    columns = table.columns.map {
      Column(
        id: $0.id, header: $0.header, rule: $0.rule, input: $0.input, total: $0.total,
        unit: $0.unit, currency: $0.currency)
    }
    let axes = TableAxes(table)
    cells = Dictionary(
      uniqueKeysWithValues: table.cells.compactMap { cell in
        guard let row = axes.rows[cell.row], let column = axes.columns[cell.column] else {
          return nil
        }
        return (TableCellPosition(row: row, column: column), cell.source)
      })
  }
  /// Resolve a canonical source hit to its data cell or column rule anchor.
  package func cell(atUTF8 offset: Int, in document: TableSourceDocument) -> TableCellPosition? {
    guard let block = document.blocks.first(where: { $0.table?.id == id }), let json = block.json,
      let ids = json["ids"]?.array?.compactMap(\.string)
    else { return nil }
    for record in json["x"]?.array ?? [] {
      guard let source = record["s"], block.sheetRange(of: source).contains(offset),
        let address = record["a"]?.array, address.count == 2,
        let rowPointer = address[0].index, let columnPointer = address[1].index,
        ids.indices.contains(rowPointer), ids.indices.contains(columnPointer),
        let row = rows.firstIndex(where: { $0.string == ids[rowPointer] }),
        let column = columns.firstIndex(where: { $0.id.string == ids[columnPointer] })
      else { continue }
      return .init(row: row, column: column)
    }
    for record in json["c"]?.array ?? [] {
      guard block.sheetRange(of: record).contains(offset), let pointer = record["i"]?.index,
        ids.indices.contains(pointer),
        let column = columns.firstIndex(where: { $0.id.string == ids[pointer] })
      else { continue }
      return .init(row: 0, column: column)
    }
    return nil
  }
  package func brokenReferenceRange(in source: String) -> NSRange? {
    guard let syntax = try? TableFormulaSyntax.discover(source),
      let reference = syntax.references.first(where: {
        if case .broken = $0.syntax { return true }
        return false
      }),
      let lower = source.utf8.index(
        source.utf8.startIndex, offsetBy: reference.range.lowerBound,
        limitedBy: source.utf8.endIndex),
      let upper = source.utf8.index(
        source.utf8.startIndex, offsetBy: reference.range.upperBound,
        limitedBy: source.utf8.endIndex),
      let start = String.Index(lower, within: source), let end = String.Index(upper, within: source)
    else { return nil }
    return NSRange(start..<end, in: source)
  }
  package func referencedCells(in source: String, row currentRow: Int? = nil) -> Set<
    TableCellPosition
  > {
    guard let syntax = try? TableFormulaSyntax.discover(source) else { return [] }
    var result: Set<TableCellPosition> = []
    for reference in syntax.references {
      switch reference.syntax {
      case .cell(let table, let coordinate)
      where table == nil || table?.lowercased() == name.lowercased():
        let cell = TableCellPosition(row: coordinate.row - 2, column: coordinate.column - 1)
        if rows.indices.contains(cell.row), columns.indices.contains(cell.column) {
          result.insert(cell)
        }
      case .rectangle(let table, let first, let last)
      where table == nil || table?.lowercased() == name.lowercased():
        let lowerRow = max(0, min(first.row, last.row) - 2)
        let upperRow = min(rows.count, max(first.row, last.row) - 1)
        let lowerColumn = max(0, min(first.column, last.column) - 1)
        let upperColumn = min(columns.count, max(first.column, last.column))
        guard lowerRow < upperRow, lowerColumn < upperColumn else { continue }
        let rowRange = lowerRow..<upperRow
        let columnRange = lowerColumn..<upperColumn
        for row in rowRange {
          for column in columnRange { result.insert(.init(row: row, column: column)) }
        }
      case .currentRow(let header):
        if let row = currentRow, rows.indices.contains(row),
          let column = columns.firstIndex(where: { $0.header.lowercased() == header.lowercased() })
        {
          result.insert(.init(row: row, column: column))
        }
      case .namedColumn(let table, let header) where table.lowercased() == name.lowercased():
        if let column = columns.firstIndex(where: { $0.header.lowercased() == header.lowercased() })
        {
          for row in rows.indices { result.insert(.init(row: row, column: column)) }
        }
      default: break
      }
    }
    return result
  }
  package func source(at position: TableCellPosition) -> String {
    cells[position] ?? columns[position.column].rule ?? ""
  }
  package func isOverride(at position: TableCellPosition) -> Bool {
    columns[position.column].rule != nil && cells[position] != nil
  }
}

extension TableSourceDocument {
  package var editingTableIDs: [TableID] { blocks.compactMap { $0.table?.id } }
  package var editingSource: String { source }
}
