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
  private var items: [CompletionItem] = []
  private(set) var selected = 0
  /// Set once an arrow key picks a row, so Return can still end a line that
  /// happens to start a completion, such as `5 min`.
  private(set) var isPicked = false
  private var isUpdating = false
  /// Inserts the highlighted row; a click sends this, arrows only move.
  var onChoose: (() -> Void)?

  var isVisible: Bool {
    panel.isVisible
  }

  var selectedItem: CompletionItem? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  var titles: [String] {
    items.map(\.insertion)
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

  func show(_ items: [CompletionItem], at rect: NSRect, in view: NSView) {
    isUpdating = true
    self.items = Array(items.prefix(200))
    selected = 0
    isPicked = false
    source.items = self.items
    table.rowHeight = items.contains { !$0.detail.isEmpty } ? 40 : 20
    table.reloadData()
    if !self.items.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    let height = min(CGFloat(self.items.count) * table.rowHeight + 4, 240)
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
    isPicked = true
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
  private static func width(for items: [CompletionItem]) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let longest =
      items.map {
        (max($0.insertion.count, $0.detail.count) == $0.insertion.count
          ? $0.insertion : $0.detail) as NSString
      }.map { $0.size(withAttributes: [.font: font]).width }.max() ?? 0
    return min(max(ceil(longest) + 24, 220), 420)
  }

  fileprivate let source = CompletionListSource()
}

@MainActor
private final class CompletionListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  weak var owner: CompletionList?
  var items: [CompletionItem] = []

  func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard items.indices.contains(row) else {
      return nil
    }
    let item = items[row]
    let label = NSTextField(labelWithString: item.insertion)
    label.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.textColor = VisualStyle.Color.primary
    label.lineBreakMode = .byTruncatingTail
    guard !item.detail.isEmpty else { return label }
    let detail = NSTextField(labelWithString: item.detail)
    detail.font = VisualStyle.Typography.caption
    detail.textColor = VisualStyle.Color.secondary
    detail.lineBreakMode = .byTruncatingTail
    let stack = NSStackView(views: [label, detail])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.toolTip = item.insertion + " — " + item.detail
    stack.setAccessibilityLabel(stack.toolTip)
    return stack
  }

  @objc func choose(_ sender: Any?) {
    owner?.chooseClickedRow()
  }
}
