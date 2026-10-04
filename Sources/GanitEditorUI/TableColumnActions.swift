import AppKit
import GanitEngine

extension ExpandedTableViewController: NSMenuItemValidation {
  package func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let projection else { return false }
    if menuItem.action == #selector(insertCompletion(_:)) { return isEditingCell }
    if hasReviewProjection,
      [
        #selector(insertRowsAbove), #selector(insertRowsBelow), #selector(fillSelection),
        #selector(fillDown), #selector(fillRight), #selector(pasteCells), #selector(pasteFormulas),
      ].contains(menuItem.action)
    {
      return false
    }
    switch menuItem.action {
    case #selector(addRow), #selector(addColumn), #selector(renameCurrentTable),
      #selector(exportTable(_:)):
      return !isEditingCell
    case #selector(renameColumn), #selector(columnSettings), #selector(changeColumnType(_:)),
      #selector(insertColumnBefore), #selector(insertColumnAfter), #selector(setTotal(_:)),
      #selector(clearTotal), #selector(columnRule):
      return !isEditingCell && selectedColumn != nil
    case #selector(clearRule), #selector(resetOverrides):
      return !isEditingCell && selectedColumn?.rule != nil
    case #selector(deleteColumns):
      return !isEditingCell && rectangle.columns.count < projection.columns.count
    default:
      return !isEditingCell && !projection.rows.isEmpty && !projection.columns.isEmpty
    }
  }
  @objc func insertRowsAbove() {
    performEdit {
      try editor.insertTableRows(
        tableID, at: rectangle.rows.lowerBound, count: rectangle.rows.count)
    }
  }
  @objc func insertRowsBelow() {
    performEdit {
      try editor.insertTableRows(
        tableID, at: rectangle.rows.upperBound, count: rectangle.rows.count)
    }
  }
  @objc func insertColumnBefore() { insertColumn(at: rectangle.columns.lowerBound) }
  @objc func insertColumnAfter() { insertColumn(at: rectangle.columns.upperBound) }
  func insertColumn(at index: Int) {
    let headers = Set(projection?.columns.map { $0.header.lowercased() } ?? [])
    var number = index + 1
    while headers.contains("column \(number)") { number += 1 }
    prompt("Insert Column", initial: "Column \(number)") { [weak self] header in
      guard let self else { return }
      performEdit { try editor.insertTableColumn(tableID, at: index, header: header) }
    }
  }
  @objc func renameColumn() {
    guard let column = selectedColumn else { return }
    prompt("Rename Column", initial: column.header) { [weak self] header in
      guard let self else { return }
      performEdit { try editor.renameTableColumn(tableID, column: column.id, to: header) }
    }
  }
  @objc func renameCurrentTable() {
    guard let projection else { return }
    prompt("Rename Table", initial: projection.name) { [weak self] name in
      guard let self else { return }
      performEdit { try editor.renameTable(tableID, to: name) }
    }
  }
  @objc func changeColumnType(_ sender: NSMenuItem) {
    guard let column = selectedColumn, let raw = sender.representedObject as? String,
      let policy = TableInputPolicy(rawValue: raw)
    else { return }
    performEdit { try editor.setTableColumnInput(tableID, column: column.id, policy: policy) }
  }
  @objc func columnSettings() {
    guard let column = selectedColumn, let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = "Column Settings: " + column.header
    alert.informativeText =
      "The type applies to values you enter. Formulas work in either type. Use either a unit or a currency for Value input."
    let policy = NSPopUpButton()
    policy.addItems(withTitles: ["Value", "Text", "Automatic"])
    policy.selectItem(at: column.input == .value ? 0 : column.input == .text ? 1 : 2)
    policy.setAccessibilityLabel("Input type")
    let unit = NSTextField(string: column.unit ?? "")
    let currency = NSTextField(string: column.currency ?? "")
    unit.setAccessibilityLabel("Default unit")
    currency.setAccessibilityLabel("Default currency")
    unit.placeholderString = "For example, kg"
    currency.placeholderString = "For example, USD"
    let format = NSPopUpButton()
    format.addItems(withTitles: ["Automatic", "Percentage"])
    format.selectItem(at: column.percentageDecimals == nil ? 0 : 1)
    format.setAccessibilityLabel("Display format")
    let decimals = NSTextField(string: String(column.percentageDecimals ?? 0))
    decimals.setAccessibilityLabel("Percentage decimals, 0 to 12")
    let stack = NSStackView(views: [
      NSStackView(views: [NSTextField(labelWithString: "Input type"), policy]),
      NSStackView(views: [NSTextField(labelWithString: "Default unit"), unit]),
      NSStackView(views: [NSTextField(labelWithString: "Default currency"), currency]),
      NSStackView(views: [NSTextField(labelWithString: "Display format"), format]),
      NSStackView(views: [NSTextField(labelWithString: "Percentage decimals"), decimals]),
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.frame = NSRect(x: 0, y: 0, width: 360, height: 172)
    for row in stack.arrangedSubviews {
      row.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }
    alert.accessoryView = stack
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let text = policy.indexOfSelectedItem == 1
      let u = unit.stringValue.trimmingCharacters(in: .whitespaces)
      let c = currency.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
      performEdit {
        editor.documentUndoManager.beginUndoGrouping()
        defer { editor.documentUndoManager.endUndoGrouping() }
        try editor.editTables("Change Column Format") {
          try $0.setColumnPresentation(
            table: tableID, column: column.id,
            percentageDecimals: format.indexOfSelectedItem == 1 ? decimals.integerValue : nil)
        }
        try editor.setTableColumnInput(
          tableID, column: column.id,
          policy: text ? .text : policy.indexOfSelectedItem == 2 ? .automatic : .value,
          unit: policy.indexOfSelectedItem != 0 || u.isEmpty ? nil : u,
          currency: policy.indexOfSelectedItem != 0 || c.isEmpty ? nil : c)
      }
    }
  }
}
