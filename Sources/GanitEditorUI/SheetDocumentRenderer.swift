import AppKit

/// A sheet line as exported: its source and the answer the editor shows.
public struct ExportedLine: Equatable, Sendable {
  public let source: String
  /// The displayed answer or failure message, or `nil` for lines without one.
  public let answer: String?
  public let isFailure: Bool

  public init(source: String, answer: String?, isFailure: Bool) {
    self.source = source
    self.answer = answer
    self.isFailure = isFailure
  }
}

/// Renders a sheet's source beside its answers as CSV, HTML, printable text,
/// PDF, and a Quick Look thumbnail. Every format shows the same answers the
/// editor displays.
@MainActor
public enum SheetDocumentRenderer {
  /// `Line,Source,Answer` rows quoted per RFC 4180. A cell that a spreadsheet
  /// would run as a formula starts with an apostrophe instead.
  public static func csv(_ lines: [ExportedLine]) -> String {
    let rows =
      [["Line", "Source", "Answer"]]
      + lines.enumerated().map {
        [String($0.offset + 1), $0.element.source, $0.element.answer ?? ""]
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

  /// A standalone page with one table row per line. All text is escaped and
  /// the page loads nothing.
  public static func html(_ lines: [ExportedLine], title: String) -> String {
    let rows = lines.map { line in
      let answerClass = line.isFailure ? " class=\"failure\"" : ""
      return "<tr><td dir=\"auto\">\(escape(line.source))</td>"
        + "<td\(answerClass) dir=\"auto\">\(escape(line.answer ?? ""))</td></tr>"
    }
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <title>\(escape(title))</title>
      <style>
      body { font: 14px -apple-system, system-ui, sans-serif; margin: 2em; }
      table { border-collapse: collapse; width: 100%; }
      td { padding: 2px 8px; vertical-align: top; white-space: pre-wrap; }
      td + td { text-align: end; font-variant-numeric: tabular-nums; }
      .failure { color: #b3261e; }
      </style>
      </head>
      <body>
      <h1>\(escape(title))</h1>
      <table>
      \(rows.joined(separator: "\n"))
      </table>
      </body>
      </html>

      """
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// A text view laid out for `printInfo`'s page, with each answer at a right
  /// tab stop after its source, for printing and PDF.
  public static func printableView(_ lines: [ExportedLine], printInfo: NSPrintInfo) -> NSTextView {
    let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width - 1)]
    let text = NSMutableAttributedString()
    for line in lines {
      text.append(
        NSAttributedString(
          string: line.source,
          attributes: [.font: VisualStyle.Typography.source(scale: 1), .paragraphStyle: paragraph]))
      if let answer = line.answer {
        text.append(
          NSAttributedString(
            string: "\t" + answer,
            attributes: [
              .font: VisualStyle.Typography.answer(scale: 1), .paragraphStyle: paragraph,
              .foregroundColor: line.isFailure ? VisualStyle.Color.failure : NSColor.black,
            ]))
      }
      text.append(NSAttributedString(string: "\n"))
    }
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(text)
    view.isVerticallyResizable = true
    view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    view.sizeToFit()
    return view
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
  public static func pdf(_ lines: [ExportedLine], title: String) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    let printInfo = printInfo()
    printInfo.jobDisposition = .save
    printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    let operation = NSPrintOperation(
      view: printableView(lines, printInfo: printInfo), printInfo: printInfo)
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
