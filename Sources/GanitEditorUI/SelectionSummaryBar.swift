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
  private let askButton = NSButton()

  /// The bar grows one trailing action: a multi-line selection is exactly when a
  /// transform makes sense, so Ask belongs here and nowhere else.
  var onAsk: (() -> Void)?
  var canAsk: () -> Bool = { false } {
    didSet { needsLayout = true }
  }

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
    askButton.title = localized("menu.askGanit", "Ask Ganit…")
    askButton.bezelStyle = .inline
    askButton.font = VisualStyle.Typography.caption
    askButton.target = self
    askButton.action = #selector(ask)
    askButton.setAccessibilityLabel(
      localized("selection.ask", "Ask Ganit about the selected lines"))
    askButton.translatesAutoresizingMaskIntoConstraints = true
    askButton.isHidden = true
    addSubview(askButton)
  }

  @objc private func ask() { onAsk?() }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  /// The height the bar needs, or zero when it has nothing to show.
  var fittingHeight: CGFloat {
    isHidden
      ? 0
      : max(label.fittingSize.height, askButton.fittingSize.height)
        + 2 * VisualStyle.Spacing.compact
  }

  override func layout() {
    super.layout()
    let showAsk = summary != nil && canAsk()
    askButton.isHidden = !showAsk
    let width = showAsk ? askButton.fittingSize.width + VisualStyle.Spacing.standard : 0
    askButton.frame =
      showAsk
      ? NSRect(
        x: bounds.maxX - width, y: (bounds.height - askButton.fittingSize.height) / 2,
        width: askButton.fittingSize.width, height: askButton.fittingSize.height)
      : .zero
    label.frame = NSRect(
      x: VisualStyle.Spacing.standard, y: VisualStyle.Spacing.compact,
      width: max(0, bounds.width - 2 * VisualStyle.Spacing.standard - width),
      height: bounds.height - 2 * VisualStyle.Spacing.compact)
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
