import AppKit
import GanitEngine
import GanitFormatting

private struct TableCopyPayload: Codable {
  let version: Int
  let source: String
  let table: UUID
  let rows: [Int]
  let columns: [Int]
}

extension ExpandedTableViewController {
  private static var copyType: NSPasteboard.PasteboardType { .init("app.ganit.table-range.v1") }

  @objc func showActions() {
    let menu = actionsMenu()
    menu.popUp(positioning: nil, at: NSPoint(x: 12, y: view.bounds.maxY - 60), in: view)
  }

  /// The Table Actions menu, so tests can list the commands it offers.
  func actionsMenu() -> NSMenu {
    let menu = NSMenu()
    addCommands(
      to: menu,
      [
        ("Rename Table…", #selector(renameCurrentTable)),
        ("Add Row at End", #selector(addRow)),
        ("Add Column at End…", #selector(addColumn)),
        ("Export Table…", #selector(exportTable(_:))),
      ])
    return menu
  }
  func addCommands(to menu: NSMenu, _ commands: [(String, Selector)]) {
    for (title, action) in commands {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
  }
  func addSubmenu(_ title: String, _ submenu: NSMenu, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    menu.addItem(item)
  }
  func rowMenu() -> NSMenu {
    let menu = NSMenu()
    addCommands(
      to: menu,
      [
        ("Insert Rows Above", #selector(insertRowsAbove)),
        ("Insert Rows Below", #selector(insertRowsBelow)),
        ("Delete Selected Rows", #selector(deleteRows)),
      ])
    return menu
  }
  func columnMenu() -> NSMenu {
    let menu = NSMenu()
    addCommands(
      to: menu,
      [
        ("Insert Column Before…", #selector(insertColumnBefore)),
        ("Insert Column After…", #selector(insertColumnAfter)),
        ("Delete Selected Columns", #selector(deleteColumns)),
      ])
    menu.addItem(.separator())
    addCommands(
      to: menu,
      [
        ("Rename Column…", #selector(renameColumn)),
        ("Column Settings…", #selector(columnSettings)),
      ])
    let types = NSMenu()
    for (title, policy) in [("Value", TableInputPolicy.value), ("Text", .text)] {
      let item = NSMenuItem(
        title: title, action: #selector(changeColumnType(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = policy.rawValue
      item.state = selectedColumn?.input == policy ? .on : .off
      types.addItem(item)
    }
    addSubmenu("Input Type", types, to: menu)
    let totals = NSMenu()
    for total in TableTotal.allCases {
      let item = NSMenuItem(
        title: total.rawValue, action: #selector(setTotal(_:)), keyEquivalent: "")
      item.target = self
      item.state = selectedColumn?.total == total ? .on : .off
      totals.addItem(item)
    }
    addCommands(to: totals, [("Clear Total", #selector(clearTotal))])
    addSubmenu("Column Total", totals, to: menu)
    let rules = NSMenu()
    addCommands(
      to: rules,
      [
        ("Set Column Formula…", #selector(columnRule)),
        ("Clear Column Formula", #selector(clearRule)),
        ("Reset Overrides", #selector(resetOverrides)),
      ])
    addSubmenu("Column Formula (Optional)", rules, to: menu)
    return menu
  }
  func cellMenu() -> NSMenu {
    let menu = NSMenu()
    addCommands(
      to: menu,
      [
        ("Edit Cell", #selector(editSelectedCell)),
        ("Copy Values", #selector(copyValues)),
        ("Copy Inputs and Formulas", #selector(copyFormulas)),
        ("Paste", #selector(pasteCells)),
        ("Paste TSV as Formulas", #selector(pasteFormulas)),
        ("Clear Contents", #selector(clearCells)),
        ("Fill Down", #selector(fillDown)),
        ("Fill Right", #selector(fillRight)),
      ])
    menu.addItem(.separator())
    addSubmenu("Rows", rowMenu(), to: menu)
    addSubmenu("Columns", columnMenu(), to: menu)
    let inspect = NSMenu()
    addCommands(
      to: inspect,
      [
        ("Show Interpretation", #selector(showInterpretation(_:))),
        ("Copy Full Precision", #selector(copyFullPrecision(_:))),
      ])
    if let projection, projection.rows.indices.contains(position.row), let column = selectedColumn,
      case .failure = result?.value(row: projection.rows[position.row], column: column.id)
    {
      addCommands(
        to: inspect,
        [
          ("Repair Broken Reference", #selector(repairReference)),
          ("Go to Original Failure", #selector(goToOriginalFailure)),
        ])
    }
    addSubmenu("Cell Details", inspect, to: menu)
    return menu
  }
  func performEdit(_ operation: () throws -> Void) {
    guard commitCellEditing() else { return }
    do {
      try operation()
      refresh()
      clampSelection()
    } catch { status.stringValue = String(describing: error) }
  }
  func clampSelection() {
    guard let projection, !projection.rows.isEmpty, !projection.columns.isEmpty else { return }
    select(
      .init(
        row: min(position.row, projection.rows.count - 1),
        column: min(position.column, projection.columns.count - 1)))
  }
  func prompt(_ title: String, initial: String = "", apply: @escaping (String) -> Void) {
    guard let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    field.setAccessibilityLabel(title)
    alert.accessoryView = field
    alert.addButton(withTitle: localized("table.apply", "Apply"))
    alert.addButton(withTitle: localized("table.cancel", "Cancel"))
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn { apply(field.stringValue) }
    }
  }
  @objc func addRow() { performEdit { try editor.appendTableRows(tableID) } }
  @objc func deleteRows() {
    performEdit { try editor.deleteTableRows(tableID, in: rectangle.rows) }
  }
  @objc func addColumn() {
    prompt(localized("table.columnName", "Column name")) { [weak self] name in
      guard let self else { return }
      performEdit {
        try editor.insertTableColumn(tableID, at: projection?.columns.count ?? 0, header: name)
      }
    }
  }
  @objc func deleteColumns() {
    performEdit { try editor.deleteTableColumns(tableID, in: rectangle.columns) }
  }
  @objc func columnRule() {
    guard let column = selectedColumn else { return }
    prompt(localized("table.columnFormula", "Set Column Formula…"), initial: column.rule ?? "=") {
      [weak self] text in
      guard let self else { return }
      performEdit { try editor.setTableColumnRule(tableID, column: column.id, formula: text) }
    }
  }
  var selectedColumn: TableEditingSnapshot.Column? {
    guard let projection, projection.columns.indices.contains(position.column) else { return nil }
    return projection.columns[position.column]
  }
  @objc func clearRule() {
    guard let column = selectedColumn else { return }
    performEdit { try editor.setTableColumnRule(tableID, column: column.id, formula: nil) }
  }
  @objc func resetOverrides() {
    performEdit {
      var document = TableSourceDocument(editor.sheet)
      let before = editor.sheet.text
      for row in rectangle.rows {
        for column in rectangle.columns where projection?.columns[column].rule != nil {
          let edit = try document.setCell(
            table: tableID, at: .init(row: row, column: column), source: nil)
          document = TableSourceDocument(
            try TableSourcePatch.applying(edit.patches, to: document.editingSource))
        }
      }
      // One transaction for the complete rectangle.
      try editor.replaceTableSource(
        before: before, after: document.editingSource,
        action: localized("table.reset", "Reset Overrides"))
    }
  }
  @objc func setTotal(_ sender: NSMenuItem) {
    guard let column = selectedColumn, let total = TableTotal(rawValue: sender.title) else {
      return
    }
    performEdit { try editor.setTableColumnTotal(tableID, column: column.id, total: total) }
  }
  @objc func clearTotal() {
    guard let column = selectedColumn else { return }
    performEdit { try editor.setTableColumnTotal(tableID, column: column.id, total: nil) }
  }
  @objc func fillSelection() {
    performEdit {
      try editor.fillTableCells(
        tableID, from: .init(row: rectangle.rows.lowerBound, column: rectangle.columns.lowerBound),
        into: rectangle)
    }
  }
  @objc func copyValues() { copyRange(formulas: false) }
  @objc func copyFormulas() { copyRange(formulas: true) }
  func copyRange(formulas: Bool) {
    guard !isEditingCell, let projection, !projection.rows.isEmpty, !projection.columns.isEmpty,
      formulas || result != nil
    else { return }
    let text: String
    if formulas {
      guard
        let source = try? TableSourceDocument(editor.sheet).plainText(
          table: tableID, rectangle: rectangle)
      else { return }
      text = source
    } else {
      text = rectangle.rows.map { row in
        rectangle.columns.map { column in
          tsv(
            display(result?.value(row: projection.rows[row], column: projection.columns[column].id))
          )
        }.joined(separator: "\t")
      }.joined(separator: "\n")
    }
    let board = editor.resultPasteboard
    board.clearContents()
    board.setString(text, forType: .string)
    if formulas {
      let payload = TableCopyPayload(
        version: 1, source: editor.sheet.text, table: tableID.uuid,
        rows: [rectangle.rows.lowerBound, rectangle.rows.upperBound],
        columns: [rectangle.columns.lowerBound, rectangle.columns.upperBound])
      if let data = try? JSONEncoder().encode(payload) {
        board.setData(data, forType: Self.copyType)
      }
    }
  }
  func tsv(_ text: String) -> String {
    if text.contains(where: { "\t\n\r\"".contains($0) }) {
      return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return text
  }
  @objc func pasteCells() { pasteRange(formulas: false) }
  @objc func pasteFormulas() { pasteRange(formulas: true) }
  func pasteRange(formulas: Bool) {
    performEdit {
      let board = editor.resultPasteboard
      if !formulas, let data = board.data(forType: Self.copyType), data.count < 2_000_000,
        let payload = try? JSONDecoder().decode(TableCopyPayload.self, from: data),
        payload.version == 1,
        payload.rows.count == 2, payload.columns.count == 2,
        payload.rows[0] >= 0, payload.rows[1] >= payload.rows[0], payload.columns[0] >= 0,
        payload.columns[1] >= payload.columns[0]
      {
        let originDocument = TableSourceDocument(payload.source)
        guard let id = originDocument.editingTableIDs.first(where: { $0.uuid == payload.table })
        else {
          return
        }
        let clipboard = try originDocument.clipboard(
          table: id,
          rectangle: .init(
            rows: payload.rows[0]..<payload.rows[1],
            columns: payload.columns[0]..<payload.columns[1]))
        let before = editor.sheet.text
        let document = try documentForPaste(
          rows: payload.rows[1] - payload.rows[0], columns: payload.columns[1] - payload.columns[0])
        let paste = try document.paste(clipboard, table: tableID, at: position)
        try editor.replaceTableSource(
          before: before, after: paste.applying(to: document.editingSource), action: "Paste")
      } else if let text = board.string(forType: .string) {
        let before = editor.sheet.text
        let fields = TableSourceDocument.tabSeparated(text)
        let document = try documentForPaste(
          rows: fields.count, columns: fields.map(\.count).max() ?? 0)
        let paste = try document.pastePlainText(
          text, table: tableID, at: position, formulas: formulas)
        try editor.replaceTableSource(
          before: before, after: paste.applying(to: document.editingSource), action: "Paste")
      }
    }
  }
  private func documentForPaste(rows: Int, columns: Int) throws -> TableSourceDocument {
    var document = TableSourceDocument(editor.sheet)
    let rowsNeeded = position.row + rows
    let columnsNeeded = position.column + columns
    guard let projection, rows > 0, columns > 0, columnsNeeded <= 32,
      max(rowsNeeded, projection.rows.count) * max(columnsNeeded, projection.columns.count) <= 4000
    else {
      throw TableTransformError.invalidSelection
    }
    if rowsNeeded > projection.rows.count {
      let growth = try document.appendRows(
        table: tableID, count: rowsNeeded - projection.rows.count)
      document = TableSourceDocument(try growth.applying(to: document.editingSource))
    }
    var headers = Set(projection.columns.map { $0.header.lowercased() })
    for index in projection.columns.count..<max(projection.columns.count, columnsNeeded) {
      var number = index + 1
      while headers.contains("column \(number)") { number += 1 }
      let header = "Column \(number)"
      headers.insert(header.lowercased())
      let growth = try document.insertColumn(table: tableID, at: index, header: header)
      document = TableSourceDocument(try growth.applying(to: document.editingSource))
    }
    return document
  }
  func updateSummary() {
    guard let projection else { return }
    let count =
      projection.rows.isEmpty || projection.columns.isEmpty
      ? 0 : rectangle.rows.count * rectangle.columns.count
    address.stringValue = TableSourceDocument.letters(position.column) + String(position.row + 2)
    var parts = ["\(count) cells"]
    if count > 0, let result, let value = result.aggregate(.sum, rectangle: rectangle) {
      parts.append("Sum: " + (editor.formatTableValue(value)?.display ?? ""))
    }
    if count > 0, let result, let value = result.aggregate(.average, rectangle: rectangle) {
      parts.append("Average: " + (editor.formatTableValue(value)?.display ?? ""))
    }
    var footer: [String] = []
    for (index, column) in projection.columns.enumerated() {
      if let total = column.total, let result {
        let value = result.aggregate(
          total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
        footer.append(
          column.header + " " + total.rawValue + ": "
            + (value.flatMap { editor.formatTableValue($0)?.display } ?? "Error"))
      }
    }
    totals.stringValue = footer.joined(separator: "   |   ")
    totals.isHidden = footer.isEmpty
    if count == 1, projection.rows.indices.contains(position.row), let column = selectedColumn,
      let error = result?.cellError(row: projection.rows[position.row], column: column.id)
    {
      parts.append(editor.formatTableError(error))
    }
    status.stringValue = parts.joined(separator: "   ")
  }
}

extension ExpandedTableViewController {
  @objc func copyFullPrecision(_ sender: Any?) {
    guard let projection, !isEditingCell, let result else { return }
    let text = rectangle.rows.map { row in
      rectangle.columns.map { column in
        let value = result.value(row: projection.rows[row], column: projection.columns[column].id)
        if case .value(let scalar) = value {
          return tsv(editor.formatTableValue(scalar)?.fullPrecision ?? "")
        }
        return tsv(display(value))
      }.joined(separator: "\t")
    }.joined(separator: "\n")
    editor.resultPasteboard.clearContents()
    editor.resultPasteboard.setString(text, forType: .string)
  }
  @objc func showInterpretation(_ sender: Any?) {
    guard let projection, projection.rows.indices.contains(position.row),
      let column = selectedColumn
    else { return }
    let row = projection.rows[position.row]
    var details = [AnswerCell.Detail(label: "Input", value: projection.source(at: position))]
    var fullPrecision: String?
    if case .value(let scalar) = result?.value(row: row, column: column.id),
      let formatted = editor.formatTableValue(scalar)
    {
      fullPrecision = formatted.fullPrecision
      details.append(.init(label: "Result", value: formatted.display))
      details.append(.init(label: "Full precision", value: formatted.fullPrecision))
      details.append(.init(label: "Kind", value: scalar.tableKindName))
      details.append(
        .init(
          label: "Exactness",
          value: formatted.isApproximate
            ? "Approximate" : formatted.isRounded ? "Exact; display rounded" : "Exact"))
    }
    details +=
      result?.interpretation(row: row, column: column.id).map { entry in
        var value = entry.1
        if entry.0 == "Problem" {
          if let error = result?.cellError(row: row, column: column.id) {
            value = editor.formatTableError(error)
          } else {
            switch entry.1 {
            case "brokenReference", "missingTable", "missingColumn", "outOfBounds":
              value = localized(
                "table.referenceProblem",
                "The reference has no usable target. Repair the reference or edit the formula.")
            case "cycle":
              value = localized("table.cycleProblem", "These cells refer to each other.")
            case "blocked", "inheritedFailure":
              value = localized(
                "table.blockedProblem", "An input has an error. Go to the original failure.")
            case "inputRequiresFormula":
              value = localized("table.formulaProblem", "Start arithmetic input with =.")
            default:
              value = localized("table.checkFormula", "Check the formula and its references.")
            }
          }
        } else if entry.0 == "Clock" {
          value = entry.1 == "day" ? "Updates at midnight." : "Updates every second."
        } else if entry.0 == "Currency rate" {
          value =
            entry.1 == "manual"
            ? "Manual exchange rate"
            : entry.1 == "reference" ? "ECB reference rate" : "Calculated from ECB reference rates"
        } else if entry.0 == "Finance assumption" {
          value = editor.tableFinanceAssumption(entry.1)
        }
        return .init(label: entry.0, value: value)
      } ?? [.init(label: "Result", value: "Pending…")]
    let card = InterpretationViewController(
      details: details, fullPrecision: fullPrecision,
      availableSize: view.window?.frame.size ?? NSSize(width: 600, height: 400),
      pasteboard: editor.resultPasteboard)
    let popover = NSPopover()
    popover.contentViewController = card
    popover.behavior = .transient
    popover.show(relativeTo: formula.bounds, of: formula, preferredEdge: .maxY)
  }
  @objc func repairReference() {
    beginEditing()
    guard let range = projection?.brokenReferenceRange(in: formula.stringValue),
      let input = formula.currentEditor() as? NSTextView
    else { return }
    input.setSelectedRange(range)
    status.stringValue = localized(
      "table.pickReplacement",
      "Pick a cell to replace the selected broken reference. Return commits. Escape cancels.")
  }
  @objc func goToOriginalFailure() {
    guard let projection, projection.rows.indices.contains(position.row),
      let column = selectedColumn,
      case .failure(let origins) = result?.value(
        row: projection.rows[position.row], column: column.id),
      let origin = origins.first
    else { return }
    navigateFailure?(origin)
  }

  /// Writes the open table as TSV or CSV, in values or formulas mode. The
  /// file shows the same values the sheet displays, with a header row by
  /// default and the totals footer as the last row.
  @objc func exportTable(_ sender: Any?) {
    guard !isEditingCell, let projection, let window = view.window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText]
    panel.nameFieldStringValue = projection.name
    let mode = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
    mode.addItems(withTitles: [
      localized("table.exportValues", "Values"),
      localized("table.exportFormulas", "Inputs and Formulas"),
    ])
    mode.setAccessibilityLabel(localized("table.exportMode", "Export mode"))
    let headerBox = NSButton(
      checkboxWithTitle: localized("table.exportHeaders", "Include header row"), target: nil,
      action: nil)
    headerBox.state = .on
    let accessory = NSStackView(views: [mode, headerBox])
    accessory.orientation = .vertical
    accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    panel.accessoryView = accessory
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      let format: TableTextFormat =
        url.pathExtension.lowercased() == "csv" ? .csv : .tsv
      let grid = self.exportGrid(
        mode: mode.indexOfSelectedItem == 1 ? .formulas : .values)
      let text = TableGridText.text(
        grid, format: format, includesHeader: headerBox.state == .on,
        locale: self.editor.tableExportLocale)
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
      }
    }
  }

  /// Which text an export writes: what cells show, or what they hold.
  enum ExportMode { case values, formulas }

  /// The open table as display text: values with their units, or the source
  /// of each cell, with the column rule spelled in every inherited cell.
  func exportGrid(mode: ExportMode) -> TableGrid {
    guard let projection else {
      return TableGrid(name: nil, headers: [], rows: [], totals: [], failures: [])
    }
    let rows: [[String]]
    switch mode {
    case .values:
      rows = projection.rows.map { row in
        projection.columns.map { column in
          exportCell(result?.value(row: row, column: column.id), row: row, column: column.id)
        }
      }
    case .formulas:
      rows = projection.rows.indices.map { rowIndex in
        projection.columns.indices.map { columnIndex in
          projection.source(at: TableCellPosition(row: rowIndex, column: columnIndex))
        }
      }
    }
    let totals: [String?]
    if let result {
      totals = projection.columns.enumerated().map { index, column -> String? in
        guard let total = column.total else { return nil }
        let value = result.aggregate(
          total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
        return value.flatMap { editor.formatTableValue($0)?.display }
          ?? localized(
            "table.failure", "Error")
      }
    } else {
      totals = []
    }
    let failures = result?.calculationFailure.map { [editor.formatTableError($0)] } ?? []
    return TableGrid(
      name: projection.name, headers: projection.columns.map(\.header), rows: rows,
      totals: totals.contains(where: { $0 != nil }) ? totals : [], failures: failures)
  }

  /// A value cell as the export shows it: the display text, or the failure
  /// message that names the problem.
  private func exportCell(_ value: TableCellValue?, row: RowID, column: ColumnID) -> String {
    switch value {
    case .value(let scalar):
      return editor.formatTableValue(scalar)?.display ?? ""
    case .text(let text): return text
    case .blank: return ""
    case .failure:
      if let error = result?.cellError(row: row, column: column) {
        return editor.formatTableError(error)
      }
      return localized("table.failure", "Error")
    case nil:
      if let error = result?.calculationFailure {
        return editor.formatTableError(error)
      }
      return localized("table.pending", "Pending…")
    }
  }
}
