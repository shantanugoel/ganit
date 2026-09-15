import AppKit
import GanitEngine

/// A sheet text view that draws each line's answer in a right-hand column.
///
/// Answers are drawn by an overlay view, never inserted into the text
/// storage, so source text and its offsets are unaffected. TextKit 2 renders
/// text in its own subviews, so the overlay sits above them and passes events
/// through. The text container is narrowed to leave the column free.
@MainActor
final class SheetTextView: NSTextView {
  /// The answer column shares the width with source up to these bounds.
  static let answerColumnFraction: CGFloat = 0.35
  static let answerColumnWidthRange: ClosedRange<CGFloat> = 140...360
  static let columnGap: CGFloat = 16

  /// Formatted answers by line; lines without an entry show nothing.
  var answers: [LineID: String] = [:] {
    didSet { answerOverlay().needsDisplay = true }
  }
  /// The line IDs of the current source, used to find a paragraph's line.
  var lineIDsByUTF16Start: () -> [Int: LineID] = { [:] }

  private var overlay: AnswerOverlayView?

  fileprivate let answerAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor.labelColor,
  ]

  var answerColumnWidth: CGFloat {
    min(
      max(bounds.width * Self.answerColumnFraction, Self.answerColumnWidthRange.lowerBound),
      Self.answerColumnWidthRange.upperBound
    )
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    answerOverlay().frame = bounds
    answerOverlay().needsDisplay = true
    let sourceWidth =
      newSize.width - textContainerInset.width * 2 - answerColumnWidth - Self.columnGap
    textContainer?.size = NSSize(
      width: max(sourceWidth, Self.answerColumnWidthRange.lowerBound),
      height: CGFloat.greatestFiniteMagnitude
    )
  }

  override func didChangeText() {
    super.didChangeText()
    // Edits move lines, so answers must be redrawn in their new positions.
    answerOverlay().needsDisplay = true
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    // Keep answers above the text layout views TextKit adds.
    if let overlay, subview !== overlay {
      addSubview(overlay, positioned: .above, relativeTo: nil)
    }
  }

  private func answerOverlay() -> AnswerOverlayView {
    if let overlay {
      return overlay
    }
    let overlay = AnswerOverlayView(textView: self)
    self.overlay = overlay
    addSubview(overlay)
    return overlay
  }

  /// The answers to draw for lines whose first layout fragment intersects
  /// `rect`, each right-aligned in the answer column on its line's first row.
  func answerLayout(in rect: NSRect) -> [(line: LineID, text: String, rect: NSRect)] {
    guard !answers.isEmpty,
      let layoutManager = textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let start = layoutManager.textLayoutFragment(
        for: CGPoint(x: 0, y: max(rect.minY - textContainerOrigin.y, 0))
      )?.rangeInElement.location
    else {
      return []
    }
    let lineIDs = lineIDsByUTF16Start()
    let columnMaxX = bounds.maxX - textContainerInset.width
    let columnWidth = answerColumnWidth
    var layout: [(line: LineID, text: String, rect: NSRect)] = []
    layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) {
      fragment in
      let frame = fragment.layoutFragmentFrame.offsetBy(
        dx: textContainerOrigin.x,
        dy: textContainerOrigin.y
      )
      guard frame.minY <= rect.maxY else {
        return false
      }
      let offset = contentManager.offset(
        from: contentManager.documentRange.location,
        to: fragment.rangeInElement.location
      )
      if let line = lineIDs[offset], let text = answers[line],
        let row = fragment.textLineFragments.first
      {
        let size = (text as NSString).size(withAttributes: answerAttributes)
        let width = min(ceil(size.width), columnWidth)
        layout.append(
          (
            line,
            text,
            NSRect(
              x: columnMaxX - width,
              y: frame.minY + row.typographicBounds.minY,
              width: width,
              height: row.typographicBounds.height
            )
          )
        )
      }
      return true
    }
    return layout
  }
}

/// Draws answers above the text view's content without taking events.
@MainActor
private final class AnswerOverlayView: NSView {
  private unowned let textView: SheetTextView

  init(textView: SheetTextView) {
    self.textView = textView
    super.init(frame: textView.bounds)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override var isFlipped: Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    for (_, text, rect) in textView.answerLayout(in: dirtyRect) {
      (text as NSString).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: textView.answerAttributes
      )
    }
  }
}
