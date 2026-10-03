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
  package func source(at position: TableCellPosition) -> String {
    cells[position] ?? columns[position.column].rule ?? ""
  }
  package func isOverride(at position: TableCellPosition) -> Bool {
    columns[position.column].rule != nil && cells[position] != nil
  }
}
