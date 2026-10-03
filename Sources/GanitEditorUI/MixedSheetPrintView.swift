import AppKit

/// One item of the printable layout: a prose line, a table name, a failure
/// note, or one grid row with its column widths.
struct PrintItem {
  enum Content {
    /// Prose: the source, then the answer at a right tab stop.
    case line(NSAttributedString)
    case tableName(NSAttributedString)
    /// A whole-table failure, shown under the table name.
    case note(NSAttributedString)
    case header(columns: [NSAttributedString], widths: [CGFloat])
    case row(columns: [NSAttributedString], widths: [CGFloat], failures: [Bool])
    case spacer(CGFloat)
  }

  var content: Content
  /// The table this row belongs to, so a continuation page can repeat its
  /// header. `nil` for prose.
  var tableIndex: Int?
  var isHeader = false

  var columns: (cells: [NSAttributedString], widths: [CGFloat])? {
    switch content {
    case .header(let columns, let widths), .row(let columns, let widths, _):
      return (columns, widths)
    default: return nil
    }
  }
}

/// Prints and exports a sheet as pages: prose lines with answers at a right
/// tab stop, then each table as a grid with aligned columns. When a table
/// continues on the next page, its header row repeats at the top of that
/// page. Each page region is the printable area, and its items are drawn
/// from the top with the heights the pagination measured.
@MainActor
final class MixedSheetPrintView: NSView {
  /// The items of each page, and each item's measured height.
  private(set) var pages: [[PrintItem]] = []
  private(set) var pageItemHeights: [[CGFloat]] = []
  /// How much of each page its items fill, at most the printable height.
  private(set) var pageHeights: [CGFloat] = []
  private let blocks: [RenderedBlock]
  private let contentWidth: CGFloat
  private let contentHeight: CGFloat
  static let rowPadding: CGFloat = 3

  init(blocks: [RenderedBlock], printInfo: NSPrintInfo) {
    self.blocks = blocks
    contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
    contentHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
    super.init(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override var isFlipped: Bool { true }

  override func knowsPageRange(_ range: UnsafeMutablePointer<NSRange>) -> Bool {
    layoutPages()
    range.pointee.location = 1
    range.pointee.length = max(pages.count, 1)
    frame = NSRect(
      x: 0, y: 0, width: contentWidth,
      height: CGFloat(max(pages.count, 1)) * contentHeight)
    return true
  }

  /// Every page region is the printable area, stacked downward in this
  /// flipped view.
  override func rectForPage(_ page: Int) -> NSRect {
    let index = max(0, min(pages.count, page) - 1)
    return NSRect(
      x: 0, y: CGFloat(index) * contentHeight, width: contentWidth, height: contentHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    var top: CGFloat = 0
    for (index, page) in pages.enumerated() {
      defer { top += contentHeight }
      guard
        dirtyRect.intersects(NSRect(x: 0, y: top, width: contentWidth, height: contentHeight))
      else { continue }
      var y = top
      for (position, item) in page.enumerated() {
        draw(item, at: y)
        y += pageItemHeights[index][position]
      }
    }
  }

  // MARK: - Layout

  /// Lays every block out, then splits the items into pages that fit, and
  /// repeats a table's header when its rows continue on the next page.
  func layoutPages() {
    guard pages.isEmpty else { return }
    var items: [PrintItem] = []
    var tableCount = 0
    for block in blocks {
      switch block {
      case .lines(let lines):
        for line in lines {
          items.append(PrintItem(content: .line(Self.line(line, width: contentWidth))))
        }
        items.append(PrintItem(content: .spacer(VisualStyle.Spacing.related)))
      case .table(let table):
        items += Self.tableItems(table, index: tableCount, contentWidth: contentWidth)
        tableCount += 1
        items.append(PrintItem(content: .spacer(VisualStyle.Spacing.related)))
      }
    }
    pages = []
    pageItemHeights = []
    pageHeights = []
    var current: [PrintItem] = []
    var currentHeights: [CGFloat] = []
    var used: CGFloat = 0
    for item in items {
      let itemHeight = measuredHeight(of: item)
      let fits = used + itemHeight <= contentHeight
      if !fits, !current.isEmpty {
        pages.append(current)
        pageItemHeights.append(currentHeights)
        pageHeights.append(used)
        // A row that continues a table starts its page under that table's
        // header again.
        var next: [PrintItem] = []
        if item.tableIndex != nil, !item.isHeader,
          let header = items.first(where: { $0.isHeader && $0.tableIndex == item.tableIndex })
        {
          next.append(header)
        }
        current = next
        currentHeights = current.map { measuredHeight(of: $0) }
        used = currentHeights.reduce(0, +)
      }
      current.append(item)
      currentHeights.append(itemHeight)
      used += itemHeight
    }
    if !current.isEmpty {
      pages.append(current)
      pageItemHeights.append(currentHeights)
      pageHeights.append(used)
    }
    if pages.isEmpty {
      pages = [[]]
      pageItemHeights = [[]]
      pageHeights = [0]
    }
  }

  /// Prose: the source, then the answer at a right tab stop, as the sheet
  /// shows it.
  static func line(_ line: ExportedLine, width: CGFloat) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width - 1)]
    let text = NSMutableAttributedString()
    text.append(
      NSAttributedString(
        string: line.source,
        attributes: [
          .font: VisualStyle.Typography.source(scale: 1), .paragraphStyle: paragraph,
          .foregroundColor: VisualStyle.Color.primary,
        ]))
    if let answer = line.annotatedAnswer {
      text.append(
        NSAttributedString(
          string: "\t" + answer,
          attributes: [
            .font: VisualStyle.Typography.answer(scale: 1), .paragraphStyle: paragraph,
            .foregroundColor: line.isFailure
              ? VisualStyle.Color.failure : VisualStyle.Color.primary,
          ]))
    }
    return text
  }

