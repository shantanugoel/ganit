import AppKit
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

/// M6 task 1: the open table's export grid shows the displayed values or
/// the stored inputs, with the column rule spelled in inherited cells, and
/// Table Actions lists Export Table.
@MainActor
@Suite(.serialized)
struct TableExportTests {
  static var windows: [NSWindow] = []
  func makeEditor() async throws -> (
    SheetEditorViewController, TableModel, ExpandedTableViewController
  ) {
    var table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: 2)
    table.columns[1].rule = "=[@Qty] * rate"
    table.columns[1].total = .sum
    for (row, source) in ["2", "4"].enumerated() {
      table.cells.append(
        TableCell(
          row: table.rows[row], column: table.columns[0].id, source: source, isOverride: false))
    }
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0),
      calendar: Calendar(identifier: .gregorian), timeZone: #require(TimeZone(identifier: "UTC")))
    let editor = SheetEditorViewController(
      text: "rate = 3\n" + (try TableSourceDocument.canonicalBlock(for: table))
        + "sum(Items[Amount])\n",
      context: context)
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 450), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    editor.openTable(table.id)
    window.layoutIfNeeded()
    return (editor, table, try #require(editor.expandedTable))
  }

  @Test func actionsMenuListsExportTable() async throws {
    let (_, _, grid) = try await makeEditor()
    let titles = grid.actionsMenu().items.compactMap(\.title)
    #expect(titles.contains("Export Table…"))
  }

  @Test func exportGridShowsValuesTotalsAndRuleCells() async throws {
    let (editor, table, grid) = try await makeEditor()
    await editor.scheduler?.waitUntilIdle()
    let values = grid.exportGrid(mode: .values)
    #expect(values.headers == ["Qty", "Amount"])
    #expect(values.rows == [["2", "6"], ["4", "12"]])
    #expect(values.totals == [nil, "18"])
    #expect(values.failures.isEmpty)
    let formulas = grid.exportGrid(mode: .formulas)
    #expect(formulas.rows == [["2", "=[@Qty] * rate"], ["4", "=[@Qty] * rate"]])
    #expect(formulas.totals == [nil, "18"])
    let text = TableGridText.text(values, format: .csv, locale: editor.tableExportLocale)
    #expect(text == "Qty,Amount\r\n2,6\r\n4,12\r\n,18\r\n")
  }

  @Test func failureCellsShowTheirMessageInExports() async throws {
    let (_, table, grid) = try await makeEditor()
    grid.beginEditing()
    grid.formula.stringValue = "=1/0"
    #expect(grid.commitCellEditing())
    let editor = grid.editor
    await editor.scheduler?.waitUntilIdle()
    let values = grid.exportGrid(mode: .values)
    let cell = try #require(values.rows.first?.first)
    #expect(cell == "Cannot divide by zero.")
    // A blocked dependent stays an explicit failure, and the total names it.
    #expect(values.rows.first?[1] == "An input has an error. Go to the original failure.")
    #expect(
      values.totals == [nil, "Cannot total these values. Check cell errors and value types."])
    _ = table
  }
}
