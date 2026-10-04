import AppKit
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

@MainActor
@Suite(.serialized)
struct TableUsabilityTests {
  @Test func creationKeepsColumnSettingsAndUsesRequestedSize() async throws {
    let form = TableCreationForm(pasted: nil)
    form.columnCount.selectItem(at: 3)
    form.sizeChanged()
    #expect(form.settings.count == 4)
    form.headers[3].stringValue = "Price"
    form.policies[3].selectItem(at: 1)
    form.columnCount.selectItem(at: 1)
    form.sizeChanged()
    form.columnCount.selectItem(at: 3)
    form.sizeChanged()
    #expect(
      form.settings.map(\.0) == ["Column 1", "Column 2", "Column 3", "Price"]
    )
    #expect(form.settings[3].1 == .text)
    let (editor, _) = try await InlineTableTests().makeEditor()
    let before = editor.sheet.text
    let id = try #require(
      try editor.insertTableRectangle(
        named: "New", headers: form.settings,
        rows: nil, formulas: false, atUTF8: 0, expectedSource: before, rowCount: 5))
    let projection = try #require(TableEditingSnapshot(TableSourceDocument(editor.sheet), id: id))
    #expect(projection.rows.count == 5)
    #expect(projection.columns.count == 4)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func basicEntryAndFormulaInTextColumn() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.insertTableColumn(table.id, at: 2, header: "Total", policy: .text)
    controller.beginEditing(inline: true)
    controller.inlineInput.stringValue = "1"
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: controller.inlineInput))
    #expect(controller.inlineInput.superview === controller.grid)
    #expect(controller.commitCellEditing())
    controller.moveAfterCommit(horizontal: true, backwards: false)
    #expect(controller.position == .init(row: 0, column: 1))
    controller.beginEditing(inline: true)
    controller.inlineInput.stringValue = "2"
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: controller.inlineInput))
    #expect(controller.commitCellEditing())
    controller.moveAfterCommit(horizontal: true, backwards: false)
    controller.beginEditing(inline: true)
    controller.inlineInput.stringValue = "sum(A2, B2)"
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: controller.inlineInput))
    #expect(controller.commitCellEditing())
    await editor.scheduler?.waitUntilIdle()
    let column = try #require(controller.projection?.columns[2])
    #expect(
      controller.display(controller.result?.value(row: table.rows[0], column: column.id)) == "3")
    #expect(controller.formula.stringValue == "=sum(A2, B2)")
    #expect(controller.address.stringValue == "C2")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 2), source: "=SUM(A2:B2)")
    await editor.scheduler?.waitUntilIdle()
    #expect(
      controller.display(controller.result?.value(row: table.rows[0], column: column.id)) == "3")
  }
  @Test func tabBacktabReturnAndLastRowGrowth() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor(rows: 1)
    controller.beginEditing(inline: true)
    controller.formula.stringValue = "8"
    let input = try #require(controller.editingInput.currentEditor() as? NSTextView)
    #expect(
      controller.control(
        controller.editingInput, textView: input, doCommandBy: #selector(NSResponder.insertTab(_:)))
    )
    #expect(controller.position == .init(row: 0, column: 1))
    controller.beginEditing(inline: true)
    #expect(
      controller.control(
        controller.editingInput,
        textView: try #require(controller.editingInput.currentEditor() as? NSTextView),
        doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    #expect(controller.position == .init(row: 0, column: 0))
    controller.select(.init(row: 0, column: 1))
    let before = editor.sheet.text
    controller.moveAfterCommit(horizontal: true, backwards: false)
    #expect(controller.projection?.rows.count == 2)
    #expect(controller.position == .init(row: 1, column: 0))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func contextualInsertionKeepsTargetsAndUndo() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 1, column: 1), source: "=$A$2 + A2")
    controller.select(.init(row: 0, column: 0))
    let before = editor.sheet.text
    controller.insertRowsAbove()
    #expect(controller.projection?.source(at: .init(row: 2, column: 1)) == "=$A$3 + A3")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    controller.select(.init(row: 1, column: 0))
    controller.insertRowsBelow()
    #expect(controller.projection?.rows.count == 4)
  }
  @Test func formulaCopyKeepsRelativeAndLockedReferences() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    editor.resultPasteboard = NSPasteboard.withUniqueName()
    defer { editor.resultPasteboard.releaseGlobally() }
    try editor.setTableCell(
      table.id, at: .init(row: 0, column: 1), source: "=A2 + $A$2 + $A2 + A$2")
    controller.select(.init(row: 0, column: 1))
    controller.grid.copy(nil)
    controller.select(.init(row: 1, column: 1))
    controller.pasteCells()
    #expect(controller.projection?.source(at: controller.position) == "=A3 + $A$2 + $A3 + A$2")
  }
  @Test func pasteGrowsAtomicallyAndRejectedFormulasDoNotGrow() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor(rows: 1)
    editor.resultPasteboard = NSPasteboard.withUniqueName()
    defer { editor.resultPasteboard.releaseGlobally() }
    editor.resultPasteboard.setString("1\t2\t3\n4\t5\t6", forType: .string)
    let before = editor.sheet.text
    controller.pasteCells()
    #expect(controller.projection?.rows.count == 2)
    #expect(controller.projection?.columns.count == 3)
    #expect(controller.projection?.source(at: .init(row: 1, column: 2)) == "6")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    editor.resultPasteboard.clearContents()
    editor.resultPasteboard.setString("1\t2\t=A2\n4\t5\t6", forType: .string)
    controller.pasteCells()
    #expect(editor.sheet.text == before)
  }
  @Test func clearSelectionAndUndoAndColumnSettings() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "7")
    controller.selectAllCells(nil)
    #expect(controller.rectangle.rows == 0..<3)
    #expect(controller.rectangle.columns == 0..<2)
    let before = editor.sheet.text
    controller.clearCells()
    #expect(controller.projection?.source(at: .init(row: 0, column: 0)) == "")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    controller.select(.init(row: 0, column: 0))
    controller.grid.tableColumns[1].width = 230
    try editor.renameTableColumn(table.id, column: table.columns[0].id, to: "Mass")
    try editor.setTableColumnInput(
      table.id, column: table.columns[0].id, policy: .value, unit: "kg")
    #expect(controller.grid.tableColumns[1].width == 230)
    #expect(controller.grid.tableColumns[1].title == "A  Mass")
    #expect(controller.selectedColumn?.unit == "kg")
    await editor.scheduler?.waitUntilIdle()
    let mass = controller.display(
      controller.result?.value(row: table.rows[0], column: table.columns[0].id))
    #expect(mass.contains("kg"))
  }
  @Test func menusHaveTargetsAndDistinctScopes() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor()
    #expect(controller.actionsMenu().items.count == 4)
    #expect(!controller.actionsMenu().items.map(\.title).contains("Copy Values"))
    #expect(controller.rowMenu().items.map(\.title).contains("Insert Rows Above"))
    #expect(controller.columnMenu().items.map(\.title).contains("Input Type"))
    #expect(controller.cellMenu().items.map(\.title).contains("Edit Cell"))
    editor.returnFromTable(nil)
    let text = try #require(editor.textView as? SheetTextView)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .init(x: 20, y: 400), modifierFlags: [], timestamp: 0,
        windowNumber: editor.view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
        pressure: 1))
    let menu = try #require(text.menu(for: event))
    #expect(menu.items.map(\.title).contains("Insert Table…"))
    #expect(menu.items.first(where: { $0.title == "Insert Table…" })?.target === editor)
  }
  @Test func previewEditsAndCancelAndUndo() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    let preview = try #require(editor.inlineTableViews[table.id])
    let button = try #require(
      preview.cells.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 0 })
    button.performClick(nil)
    preview.beginPreviewEdit()
    preview.cellInput.stringValue = "42"
    let before = editor.sheet.text
    #expect(preview.commitPreviewEdit())
    await editor.scheduler?.waitUntilIdle()
    #expect(
      TableEditingSnapshot(TableSourceDocument(editor.sheet), id: table.id)?.source(
        at: .init(row: 0, column: 0)) == "42")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    preview.beginPreviewEdit()
    preview.cellInput.stringValue = "99"
    #expect(
      preview.control(
        preview.cellInput, textView: try #require(preview.cellInput.currentEditor() as? NSTextView),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(editor.sheet.text == before)
  }
  @Test func fillDownCopiesEachColumnAndUsesOneUndo() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "4")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=A2 * 2")
    controller.selectAllCells(nil)
    let before = editor.sheet.text
    controller.fillDown()
    #expect(controller.projection?.source(at: .init(row: 2, column: 0)) == "4")
    #expect(controller.projection?.source(at: .init(row: 2, column: 1)) == "=A4 * 2")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func smallTablesFitTheInitialWindowAndShowRowAddresses() async throws {
    let (editor, table, _) = try await ExpandedTableTests().makeEditor()
    editor.returnFromTable(nil)
    try editor.insertTableColumn(table.id, at: 2, header: "Third")
    try editor.insertTableColumn(table.id, at: 3, header: "Fourth")
    let window = try #require(editor.view.window)
    window.setContentSize(.init(width: 440, height: 450))
    editor.openTable(table.id)
    let controller = try #require(editor.expandedTable)
    window.layoutIfNeeded()
    controller.view.layoutSubtreeIfNeeded()
    controller.viewDidLayout()
    let width = controller.grid.tableColumns.reduce(0) { $0 + $1.width }
    #expect(width <= controller.scroll.contentSize.width)
    #expect(controller.scroll.contentView.bounds.minX == 0)
    controller.grid.tableColumns[1].width = 220
    controller.viewDidLayout()
    #expect(controller.grid.tableColumns[1].width == 220)
  }
  @Test func unchangedCellEditDoesNotAddAnUndoStepOrOverride() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableColumnRule(table.id, column: table.columns[1].id, formula: "=A2 * 2")
    controller.select(.init(row: 0, column: 1))
    let before = editor.sheet.text
    controller.beginEditing(inline: true)
    #expect(controller.commitCellEditing())
    #expect(editor.sheet.text == before)
    #expect(controller.projection?.isOverride(at: controller.position) == false)
    editor.documentUndoManager.undo()
    #expect(controller.projection?.columns[1].rule == nil)
  }
  @Test func internalPasteGrowsAndTranslatesFormulasInOneUndo() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor(rows: 1)
    editor.resultPasteboard = NSPasteboard.withUniqueName()
    defer { editor.resultPasteboard.releaseGlobally() }
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "4")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=A2 * 2")
    controller.selectAllCells(nil)
    controller.copyFormulas()
    controller.select(.init(row: 0, column: 1))
    let before = editor.sheet.text
    controller.pasteCells()
    #expect(controller.projection?.columns.count == 3)
    #expect(controller.projection?.source(at: .init(row: 0, column: 2)) == "=B2 * 2")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func renderNativeGridAndCreationForm() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.pasteTablePlainText(
      "1\t2\n3\t4\n5\t6", into: table.id, at: .init(row: 0, column: 0), formulas: false)
    await editor.scheduler?.waitUntilIdle()
    controller.view.layoutSubtreeIfNeeded()
    func capture(_ view: NSView, _ path: String) throws {
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path))
    }
    try capture(controller.view, "/tmp/ganit-table-grid.png")
    controller.beginEditing(inline: true)
    try capture(controller.view, "/tmp/ganit-table-inline-edit.png")
    controller.cancelEditing()
    editor.returnFromTable(nil)
    editor.layoutInlineTables()
    try capture(try #require(editor.inlineTableViews[table.id]), "/tmp/ganit-table-preview.png")
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 440, height: 350), styleMask: [.titled],
      backing: .buffered, defer: true)
    let form = TableCreationForm(pasted: nil)
    window.contentView = form
    window.layoutIfNeeded()
    try capture(form, "/tmp/ganit-table-creation.png")
    ExpandedTableTests.windows.append(window)
  }
}
