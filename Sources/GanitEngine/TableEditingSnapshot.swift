import Foundation

/// A source projection for an editor. It is not a document store.
package struct TableEditingSnapshot: Sendable {
  package struct Column: Sendable {
    package let id: ColumnID
    package let header: String
    package let rule: String?
    package let input: TableInputPolicy
    package let total: TableTotal?
  }
  package let id: TableID
  package let name: String
  package let rows: [RowID]
  package let columns: [Column]
  private let cells: [TableCellPosition: String]
  package init?(_ document: TableSourceDocument, id: TableID) {
    guard let table = document.blocks.compactMap(\.table).first(where: { $0.id == id }) else { return nil }
    self.id = id
    name = table.name
    rows = table.rows
    columns = table.columns.map { Column(id: $0.id, header: $0.header, rule: $0.rule, input: $0.input, total: $0.total) }
    let axes = TableAxes(table)
    cells = Dictionary(uniqueKeysWithValues: table.cells.compactMap { cell in
      guard let row = axes.rows[cell.row], let column = axes.columns[cell.column] else { return nil }
      return (TableCellPosition(row: row, column: column), cell.source)
    })
  }
  package func brokenReferenceRange(in source: String) -> NSRange? {
    guard let syntax = try? TableFormulaSyntax.discover(source),
      let reference = syntax.references.first(where: { if case .broken = $0.syntax { return true }; return false }),
      let lower = source.utf8.index(source.utf8.startIndex, offsetBy: reference.range.lowerBound, limitedBy: source.utf8.endIndex),
      let upper = source.utf8.index(source.utf8.startIndex, offsetBy: reference.range.upperBound, limitedBy: source.utf8.endIndex),
      let start = String.Index(lower, within: source), let end = String.Index(upper, within: source) else { return nil }
    return NSRange(start..<end, in: source)
  }
  package func referencedCells(in source: String) -> Set<TableCellPosition> {
    guard let syntax = try? TableFormulaSyntax.discover(source) else { return [] }
    var result: Set<TableCellPosition> = []
    for reference in syntax.references {
      switch reference.syntax {
      case .cell(let table, let coordinate) where table == nil || table?.lowercased() == name.lowercased():
        let cell = TableCellPosition(row: coordinate.row - 2, column: coordinate.column - 1)
        if rows.indices.contains(cell.row), columns.indices.contains(cell.column) { result.insert(cell) }
      case .rectangle(let table, let first, let last) where table == nil || table?.lowercased() == name.lowercased():
        let rowRange = max(0, min(first.row, last.row) - 2)..<min(rows.count, max(first.row, last.row) - 1)
        let columnRange = max(0, min(first.column, last.column) - 1)..<min(columns.count, max(first.column, last.column))
        for row in rowRange { for column in columnRange { result.insert(.init(row: row, column: column)) } }
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
