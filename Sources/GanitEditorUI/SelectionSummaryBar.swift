import AppKit

/// What a selection of lines adds up to: the count of the answers it covers,
/// and their total and average when they can be added.
struct SelectionSummary: Equatable {
  let count: Int
  /// `nil` when the answers cannot be added, such as money and metres.
  let total: String?
  let average: String?
}

/// A bar below the sheet showing what the selected lines add up to.
///
/// It appears only while a selection covers more than one answer, because a
/// single answer is already beside its line, and it shows a count alone when
/// the answers cannot be added.
final class SelectionSummaryBar: NSView {
  private let label = NSTextField(labelWithString: "")

  var summary: SelectionSummary? {
    didSet {
      guard summary != oldValue else {
        return
      }
      isHidden = summary == nil
      label.stringValue = summary.map(Self.text) ?? ""
      needsDisplay = true
      superview?.needsLayout = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isHidden = true
    label.font = VisualStyle.Typography.caption
    label.textColor = VisualStyle.Color.secondary
    label.lineBreakMode = .byTruncatingTail
    label.setAccessibilityLabel(
      String(
        localized: "selection.accessibilityLabel",
        defaultValue: "Selection summary",
        bundle: .main
      )
    )
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  /// The height the bar needs, or zero when it has nothing to show.
  var fittingHeight: CGFloat {
    isHidden ? 0 : label.fittingSize.height + 2 * VisualStyle.Spacing.compact
  }

  override func layout() {
    super.layout()
    label.frame = bounds.insetBy(
      dx: VisualStyle.Spacing.standard, dy: VisualStyle.Spacing.compact)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
  }

  private static func text(_ summary: SelectionSummary) -> String {
    var parts = [
      "\(localized("selection.count", "Count")) \(summary.count)"
    ]
    if let total = summary.total {
      parts.append("\(localized("selection.total", "Total")) \(total)")
    }
    if let average = summary.average {
      parts.append("\(localized("selection.average", "Average")) \(average)")
    }
    return parts.joined(separator: "   ")
  }
}
