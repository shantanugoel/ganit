import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct SheetDocumentRendererTests {
  private let lines = [
    ExportedLine(source: "# Trip, \"2026\"", answer: nil, isFailure: false),
    ExportedLine(source: "hotel = 85 * 3", answer: "255", isFailure: false),
    ExportedLine(
      source: "=HYPERLINK(\"x\")", answer: "This identifier is not defined.", isFailure: true),
    ExportedLine(source: "-5", answer: "-5", isFailure: false),
    ExportedLine(source: "<b>&", answer: nil, isFailure: false),
  ]

  @Test
  func writesQuotedCSVThatSpreadsheetsCannotRunAsFormulas() {
    let rows = [
      "Line,Source,Answer",
      ##"1,"# Trip, ""2026""","##,
      "2,hotel = 85 * 3,255",
      #"3,"'=HYPERLINK(""x"")",This identifier is not defined."#,
      "4,-5,-5",
      "5,<b>&,",
    ]
    #expect(SheetDocumentRenderer.csv(lines) == rows.joined(separator: "\r\n") + "\r\n")
  }

  @Test
  func writesEscapedStandaloneHTML() {
    let html = SheetDocumentRenderer.html(lines, title: "<Trip>")
    #expect(html.contains("<title>&lt;Trip&gt;</title>"))
    #expect(html.contains("<td dir=\"auto\">&lt;b&gt;&amp;</td>"))
    #expect(
      html.contains("<td class=\"failure\" dir=\"auto\">This identifier is not defined.</td>"))
    #expect(!html.contains("<b>&"))
    #expect(!html.contains("src=") && !html.contains("href="))
  }

  @Test
  func rendersPaginatedPDFAndAThumbnail() throws {
    let long = (1...200).map {
      ExportedLine(source: "\($0) * 2", answer: "\($0 * 2)", isFailure: false)
    }
    let pdf = try SheetDocumentRenderer.pdf(long, title: "Long")
    #expect(pdf.starts(with: Data("%PDF".utf8)))
    let pages = try #require(NSPDFImageRep(data: pdf)).pageCount
    #expect(pages > 1)

    let thumbnail = try #require(SheetDocumentRenderer.thumbnail(ofPDF: pdf))
    let image = try #require(NSBitmapImageRep(data: thumbnail))
    #expect(max(image.pixelsWide, image.pixelsHigh) == 512)
  }

  @Test
  func exportsTheAnswersTheEditorShows() async throws {
    let editor = SheetEditorViewController(
      text: "# Rent\nrent = 2,100\nrent * 12\nfoo\n1 +",
      context: try EvaluationContext(
        localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates, angleMode: .radians,
        precision: PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
        timeZone: try #require(TimeZone(identifier: "UTC"))))

    let exported = await editor.exportedLines()

    #expect(exported.map(\.source) == ["# Rent", "rent = 2,100", "rent * 12", "foo", "1 +"])
    #expect(
      exported.map(\.answer) == [
        nil, "2,100", "25,200", "This identifier is not defined.", "Enter an expression here.",
      ])
    #expect(exported.map(\.isFailure) == [false, false, false, true, true])
  }
}
