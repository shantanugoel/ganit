import AppKit

/// Counts selected calculations, including unresolved ones, and aggregates
/// their values only when the whole selection is resolved.
struct SelectionSummary: Equatable {
  let count: Int
  let calculatedCount: Int
  let failedCount: Int
  let pendingCount: Int
  /// `nil` when the answers cannot be added, such as money and metres.
  let total: String?
  let average: String?
}

/// A bar below the sheet showing what the selected lines add up to.
///
/// It appears for multiple calculations, shows unresolved counts, and omits
/// aggregates when calculations are unresolved or values cannot be added.
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
      "\(localized("selection.selected", "Selected")) \(summary.count)",
      "\(localized("selection.calculated", "Calculated")) \(summary.calculatedCount)",
    ]
    if summary.failedCount + summary.pendingCount > 0 {
      parts.insert(localized("selection.incomplete", "Incomplete"), at: 0)
      parts.append("\(localized("selection.failed", "Failed")) \(summary.failedCount)")
      parts.append("\(localized("selection.pending", "Pending")) \(summary.pendingCount)")
    }
    if let total = summary.total {
      parts.append("\(localized("selection.total", "Total")) \(total)")
    }
    if let average = summary.average {
      parts.append("\(localized("selection.average", "Average")) \(average)")
    }
    return parts.joined(separator: "   ")
  }
}
