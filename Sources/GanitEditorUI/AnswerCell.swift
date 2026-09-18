import AppKit

/// What the answer column shows for one line: a formatted result or a
/// failure's message.
struct AnswerCell: Equatable {
  /// A row of an answer's interpretation card.
  struct Detail: Equatable {
    let label: String
    let value: String
  }

  let text: String
  /// The exact value for Copy Full Precision; `nil` for failures.
  let fullPrecision: String?
  /// An answer from the assistant, which Ganit did not work out itself and so
  /// writes in a colour of its own.
  var isAssisted = false
  /// A request is in flight; the sheet stays editable.
  var isPending = false
  /// The value to fewer digits, marked `≈`, drawn when `text` does not fit so
  /// a unit or time zone is not the part cut off.
  var compactText: String?

  var isFailure: Bool {
    fullPrecision == nil && !isAssisted && !isPending
  }
}

/// Lists an answer's interpretation details as selectable label/value rows.
@MainActor
final class InterpretationViewController: NSViewController {
  private let details: [AnswerCell.Detail]
  private let fullPrecision: String?
  private let availableSize: NSSize
  private let pasteboard: NSPasteboard

  init(
    details: [AnswerCell.Detail], fullPrecision: String?, availableSize: NSSize,
    pasteboard: NSPasteboard
  ) {
    self.details = details
    self.fullPrecision = fullPrecision
    self.availableSize = availableSize
    self.pasteboard = pasteboard
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func loadView() {
    let width = min(560, availableSize.width - 32)
    let maximumHeight = min(600, availableSize.height - 32)
    let contentWidth = width - 2 * VisualStyle.Spacing.card
    let labelWidth = min(140, contentWidth * 0.3)
    let valueWidth = contentWidth - labelWidth - VisualStyle.Spacing.group - 16
    let grid = NSGridView(
      views: details.map { detail in
        let label = NSTextField(wrappingLabelWithString: detail.label)
        label.textColor = VisualStyle.Color.secondary
        label.alignment = .right
        label.preferredMaxLayoutWidth = labelWidth
        return [label, valueView(detail.value, width: valueWidth)]
      })
    grid.rowSpacing = VisualStyle.Spacing.related
    grid.columnSpacing = VisualStyle.Spacing.group
    grid.column(at: 0).width = labelWidth
    grid.column(at: 1).width = valueWidth
    grid.yPlacement = .top
    grid.frame = NSRect(x: 0, y: 0, width: contentWidth, height: grid.fittingSize.height)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.documentView = grid
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(scroll)
    let buttonHeight: CGFloat = fullPrecision == nil ? 0 : 32
    let height = min(maximumHeight, grid.fittingSize.height + 24 + buttonHeight)
    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: width),
      container.heightAnchor.constraint(equalToConstant: height),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12 - buttonHeight),
    ])
    if fullPrecision != nil {
      let button = NSButton(
        title: localized("menu.copyFullPrecision", "Copy Full Precision"),
        target: self, action: #selector(copyFullPrecision(_:)))
      button.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(button)
      NSLayoutConstraint.activate([
        button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
      ])
    }
    container.setFrameSize(NSSize(width: width, height: height))
    view = container
  }

  private func valueView(_ value: String, width: CGFloat) -> NSView {
    if value.count > 200 {
      let scroll = NSTextView.scrollableTextView()
      scroll.frame = NSRect(x: 0, y: 0, width: width, height: 96)
      scroll.drawsBackground = false
      scroll.translatesAutoresizingMaskIntoConstraints = false
      scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
      let text = scroll.documentView as! NSTextView
      text.setFrameSize(NSSize(width: width, height: 96))
      text.minSize = NSSize(width: width, height: 96)
      text.isEditable = false
      text.isRichText = false
      text.drawsBackground = false
      text.font = VisualStyle.Typography.detailValue
      text.textColor = .labelColor
      text.string = value
      text.scrollRangeToVisible(NSRange(location: 0, length: 0))
      scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
      return scroll
    }
    let field = NSTextField(wrappingLabelWithString: value)
    field.isSelectable = true
    field.font = VisualStyle.Typography.detailValue
    field.lineBreakMode = .byCharWrapping
    field.preferredMaxLayoutWidth = width
    return field
  }

  @objc func copyFullPrecision(_ sender: Any?) {
    guard let fullPrecision else { return }
    pasteboard.clearContents()
    pasteboard.setString(fullPrecision, forType: .string)
  }
}
