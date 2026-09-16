import AppKit

/// A small list of completions anchored under the insertion point.
@MainActor
final class CompletionList {
  private let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 280, height: 140),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
  )
  private let table = NSTableView()
  private var items: [String] = []
  private(set) var selected = 0
  private var isUpdating = false
  /// Inserts the highlighted row; a click sends this, arrows only move.
  var onChoose: (() -> Void)?

  var isVisible: Bool {
    panel.isVisible
  }

  var selectedItem: String? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  var titles: [String] {
    items
  }

  init() {
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = true
    panel.level = .popUpMenu
    panel.backgroundColor = .windowBackgroundColor
    panel.hasShadow = true
    panel.isOpaque = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 20
    table.style = .plain
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.dataSource = source
    table.delegate = source
    table.target = source
    table.action = #selector(CompletionListSource.choose(_:))
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .lineBorder
    panel.contentView = scroll
    source.owner = self
  }

  func show(_ items: [String], at rect: NSRect, in view: NSView) {
    isUpdating = true
    self.items = Array(items.prefix(8))
    selected = 0
    source.items = self.items
    table.reloadData()
    if !self.items.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    let height = min(CGFloat(self.items.count) * table.rowHeight + 4, 140)
    let width = Self.width(for: self.items)
    var frame = rect
    frame.size = NSSize(width: width, height: height)
    if let window = view.window {
      frame.origin = window.convertToScreen(view.convert(rect, to: nil)).origin
      frame.origin.y -= height
    }
    table.tableColumns.first?.width = width
    panel.setFrame(frame, display: true)
    panel.orderFront(nil)
    isUpdating = false
  }

  func hide() {
    panel.orderOut(nil)
    items = []
    source.items = []
    table.reloadData()
  }

  @discardableResult
  func move(_ delta: Int) -> Bool {
    guard isVisible, !items.isEmpty else {
      return false
    }
    selected = min(max(selected + delta, 0), items.count - 1)
    table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
    table.scrollRowToVisible(selected)
    return true
  }

  func chooseClickedRow() {
    guard !isUpdating, table.clickedRow >= 0 else {
      return
    }
    selected = table.clickedRow
    onChoose?()
  }

  /// Wide enough for the longest signature, without covering the sheet.
  private static func width(for items: [String]) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let longest =
      items.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    return min(max(ceil(longest) + 24, 220), 420)
  }

  fileprivate let source = CompletionListSource()
}

@MainActor
private final class CompletionListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  weak var owner: CompletionList?
  var items: [String] = []

  func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard items.indices.contains(row) else {
      return nil
    }
    let label = NSTextField(labelWithString: items[row])
    label.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.textColor = VisualStyle.Color.primary
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  @objc func choose(_ sender: Any?) {
    owner?.chooseClickedRow()
  }
}