  /// One table as items: the name, failure notes, a header, the rows and
  /// the totals footer, with column widths that fit the page.
  static func tableItems(
    _ table: RenderedTable, index tableIndex: Int, contentWidth width: CGFloat
  ) -> [PrintItem] {
    var items: [PrintItem] = []
    if let name = table.name {
      items.append(PrintItem(content: .tableName(bold(name)), tableIndex: tableIndex))
    }
    for failure in table.failures {
      items.append(PrintItem(content: .note(failureText(failure)), tableIndex: tableIndex))
    }
    guard !table.headers.isEmpty else {
      return items
    }
    let headerFont = NSFont.systemFont(ofSize: VisualStyle.Typography.editorSize, weight: .semibold)
    let cellFont = VisualStyle.Typography.answer(scale: 1)
    let measured: [[String]] =
      [table.headers]
      + table.rows.map { $0.map(\.text) }
      + (table.totals.isEmpty ? [] : [table.totals.map(\.text)])
    var widths = Array(repeating: CGFloat(0), count: table.headers.count)
    for row in measured {
      for (column, text) in row.enumerated() where column < widths.count {
        widths[column] = max(
          widths[column],
          NSAttributedString(string: text, attributes: [.font: cellFont]).size().width + 16)
        widths[column] = max(
          widths[column],
          NSAttributedString(string: text, attributes: [.font: headerFont]).size().width + 16)
      }
    }
    // A column never takes more than two fifths of the page, and the grid
    // always fits the page width.
    let cap = width * 0.4
    for (column, _) in widths.enumerated() { widths[column] = min(widths[column], cap) }
    let total = widths.reduce(0, +)
    if total > width, total > 0 {
      widths = widths.map { $0 * width / total }
    }
    items.append(
      PrintItem(
        content: .header(
          columns: table.headers.map {
            NSAttributedString(
              string: $0,
              attributes: [.font: headerFont, .foregroundColor: VisualStyle.Color.primary])
          }, widths: widths), tableIndex: tableIndex, isHeader: true))
    for row in table.rows {
      items.append(
        PrintItem(
          content: .row(
            columns: row.map {
              NSAttributedString(
                string: $0.text,
                attributes: [
                  .font: cellFont,
                  .foregroundColor: $0.isFailure
                    ? VisualStyle.Color.failure : VisualStyle.Color.primary,
                ])
            }, widths: widths, failures: row.map(\.isFailure)), tableIndex: tableIndex))
    }
    if !table.totals.isEmpty {
      var cells = Array(repeating: "", count: table.headers.count)
      for total in table.totals where cells.indices.contains(total.columnIndex) {
        cells[total.columnIndex] = total.text
      }
      items.append(
        PrintItem(
          content: .row(
            columns: cells.map {
              NSAttributedString(
                string: $0,
                attributes: [
                  .font: NSFont.systemFont(
                    ofSize: VisualStyle.Typography.editorSize, weight: .semibold),
                  .foregroundColor: VisualStyle.Color.primary,
                ])
            }, widths: widths, failures: []), tableIndex: tableIndex))
    }
    return items
  }

  private static func failureText(_ failure: String) -> NSAttributedString {
    NSAttributedString(
      string: failure,
      attributes: [
        .font: VisualStyle.Typography.source(scale: 1),
        .foregroundColor: VisualStyle.Color.failure,
      ])
  }

  private static func bold(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: VisualStyle.Typography.editorSize, weight: .semibold),
        .foregroundColor: VisualStyle.Color.primary,
      ])
  }

  private func measuredHeight(of item: PrintItem) -> CGFloat {
    switch item.content {
    case .line(let text), .tableName(let text), .note(let text):
      return textHeight(of: text, width: contentWidth)
    case .header(let columns, let widths), .row(let columns, let widths, _):
      let tallest =
        zip(columns, widths)
        .map { textHeight(of: $0.0, width: max($0.1 - 8, 1)) }
        .max() ?? 0
      return tallest + Self.rowPadding * 2
    case .spacer(let height): return height
    }
  }

  private func textHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    text.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
  }

  // MARK: - Drawing

  private func draw(_ item: PrintItem, at y: CGFloat) {
    switch item.content {
    case .line(let text), .tableName(let text), .note(let text):
      text.draw(
        with: NSRect(
          x: 0, y: y, width: contentWidth, height: textHeight(of: text, width: contentWidth)),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
    case .header(let columns, let widths), .row(let columns, let widths, _):
      var x: CGFloat = 0
      for (column, text) in columns.enumerated() {
        let cellHeight = textHeight(of: text, width: max(widths[column] - 8, 1))
        text.draw(
          with: NSRect(
            x: x, y: y + Self.rowPadding, width: max(widths[column] - 8, 1), height: cellHeight),
          options: [.usesLineFragmentOrigin, .usesFontLeading])
        x += widths[column]
      }
      if item.isHeader {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y + Self.rowPadding * 2))
        path.line(to: NSPoint(x: contentWidth, y: y + Self.rowPadding * 2))
        VisualStyle.Color.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
      }
    case .spacer: break
    }
  }
}
