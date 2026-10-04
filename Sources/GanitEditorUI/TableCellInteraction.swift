import AppKit
import GanitEngine

extension ExpandedTableViewController {
  func normalizedCellInput(_ source: String) -> String {
    TableCellInput.normalized(
      source, policy: selectedColumn?.input ?? .value, context: editor.tableEvaluationContext)
  }

  func moveAfterCommit(horizontal: Bool, backwards: Bool) {
    guard let projection, !projection.columns.isEmpty else { return }
    var target = position
    var row = visibleRow(position.row) ?? 0
    let direction = backwards ? -1 : 1
    if horizontal {
      target.column += direction
      if target.column >= projection.columns.count {
        target.column = 0
        row += 1
      }
      if target.column < 0 {
        target.column = projection.columns.count - 1
        row -= 1
      }
    } else {
      row += direction
    }
    if row == displayedRows.count && !backwards && !hasReviewProjection {
      performEdit { try editor.appendTableRows(tableID) }
    }
    target.row = canonicalRow(row) ?? position.row
    select(target)
  }

  @objc func fillDown() { fillAcrossSelection(down: true) }
  @objc func fillRight() { fillAcrossSelection(down: false) }
  private func fillAcrossSelection(down: Bool) {
    guard permitsRectangleEdit() else { return }
    performEdit {
      let selection = rectangle
      let before = editor.sheet.text
      var document = TableSourceDocument(editor.sheet)
      let indices = down ? selection.columns : selection.rows
      for index in indices {
        let origin = TableCellPosition(
          row: down ? selection.rows.lowerBound : index,
          column: down ? index : selection.columns.lowerBound)
        let area = TableCellRectangle(
          rows: down ? selection.rows : index..<(index + 1),
          columns: down ? index..<(index + 1) : selection.columns)
        let edit = try document.fill(table: tableID, from: origin, into: area)
        document = TableSourceDocument(try edit.applying(to: document.editingSource))
      }
      try editor.replaceTableSource(
        before: before, after: document.editingSource, action: down ? "Fill Down" : "Fill Right")
    }
  }
  @objc func editSelectedCell() { beginEditing(inline: true) }
  @objc func selectAllCells(_ sender: Any?) {
    guard let projection, !projection.rows.isEmpty, !projection.columns.isEmpty else { return }
    cancelEditing()
    select(.init(row: displayedRows.first ?? 0, column: 0))
    select(
      .init(
        row: displayedRows.last ?? projection.rows.count - 1, column: projection.columns.count - 1),
      extending: true)
  }
  @objc func clearCells() {
    performEdit {
      let before = editor.sheet.text
      var document = TableSourceDocument(editor.sheet)
      for row in selectionRows {
        for column in rectangle.columns {
          let edit = try document.setCell(
            table: tableID, at: .init(row: row, column: column), source: "")
          document = TableSourceDocument(try edit.applying(to: document.editingSource))
        }
      }
      try editor.replaceTableSource(
        before: before, after: document.editingSource, action: "Clear Cells")
    }
  }
}

enum TableCellInput {
  static func normalized(
    _ source: String, policy: TableInputPolicy = .value, context: EvaluationContext? = nil
  ) -> String {
    let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.hasPrefix("=") else { return input }
    // Function entry is deliberate formula input. Plain words remain data.
    let function = #"(?i)^(sum|total|average|avg|median|min|max|count)\s*\("#
    if input.range(of: function, options: .regularExpression) != nil { return "=" + input }
    if policy != .text, let context,
      let expression = CalculationEngine().parse(input, context: context).expression,
      expression.isArithmetic, !expression.isTableLiteral(in: input)
    {
      return "=" + input
    }
    return source
  }

}
