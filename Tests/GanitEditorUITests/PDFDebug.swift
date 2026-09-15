import AppKit
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct PDFDebugTests {
  @Test
  func debug() throws {
    let long = (1...200).map { ExportedLine(source: "\($0) * 2", answer: "\($0 * 2)", isFailure: false) }
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    print("PAPER", info.paperSize, info.topMargin, info.bottomMargin, info.imageablePageBounds)
    let view = SheetDocumentRenderer.printableView(long, printInfo: info)
    print("VIEW", view.frame, "range", view.textStorage?.length ?? -1)
    let pdf = try SheetDocumentRenderer.pdf(long, title: "Long")
    print("BYTES", pdf.count, "PAGES", NSPDFImageRep(data: pdf)?.pageCount ?? -1)
  }
}
