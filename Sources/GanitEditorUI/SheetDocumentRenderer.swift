import AppKit

/// A sheet line as exported: its source and the answer the editor shows.
public struct ExportedLine: Equatable, Sendable {
  public let source: String
  /// The displayed answer or failure message, or `nil` for lines without one.
  public let answer: String?
  /// The exact value behind a calculated answer, which may be shown rounded.
  public let fullPrecision: String?
  public enum Status: String, Sendable {
    case none, calculated
    case aiUnverified = "ai-unverified"
    case failure, pending
  }
  public let status: Status
  public var isFailure: Bool { status == .failure }

  public init(source: String, answer: String?, fullPrecision: String? = nil, status: Status) {
    self.source = source
    self.answer = answer
    self.fullPrecision = fullPrecision
    self.status = status
  }

  /// Human-readable formats retain provenance even when copied without color.
  var annotatedAnswer: String? {
    answer.map { status == .aiUnverified ? Self.annotateAI($0) : $0 }
  }

  static func annotateAI(_ answer: String) -> String {
    answer + " [" + localized("export.aiUnverified", "AI; unverified") + "]"
  }
}

/// One cell of a rendered table: the display text, with its failure state,
/// so a renderer can mark the problem instead of guessing from the text.
public struct RenderedTableCell: Equatable, Sendable {
  public let text: String
  public let isFailure: Bool

  public init(text: String, isFailure: Bool = false) {
    self.text = text
    self.isFailure = isFailure
  }
}

/// One column's totals footer: which column it belongs to, its label, and
/// the formatted value or the failure it reports.
public struct RenderedTotal: Equatable, Sendable {
  public let columnIndex: Int
  /// The spelled summary, such as "Amount sum".
  public let label: String
  public let text: String

  public init(columnIndex: Int, label: String, text: String) {
    self.columnIndex = columnIndex
    self.label = label
    self.text = text
  }
}

/// One table block as a renderer shows it: the name, headers, cell display
/// text, the totals footer, and the whole-table failures.
public struct RenderedTable: Equatable, Sendable {
  /// The table's display name, or `nil` for a block Ganit cannot read.
  public let name: String?
  public let headers: [String]
  /// One row of cells per data row, in grid order.
  public let rows: [[RenderedTableCell]]
  public let totals: [RenderedTotal]
  /// Why the table shows no values, in order. Empty for a calculated table.
  public let failures: [String]

  public init(
    name: String?, headers: [String], rows: [[RenderedTableCell]], totals: [RenderedTotal],
    failures: [String]
  ) {
    self.name = name
    self.headers = headers
    self.rows = rows
    self.totals = totals
    self.failures = failures
  }
}

/// A sheet as a renderer shows it: groups of prose lines beside their
/// answers, and each table block as its own grid.
public enum RenderedBlock: Equatable, Sendable {
  case lines([ExportedLine])
  case table(RenderedTable)
}

/// Renders a sheet's prose beside its answers and its tables as grids, as
/// CSV, HTML, printable text, PDF, and a Quick Look thumbnail. Every format
/// shows the same values the editor displays, with units as written and
/// failures named instead of hidden.
@MainActor
public enum SheetDocumentRenderer {
  /// `Line,Source,Answer,Full Precision,Status` rows quoted per RFC 4180. A cell that a spreadsheet
  /// would run as a formula starts with an apostrophe instead.
  public static func csv(_ lines: [ExportedLine]) -> String {
    let rows =
      [["Line", "Source", "Answer", "Full Precision", "Status"]]
      + lines.enumerated().map {
        [
          String($0.offset + 1), $0.element.source, $0.element.answer ?? "",
          $0.element.fullPrecision ?? "", $0.element.status.rawValue,
        ]
      }
    return rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
  }

