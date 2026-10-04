import AppKit
import Foundation
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

/// M6 task 2: HTML, print and PDF show tables as grids with readable units,
/// explicit failures, and headers repeated where a table continues on a new
/// page.
@MainActor
@Suite
struct MixedSheetRendererTests {
  private let prose: [ExportedLine] = [
    ExportedLine(source: "rate = 3", answer: "3", status: .calculated)
  ]

  private let items = RenderedTable(
    name: "Items",
    headers: ["Item", "Qty", "Amount"],
    rows: [
      [
        RenderedTableCell(text: "Nails"), RenderedTableCell(text: "2"),
        RenderedTableCell(text: "6"),
      ],
      [
        RenderedTableCell(text: "Saw"), RenderedTableCell(text: "1"),
        RenderedTableCell(text: "Cannot divide by zero.", isFailure: true),
      ],
    ],
    totals: [RenderedTotal(columnIndex: 2, label: "Amount sum", text: "6")],
    failures: [])

  private let quarantined = RenderedTable(
    name: nil, headers: [], rows: [], totals: [],
    failures: ["This table block is not valid, so Ganit keeps it unchanged."])

  @Test func htmlRendersTablesWithTheadTotalsAndFailures() {
    let html = SheetDocumentRenderer.html(
      [.lines(prose), .table(items), .table(quarantined)], title: "Trip")
    #expect(html.contains("<thead><tr><th scope=\"col\" dir=\"auto\">Item</th>"))
    #expect(html.contains("<td dir=\"auto\">Nails</td>"))
    #expect(html.contains("<td class=\"failure\" dir=\"auto\">Cannot divide by zero.</td>"))
    #expect(html.contains("<tfoot><tr><td></td><td></td><td dir=\"auto\">6</td></tr></tfoot>"))
    #expect(html.contains("<h2 class=\"table-name\">Items</h2>"))
    #expect(html.contains("<p class=\"failure\">This table block is not valid"))
    #expect(html.contains("<td dir=\"auto\">rate = 3</td><td dir=\"auto\">3</td></tr>"))
    #expect(!html.contains("Items\nQty"))
  }

  @Test func printLayoutFitsBlocksAndRepeatsContinuedHeaders() {
    // A table whose 120 rows cannot fit one page.
    let tall = RenderedTable(
      name: "Big",
      headers: ["N", "Twice"],
      rows: (1...120).map {
        [RenderedTableCell(text: "\($0)"), RenderedTableCell(text: "\($0 * 2)")]
      },
      totals: [],
      failures: [])
    let info = SheetDocumentRenderer.printInfo()
    let view = MixedSheetPrintView(blocks: [.table(tall)], printInfo: info)
    view.layoutPages()
    #expect(view.pages.count > 1)
    // Every page that continues the table starts with its header again.
    for (index, page) in view.pages.enumerated() {
      let startsWithRow = page.first?.content.isRow == true
      if startsWithRow {
        guard case .header(let columns, _) = page[0].content else {
          Issue.record("Page \(index) continues the table without its header")
          return
        }
        #expect(columns.map(\.string) == ["N", "Twice"])
      }
    }
    let lastPage = view.pages.last ?? []
    let lastRow = view.pages.last?.last { item in
      if case .row = item.content { return true }
      return false
    }
    if case .row(let columns, _, _)? = lastRow?.content {
      #expect(columns.map(\.string).last == "240")
    } else {
      Issue.record("The last page does not end with the last data row")
    }
  }

  @Test func pdfContainsTheRenderedGrid() throws {
    let pdf = try SheetDocumentRenderer.pdf([.table(items)], title: "Grid")
    #expect(pdf.starts(with: Data("%PDF".utf8)))
    #expect(try #require(NSPDFImageRep(data: pdf)).pageCount == 1)
  }

  @Test func quarantinedTablesPrintTheirDiagnosticOnly() async throws {
    let source = "rate = 3\n@ganit-table 9\n{}\n@end-ganit-table\n"
    let editor = SheetEditorViewController(
      text: source,
      context: try EvaluationContext(
        localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
        angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
        timeZone: try #require(TimeZone(identifier: "UTC"))))
    await editor.scheduler?.waitUntilIdle()
    let printed = await editor.printableLines()
    #expect(
      printed.map(\.source).contains(
        "This table block names a version Ganit does not read, so Ganit keeps it unchanged."))
    #expect(!printed.map(\.source).contains("@ganit-table 9"))
  }
}

extension PrintItem.Content {
  var isRow: Bool {
    if case .row = self { return true }
    return false
  }
}
