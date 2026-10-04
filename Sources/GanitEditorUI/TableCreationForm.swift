import AppKit
import GanitEngine

/// The insertion form keeps column settings when the user changes its size.
@MainActor
final class TableCreationForm: NSView {
  let name = NSTextField(string: "Table")
  let starter = NSPopUpButton()
  var columnRules: [Int: String] = [:]
  var percentageColumn: Int?
  let rows = NSTextField(string: "5")
  let columnCount = NSPopUpButton()
  let headerRow = NSButton(
    checkboxWithTitle: "First pasted row contains headers", target: nil, action: nil)
  let formulas = NSButton(
    checkboxWithTitle: "Interpret = inputs as formulas", target: nil, action: nil)
  private(set) var headers: [NSTextField] = []
  private(set) var policies: [NSPopUpButton] = []
  private let scroll = NSScrollView()
  private let content = FlippedTableContent()
  private let nameLabel = NSTextField(labelWithString: "Table name")
  private let rowsLabel = NSTextField(labelWithString: "Rows")
  private let columnsLabel = NSTextField(labelWithString: "Columns")
  private let headings = NSTextField(labelWithString: "Column header")
  private let types = NSTextField(labelWithString: "Input type")
  private let hint = NSTextField(
    wrappingLabelWithString:
      "Use up to 32 columns and 4,000 cells. Enter = to use a formula in any cell.")
  private let pasted: [[String]]?
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 420, height: 330) }

  var settings: [(String, TableInputPolicy)] {
    let count = pasted?.first?.count ?? columnCount.indexOfSelectedItem + 1
    return (0..<count).map {
      (
        headers[$0].stringValue,
        policies[$0].indexOfSelectedItem == 0
          ? .value : policies[$0].indexOfSelectedItem == 1 ? .text : .automatic
      )
    }
  }
  init(pasted: [[String]]?) {
    self.pasted = pasted
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 330))
    name.setAccessibilityLabel("Table name")
    rows.setAccessibilityLabel("Number of data rows")
    let formatter = NumberFormatter()
    formatter.allowsFloats = false
    rows.formatter = formatter
    columnCount.addItems(withTitles: (1...32).map(String.init))
    columnCount.selectItem(at: (pasted?.first?.count ?? 3) - 1)
    columnCount.setAccessibilityLabel("Number of columns")
    columnCount.target = self
    columnCount.action = #selector(sizeChanged)
    headerRow.state = .on
    hint.textColor = .secondaryLabelColor
    hint.font = .systemFont(ofSize: 12)
    scroll.hasVerticalScroller = true
    scroll.documentView = content
    scroll.borderType = .bezelBorder
    for control in [
      nameLabel, name, rowsLabel, rows, columnsLabel, columnCount, headerRow, headings, types,
      scroll, formulas, hint,
    ] {
      addSubview(control)
    }
    headerRow.isHidden = pasted == nil
    formulas.isHidden = pasted == nil
    for control in [rowsLabel, rows, columnsLabel, columnCount] { control.isHidden = pasted != nil }
    starter.addItems(withTitles: ["Blank", "Shopping", "Travel", "Quote", "Portfolio"])
    starter.target = self
    starter.action = #selector(starterChanged)
    starter.setAccessibilityLabel("Starter table")
    starter.isHidden = pasted != nil
    addSubview(starter)
    sizeChanged()
    layout()
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  @objc func starterChanged() {
    let choice = starter.indexOfSelectedItem
    let templates = [
      ["Column 1", "Column 2", "Column 3"], ["Item", "Qty", "Price", "Amount"],
      ["Item", "Local cost", "Currency", "Note"], ["Task", "Hours", "Rate", "Amount", "Note"],
      [
        "Ticker", "Quantity", "Buy price", "Now price", "Cost", "Value", "Gain", "Return",
        "Decision",
      ],
    ]
    let names = templates[choice]
    columnCount.selectItem(at: names.count - 1)
    sizeChanged()
    for (index, title) in names.enumerated() {
      headers[index].stringValue = title
      policies[index].selectItem(at: 2)
    }
    columnRules = [:]
    percentageColumn = nil
    if choice == 1 { columnRules = [3: "=[@Qty] * [@Price]"] }
    if choice == 3 { columnRules = [3: "=[@Hours] * [@Rate]"] }
    if choice == 4 {
      columnRules = [
        4: "=[@Quantity] * [@[Buy price]]", 5: "=[@Quantity] * [@[Now price]]",
        6: "=[@Value] - [@Cost]", 7: "=[@[Now price]] / [@[Buy price]] - 1",
      ]
      percentageColumn = 7
    }
    if choice > 0 { name.stringValue = starter.titleOfSelectedItem ?? "Table" }
    needsLayout = true
  }
  @objc func sizeChanged() {
    let count = pasted?.first?.count ?? columnCount.indexOfSelectedItem + 1
    while headers.count < count {
      let index = headers.count
      let header = NSTextField(string: pasted?[0][index] ?? "Column \(index + 1)")
      header.setAccessibilityLabel("Column \(index + 1) header")
      let policy = NSPopUpButton()
      policy.addItems(withTitles: ["Value", "Text", "Automatic"])
      policy.selectItem(at: 2)
      policy.setAccessibilityLabel("Column \(index + 1) input type")
      headers.append(header)
      policies.append(policy)
    }
    for child in content.subviews { child.removeFromSuperview() }
    for index in 0..<count {
      let letter = NSTextField(labelWithString: TableSourceDocument.letters(index))
      letter.tag = index
      letter.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
      letter.textColor = .secondaryLabelColor
      content.addSubview(letter)
      content.addSubview(headers[index])
      content.addSubview(policies[index])
    }
    needsLayout = true
    layout()
  }
  override func layout() {
    super.layout()
    let width = bounds.width
    nameLabel.frame = .init(x: 0, y: 5, width: 90, height: 22)
    name.frame = .init(x: 94, y: 0, width: max(100, width - 94), height: 28)
    starter.frame = .init(x: 0, y: 72, width: 210, height: 26)
    rowsLabel.frame = .init(x: 0, y: 45, width: 44, height: 22)
    rows.frame = .init(x: 48, y: 40, width: 80, height: 28)
    columnsLabel.frame = .init(x: 155, y: 45, width: 70, height: 22)
    columnCount.frame = .init(x: 230, y: 40, width: 80, height: 28)
    headerRow.frame = .init(x: 0, y: 40, width: width, height: 28)
    headings.frame = .init(x: 40, y: 105, width: 240, height: 22)
    types.frame = .init(x: width - 112, y: 105, width: 112, height: 22)
    let footerHeight: CGFloat = pasted == nil ? 48 : 82
    scroll.frame = .init(
      x: 0, y: 130, width: width, height: max(120, bounds.height - 130 - footerHeight))
    formulas.frame = .init(x: 0, y: bounds.height - 76, width: width, height: 28)
    hint.frame = .init(x: 0, y: bounds.height - 42, width: width, height: 40)
    let count = settings.count
    let contentWidth = scroll.contentSize.width
    content.frame = .init(
      x: 0, y: 0, width: contentWidth,
      height: max(scroll.contentSize.height, CGFloat(count) * 34 + 8))
    for index in 0..<count {
      let y = CGFloat(index) * 34 + 4
      headers[index].frame = .init(x: 36, y: y, width: max(80, contentWidth - 158), height: 26)
      policies[index].frame = .init(x: contentWidth - 116, y: y, width: 110, height: 28)
    }
    for label in content.subviews.compactMap({ $0 as? NSTextField })
    where !headers.contains(where: { $0 === label }) {
      label.frame = .init(x: 8, y: CGFloat(label.tag) * 34 + 10, width: 24, height: 20)
    }
  }
}