  private static func csvCell(_ text: String) -> String {
    let formulaStarts: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
    let guarded =
      text.first.map(formulaStarts.contains) == true && Double(text) == nil ? "'" + text : text
    guard guarded.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
      return guarded
    }
    return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// A standalone page with one prose table per prose group and one real
  /// table per calculation table. All text is escaped and the page loads
  /// nothing. `thead` repeats on page breaks when a reader prints the page.
  public static func html(_ blocks: [RenderedBlock], title: String) -> String {
    let body = blocks.map { block -> String in
      switch block {
      case .lines(let lines):
        let rows = lines.map { line -> String in
          let answerClass = line.isFailure ? " class=\"failure\"" : ""
          return "<tr><td dir=\"auto\">\(escape(line.source))</td>"
            + "<td\(answerClass) dir=\"auto\">\(escape(line.annotatedAnswer ?? ""))</td></tr>"
        }
        return "<table>\n\(rows.joined(separator: "\n"))\n</table>"
      case .table(let table):
        return html(table: table)
      }
    }.joined(separator: "\n")
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <title>\(escape(title))</title>
      <style>
      body { font: 14px -apple-system, system-ui, sans-serif; margin: 2em; }
      table { border-collapse: collapse; width: 100%; margin-bottom: 1em; }
      td, th { padding: 2px 8px; vertical-align: top; white-space: pre-wrap; }
      td + td, th + th { text-align: end; font-variant-numeric: tabular-nums; }
      th { text-align: start; border-bottom: 1px solid #888; }
      tfoot td { border-top: 1px solid #888; }
      td.failure, p.failure { color: #b3261e; }
      .table-name { font-size: 1em; margin: 1em 0 0.2em; }
      </style>
      </head>
      <body>
      <h1>\(escape(title))</h1>
      \(body)
      </body>
      </html>

      """
  }

  private static func html(table: RenderedTable) -> String {
    var parts: [String] = []
    if let name = table.name {
      parts.append("<h2 class=\"table-name\">\(escape(name))</h2>")
    }
    parts += table.failures.map { "<p class=\"failure\">\(escape($0))</p>" }
    if table.headers.isEmpty {
      return parts.joined(separator: "\n")
    }
    let head = table.headers.map {
      "<th scope=\"col\" dir=\"auto\">\(escape($0))</th>"
    }.joined()
    let body = table.rows.map { row -> String in
      row.map { cell -> String in
        let failureClass = cell.isFailure ? " class=\"failure\"" : ""
        return "<td\(failureClass) dir=\"auto\">\(escape(cell.text))</td>"
      }.joined()
    }.map { "<tr>\($0)</tr>" }.joined(separator: "\n")
    var sections = "<thead><tr>\(head)</tr></thead>"
    if !body.isEmpty {
      sections += "\n<tbody>\n\(body)\n</tbody>"
    }
    if !table.totals.isEmpty {
      var cells = Array(repeating: "<td></td>", count: table.headers.count)
      for total in table.totals where table.headers.indices.contains(total.columnIndex) {
        cells[total.columnIndex] = "<td dir=\"auto\">\(escape(total.text))</td>"
      }
      sections += "\n<tfoot><tr>\(cells.joined())</tr></tfoot>"
    }
    parts.append("<table>\n\(sections)\n</table>")
    return parts.joined(separator: "\n")
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// A view laid out for `printInfo`'s page: prose lines with each answer at
  /// a right tab stop, and each table as a grid whose headers repeat when a
  /// table continues on the next page. Used for printing and PDF.
  public static func printableView(_ blocks: [RenderedBlock], printInfo: NSPrintInfo) -> NSView {
    MixedSheetPrintView(blocks: blocks, printInfo: printInfo)
  }

  /// Page setup for sheets: the shared paper and margins, scaled to the page
  /// width and starting at the top of the first page.
  public static func printInfo() -> NSPrintInfo {
    let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
    printInfo.horizontalPagination = .fit
    printInfo.isVerticallyCentered = false
    return printInfo
  }

  /// A paginated PDF of the printable view, laid out as printing would.
  public static func pdf(_ blocks: [RenderedBlock], title: String) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    let printInfo = printInfo()
    printInfo.jobDisposition = .save
    printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    let operation = NSPrintOperation(
      view: printableView(blocks, printInfo: printInfo), printInfo: printInfo)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    operation.jobTitle = title
    operation.run()
    return try Data(contentsOf: url)
  }

  /// A PNG of a PDF's first page, at most `size` points on its longer side.
  public static func thumbnail(ofPDF pdf: Data, size: CGFloat = 512) -> Data? {
    guard let page = NSPDFImageRep(data: pdf) else {
      return nil
    }
    let scale = size / max(page.bounds.width, page.bounds.height)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(page.bounds.width * scale),
        pixelsHigh: Int(page.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
    page.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}
