import AppKit
import GanitEngine
import GanitFormatting

extension ExpandedTableViewController {
  var displayedRows: [Int] { displayOrder }
  var selectionRows: [Int] {
    guard let start = visibleRow(anchor.row), let end = visibleRow(position.row) else { return [] }
    return Array(displayedRows[min(start, end)...max(start, end)])
  }
  var hasReviewProjection: Bool {
    projection?.columns.contains(where: { $0.reviewSort != nil || $0.reviewFilter != nil }) == true
  }
  func permitsRectangleEdit() -> Bool {
    guard !hasReviewProjection else {
      status.stringValue =
        "Clear sort and filters before Fill or rectangular paste. You can edit individual cells."
      return false
    }
    return true
  }
  func canonicalRow(_ visible: Int) -> Int? {
    displayedRows.indices.contains(visible) ? displayedRows[visible] : nil
  }
  func visibleRow(_ canonical: Int) -> Int? { displayedRows.firstIndex(of: canonical) }
  var hasTotalRow: Bool { projection?.columns.contains(where: { $0.total != nil }) == true }
  func cellProblem(row: Int, column: Int) -> String? {
    guard let projection, projection.rows.indices.contains(row),
      projection.columns.indices.contains(column)
    else { return nil }
    let r = projection.rows[row]
    let c = projection.columns[column].id
    return result?.cellProblem(row: r, column: c)
      ?? result?.cellError(row: r, column: c).map(editor.formatTableError)
  }
  func cellDisplay(row: Int, column: Int, explainsErrors: Bool = false) -> String {
    guard let projection, projection.rows.indices.contains(row),
      projection.columns.indices.contains(column)
    else { return "" }
    let c = projection.columns[column].id
    switch result?.value(row: projection.rows[row], column: c) {
    case .value(let scalar):
      return editor.formatTableValue(scalar, column: c, result: result)?.display ?? ""
    case .failure:
      return explainsErrors
        ? cellProblem(row: row, column: column) ?? "Invalid input or reference." : "Error"
    default: return display(result?.value(row: projection.rows[row], column: c))
    }
  }
  func totalDisplay(column index: Int) -> String {
    guard let projection, projection.columns.indices.contains(index),
      let total = projection.columns[index].total
    else { return "" }
    let column = projection.columns[index]
    if total == .sum, let groups = result?.currencyTotals(column: column.id) {
      return groups.map { $0.0 + ": " + (editor.formatTableValue($0.1)?.display ?? "") }.joined(
        separator: " · ")
    }
    if let value = result?.aggregate(
      total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
    {
      return editor.formatTableValue(value, column: column.id, result: result)?.display ?? ""
    }
    return result == nil
      ? "Pending…" : "Cannot total these values. Check cell errors and value types."
  }
  func setReview(sort: String?, filter: String?, frozen: Bool) {
    guard let column = selectedColumn else { return }
    performEdit {
      try editor.editTables("Change Table Review") {
        try $0.setColumnReview(
          table: tableID, column: column.id, sort: sort, filter: filter, frozen: frozen)
      }
    }
  }
  @objc func sortAscending() {
    setReview(
      sort: "ascending", filter: selectedColumn?.reviewFilter,
      frozen: selectedColumn?.frozen ?? false)
  }
  @objc func sortDescending() {
    setReview(
      sort: "descending", filter: selectedColumn?.reviewFilter,
      frozen: selectedColumn?.frozen ?? false)
  }
  @objc func clearSort() {
    setReview(
      sort: nil, filter: selectedColumn?.reviewFilter, frozen: selectedColumn?.frozen ?? false)
  }
  @objc func filterColumn() {
    prompt(
      "Show rows that contain text or a currency code", initial: selectedColumn?.reviewFilter ?? ""
    ) { [weak self] text in
      guard let self else { return }
      setReview(
        sort: selectedColumn?.reviewSort, filter: text.isEmpty ? nil : text,
        frozen: selectedColumn?.frozen ?? false)
    }
  }
  @objc func clearFilter() {
    setReview(
      sort: selectedColumn?.reviewSort, filter: nil, frozen: selectedColumn?.frozen ?? false)
  }
  @objc func freezeColumn() {
    setReview(
      sort: selectedColumn?.reviewSort, filter: selectedColumn?.reviewFilter,
      frozen: !(selectedColumn?.frozen ?? false))
  }
  @objc func percentageFormat() {
    guard let column = selectedColumn else { return }
    prompt("Percentage decimal places (0 to 12)", initial: String(column.percentageDecimals ?? 0)) {
      [weak self] text in
      guard let self, let digits = Int(text), (0...12).contains(digits) else { return }
      performEdit {
        try editor.editTables("Format Percentage") {
          try $0.setColumnPresentation(
            table: tableID, column: column.id, percentageDecimals: digits)
        }
      }
    }
  }
  @objc func automaticFormat() {
    guard let column = selectedColumn else { return }
    performEdit {
      try editor.editTables("Format Automatic") {
        try $0.setColumnPresentation(table: tableID, column: column.id, percentageDecimals: nil)
      }
    }
  }
  @objc func useFormulaInput() {
    if !isEditingCell { beginEditing() }
    let source = formula.stringValue
    guard !source.hasPrefix("=") else { return }
    editingInput.stringValue = "=" + source
    formula.stringValue = editingInput.stringValue
    view.window?.makeFirstResponder(editingInput)
  }

  func refreshFrozenColumn() {
    let index = projection?.columns.firstIndex(where: { $0.frozen })
    frozenScroll.isHidden = index == nil
    frozenGrid.frozenColumn = index
    for column in frozenGrid.tableColumns { frozenGrid.removeTableColumn(column) }
    guard let index, let projection else { return }
    let row = NSTableColumn(identifier: .init("row"))
    row.width = 38
    let label = NSTableColumn(identifier: .init(projection.columns[index].id.uuid.uuidString))
    label.title = projection.columns[index].header
    label.width = 130
    frozenGrid.addTableColumn(row)
    frozenGrid.addTableColumn(label)
    frozenGrid.reloadData()
    frozenScroll.contentView.scroll(to: .init(x: 0, y: scroll.contentView.bounds.minY))
  }

  func fitNumericColumns() {
    guard let projection, result != nil else { return }
    let font = VisualStyle.Typography.answer(scale: 1)
    for (index, column) in projection.columns.enumerated()
    where grid.tableColumns.indices.contains(index + 1) {
      var width: CGFloat = 0
      for row in projection.rows.indices.prefix(200) {
        if case .value = result?.value(row: projection.rows[row], column: column.id) {
          width = max(
            width,
            (cellDisplay(row: row, column: index) as NSString).size(withAttributes: [.font: font])
              .width + 28)
        }
      }
      grid.tableColumns[index + 1].width = max(grid.tableColumns[index + 1].width, min(600, width))
    }
  }
}
