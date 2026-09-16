import AppKit
import GanitEditorUI
import GanitFormatting

/// The searchable in-app grammar and function reference.
@MainActor
public final class HelpWindowController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private let search = NSSearchField()
  private let table = NSTableView()
  private let detail = NSTextView()
  fileprivate let split = NSSplitView()
  private var shown: [Row] = []

  private enum Row {
    case group(LanguageTopic.Category)
    case topic(LanguageTopic)

    var id: String {
      switch self {
      case .group(let category):
        return "group.\(category.rawValue)"
      case .topic(let topic):
        return topic.id
      }
    }

    var title: String {
      switch self {
      case .group(let category):
        switch category {
        case .grammar:
          return localized("help.category.grammar", "Grammar")
        case .functions:
          return localized("help.category.functions", "Functions")
        case .keywords:
          return localized("help.category.keywords", "Keywords")
        }
      case .topic(let topic):
        return topic.title
      }
    }

    var topic: LanguageTopic? {
      if case .topic(let topic) = self {
        return topic
      }
      return nil
    }
  }

  public convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = localized("help.windowTitle", "Ganit Help")
    window.contentMinSize = NSSize(width: 520, height: 320)
    window.isReleasedWhenClosed = false
    self.init(window: window)
    window.contentViewController = RootController(owner: self)
    window.center()
    reload(query: "")
  }

  /// Brings the window forward, optionally on a named topic.
  public func show(topicID: String? = nil) {
    window?.makeKeyAndOrderFront(nil)
    if let topicID {
      reveal(topicID)
    } else {
      search.currentEditor()?.selectedRange = NSRange(
        location: 0, length: search.stringValue.utf16.count)
    }
  }

  public func reveal(_ topicID: String) {
    if !shown.contains(where: { $0.id == topicID }) {
      search.stringValue = ""
      reload(query: "")
    }
    guard let row = shown.firstIndex(where: { $0.id == topicID }) else {
      return
    }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
    showDetail(shown[row].topic)
  }

  fileprivate func buildView() -> NSView {
    search.placeholderString = localized("help.search", "Search grammar and functions")
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.sendsWholeSearchString = false
    search.target = self
    search.action = #selector(searchChanged(_:))
    search.setAccessibilityLabel(localized("help.search", "Search grammar and functions"))

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
    column.title = localized("help.topics", "Topics")
    table.addTableColumn(column)
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    table.allowsEmptySelection = false
    table.allowsMultipleSelection = false
    table.rowHeight = 22
    table.style = .sourceList
    table.usesAlternatingRowBackgroundColors = false
    let list = NSScrollView()
    list.documentView = table
    list.hasVerticalScroller = true
    list.borderType = .noBorder
    list.drawsBackground = false
    list.autoresizingMask = [.height]

    detail.isEditable = false
    detail.isRichText = true
    detail.drawsBackground = false
    detail.textContainerInset = NSSize(
      width: VisualStyle.Spacing.standard, height: VisualStyle.Spacing.standard)
    let reading = NSScrollView()
    reading.documentView = detail
    reading.hasVerticalScroller = true
    reading.borderType = .noBorder
    reading.drawsBackground = false
    reading.autoresizingMask = [.width, .height]
    detail.minSize = NSSize(width: 0, height: 0)
    detail.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    detail.isVerticallyResizable = true
    detail.isHorizontallyResizable = false
    detail.autoresizingMask = [.width]
    detail.textContainer?.widthTracksTextView = true
    detail.textContainer?.containerSize = NSSize(
      width: reading.contentSize.width, height: .greatestFiniteMagnitude)

    split.isVertical = true
    split.dividerStyle = .thin
    split.addArrangedSubview(list)
    split.addArrangedSubview(reading)
    split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
    split.translatesAutoresizingMaskIntoConstraints = false
    search.translatesAutoresizingMaskIntoConstraints = false

    let inset = VisualStyle.Spacing.group
    let container = NSView()
    container.addSubview(search)
    container.addSubview(split)
    NSLayoutConstraint.activate([
      search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
      search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
      search.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
      split.leadingAnchor.constraint(equalTo: search.leadingAnchor),
      split.trailingAnchor.constraint(equalTo: search.trailingAnchor),
      split.topAnchor.constraint(
        equalTo: search.bottomAnchor, constant: VisualStyle.Spacing.standard),
      split.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
    ])
    return container
  }

  fileprivate func layoutPanes() {
    guard split.frame.width > 400 else {
      return
    }
    let listWidth = split.subviews.first?.frame.width ?? 0
    if listWidth < 20 || listWidth > split.frame.width - 80 {
      split.setPosition(220, ofDividerAt: 0)
    }
    if let reading = split.subviews.dropFirst().first as? NSScrollView {
      let width = max(reading.contentSize.width, 1)
      detail.textContainer?.containerSize = NSSize(
        width: width, height: .greatestFiniteMagnitude)
    }
  }

  @objc private func searchChanged(_ sender: Any?) {
    reload(query: search.stringValue)
  }

  public func controlTextDidChange(_ obj: Notification) {
    reload(query: search.stringValue)
  }

  private func reload(query: String) {
    let selected =
      table.selectedRow >= 0 && table.selectedRow < shown.count
      ? shown[table.selectedRow].topic : nil
    let matches = LanguageReference.topics(matching: query)
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      shown = LanguageTopic.Category.allCases.flatMap { category in
        let topics = matches.filter { $0.category == category }
        guard !topics.isEmpty else {
          return [Row]()
        }
        return [.group(category)] + topics.map { .topic($0) }
      }
    } else {
      shown = matches.map { .topic($0) }
    }
    table.reloadData()
    let row =
      selected.flatMap { topic in shown.firstIndex(where: { $0.id == topic.id }) }
      ?? shown.firstIndex { $0.topic != nil }
    if let row {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      showDetail(shown[row].topic)
    } else {
      showDetail(nil)
    }
  }

  public func numberOfRows(in tableView: NSTableView) -> Int {
    shown.count
  }

  public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .group = shown[row] {
      return true
    }
    return false
  }

  public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    let label = NSTextField(labelWithString: shown[row].title)
    label.lineBreakMode = .byTruncatingTail
    if case .group = shown[row] {
      label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
      label.textColor = VisualStyle.Color.secondary
    } else {
      label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
      label.textColor = VisualStyle.Color.primary
    }
    return label
  }

  public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .group = shown[row] {
      return false
    }
    return true
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    let row = table.selectedRow
    guard row >= 0, row < shown.count else {
      showDetail(nil)
      return
    }
    showDetail(shown[row].topic)
  }

  private func showDetail(_ topic: LanguageTopic?) {
    detail.textStorage?.setAttributedString(Self.reading(for: topic))
  }

  /// The topic currently shown in the reading pane, for tests.
  public var selectedTopic: LanguageTopic? {
    let row = table.selectedRow
    guard row >= 0, row < shown.count else {
      return nil
    }
    return shown[row].topic
  }

  /// Types a query as the search field would.
  public func search(for query: String) {
    search.stringValue = query
    reload(query: query)
  }

  private static func reading(for topic: LanguageTopic?) -> NSAttributedString {
    guard let topic else {
      return NSAttributedString(
        string: localized("help.empty", "No matching topics."),
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
          .foregroundColor: VisualStyle.Color.secondary,
        ]
      )
    }
    let text = NSMutableAttributedString()
    func append(_ string: String, font: NSFont, color: NSColor = VisualStyle.Color.primary) {
      if text.length > 0 {
        text.append(NSAttributedString(string: "\n"))
      }
      text.append(
        NSAttributedString(
          string: string,
          attributes: [
            .font: font,
            .foregroundColor: color,
          ]
        )
      )
    }
    append(topic.title, font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
    if let signature = topic.signature {
      append(
        signature,
        font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        color: VisualStyle.Color.secondary
      )
    }
    append(topic.body, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
    if !topic.examples.isEmpty {
      append(
        localized("help.examples", "Examples"),
        font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        color: VisualStyle.Color.secondary
      )
      for example in topic.examples {
        append(
          example,
          font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
      }
    }
    return text
  }
}

@MainActor
private final class RootController: NSViewController {
  private weak var owner: HelpWindowController?

  init(owner: HelpWindowController) {
    self.owner = owner
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func loadView() {
    view = owner?.buildView() ?? NSView()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    owner?.layoutPanes()
  }
}
