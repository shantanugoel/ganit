import AppKit
import GanitEngine

/// A sheet text view that draws each line's answer in a right-hand column.
///
/// Answers are drawn by an overlay view, never inserted into the text
/// storage, so source text and its offsets are unaffected. TextKit 2 renders
/// text in its own subviews, so the overlay sits above them and passes events
/// through. The text container is narrowed to leave the column free.
///
/// Clicking an answer selects it; Copy then copies the displayed answer.
/// Double-clicking inserts an upward `line N` reference at the insertion
/// point, Option-double-clicking copies the answer, and Space opens its
/// interpretation. The same commands act on the insertion point's line when
/// no answer is selected.
@MainActor
final class SheetTextView: NSTextView {
  /// The answer column shares the width with source up to these bounds.
  static let answerColumnFraction: CGFloat = 0.35
  static let answerColumnWidthRange: ClosedRange<CGFloat> = 140...360
  static let columnGap: CGFloat = 16

  /// Answer cells by line; lines without an entry show nothing.
  var answers: [LineID: AnswerCell] = [:] {
    didSet {
      if let selectedAnswer, answers[selectedAnswer] == nil {
        self.selectedAnswer = nil
      }
      answerOverlay().needsDisplay = true
    }
  }
  private(set) var selectedAnswer: LineID? {
    didSet { answerOverlay().needsDisplay = true }
  }
  /// Dotted underlines by line, as line-relative UTF-16 ranges. TextKit 2
  /// does not draw underline rendering attributes, so the overlay draws them.
  var underlines: [LineID: [(range: NSRange, color: NSColor)]] = [:] {
    didSet { answerOverlay().needsDisplay = true }
  }
  /// The line starting at a UTF-16 offset of the current source, if any.
  var lineID: (Int) -> LineID? = { _ in nil }
  /// The one-based number of the line containing a UTF-16 offset, and its ID.
  var line: (Int) -> (number: Int, id: LineID)? = { _ in nil }
  /// The one-based number of a line.
  var lineNumber: (LineID) -> Int? = { _ in nil }

  /// Where Copy Result writes.
  var pasteboard = NSPasteboard.general
  private(set) var interpretationPopover: NSPopover?

  private var overlay: AnswerOverlayView?

  fileprivate static let answerFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

  fileprivate func attributes(for cell: AnswerCell, selected: Bool) -> [NSAttributedString.Key: Any]
  {
    let color: NSColor =
      selected ? .selectedTextColor : cell.isFailure ? .systemRed : .labelColor
    return [.font: Self.answerFont, .foregroundColor: color]
  }

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
  func answerLayout(in rect: NSRect) -> [(line: LineID, cell: AnswerCell, rect: NSRect)] {
    guard !answers.isEmpty else {
      return []
    }
    let columnMaxX = bounds.maxX - textContainerInset.width
    let columnWidth = answerColumnWidth
    return visibleLines(in: rect).compactMap { line in
      guard let cell = answers[line.id] else {
        return nil
      }
      let size = (cell.text as NSString).size(
        withAttributes: attributes(for: cell, selected: false)
      )
      let width = min(ceil(size.width), columnWidth)
      let row = line.firstRow
      return (
        line.id,
        cell,
        NSRect(
          x: columnMaxX - width,
          y: line.frame.minY + row.typographicBounds.minY,
          width: width,
          height: row.typographicBounds.height
        )
      )
    }
  }

  // MARK: Answer selection and commands

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard
      let hit = answerLayout(in: NSRect(x: point.x, y: point.y, width: 1, height: 1))
        .first(where: { $0.rect.insetBy(dx: -4, dy: 0).contains(point) })
    else {
      selectedAnswer = nil
      super.mouseDown(with: event)
      return
    }
    window?.makeFirstResponder(self)
    selectedAnswer = hit.line
    if event.clickCount == 2 {
      if event.modifierFlags.contains(.option) {
        copyResult(nil)
      } else {
        insertReference(to: hit.line)
      }
    }
  }

  override func keyDown(with event: NSEvent) {
    guard selectedAnswer != nil else {
      super.keyDown(with: event)
      return
    }
    switch event.charactersIgnoringModifiers {
    case " ":
      showInterpretation(nil)
    case "\u{1b}":
      selectedAnswer = nil
    default:
      selectedAnswer = nil
      super.keyDown(with: event)
    }
  }

  override func copy(_ sender: Any?) {
    guard selectedAnswer != nil else {
      super.copy(sender)
      return
    }
    copyResult(sender)
  }

  /// Copies the displayed answer of the selected answer or the insertion
  /// point's line.
  @objc func copyResult(_ sender: Any?) {
    guard let cell = targetAnswer?.cell, !cell.isFailure else {
      NSSound.beep()
      return
    }
    copyToPasteboard(cell.text)
  }

  /// Copies the exact value of the selected answer or the insertion point's
  /// line.
  @objc func copyFullPrecision(_ sender: Any?) {
    guard let fullPrecision = targetAnswer?.cell.fullPrecision else {
      NSSound.beep()
      return
    }
    copyToPasteboard(fullPrecision)
  }

  @objc func showInterpretation(_ sender: Any?) {
    guard let target = targetAnswer,
      let rect = answerLayout(in: visibleRect).first(where: { $0.line == target.line })?.rect
    else {
      NSSound.beep()
      return
    }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = InterpretationViewController(details: target.cell.details)
    popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    interpretationPopover = popover
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copyResult(_:)), #selector(showInterpretation(_:)):
      return targetAnswer != nil
    case #selector(copyFullPrecision(_:)):
      return targetAnswer?.cell.fullPrecision != nil
    default:
      return super.validateUserInterfaceItem(item)
    }
  }

  /// The selected answer, or else the answer of the insertion point's line.
  private var targetAnswer: (line: LineID, cell: AnswerCell)? {
    let id = selectedAnswer ?? line(selectedRange().location)?.id
    return id.flatMap { id in answers[id].map { (id, $0) } }
  }

  /// Inserts `line N` for an answer above the insertion point's line.
  private func insertReference(to answerLine: LineID) {
    guard let number = lineNumber(answerLine),
      let caretLine = line(selectedRange().location),
      number < caretLine.number
    else {
      NSSound.beep()
      return
    }
    selectedAnswer = nil
    insertText("line \(number)", replacementRange: selectedRange())
  }

  private func copyToPasteboard(_ string: String) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  /// Underline segments for decorated ranges of lines visible in `rect`, just
  /// below each segment's baseline.
  func underlineLayout(in rect: NSRect) -> [(rect: NSRect, color: NSColor)] {
    guard !underlines.isEmpty,
      let layoutManager = textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else {
      return []
    }
    var layout: [(rect: NSRect, color: NSColor)] = []
    for line in visibleLines(in: rect) {
      for underline in underlines[line.id] ?? [] {
        guard
          let start = contentManager.location(
            line.location,
            offsetBy: underline.range.location
          ),
          let end = contentManager.location(start, offsetBy: underline.range.length),
          let range = NSTextRange(location: start, end: end)
        else {
          continue
        }
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired)
        {
          _, segment, baseline, _ in
          layout.append(
            (
              NSRect(
                x: segment.minX + textContainerOrigin.x,
                y: segment.minY + baseline + textContainerOrigin.y + 2,
                width: segment.width,
                height: 1.5
              ),
              underline.color
            )
          )
          return true
        }
      }
    }
    return layout
  }

  /// Lines whose first layout fragment intersects `rect`, in order.
  private func visibleLines(
    in rect: NSRect
  ) -> [(id: LineID, location: NSTextLocation, frame: NSRect, firstRow: NSTextLineFragment)] {
    guard let layoutManager = textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let start = layoutManager.textLayoutFragment(
        for: CGPoint(x: 0, y: max(rect.minY - textContainerOrigin.y, 0))
      )?.rangeInElement.location
    else {
      return []
    }
    var lines:
      [(id: LineID, location: NSTextLocation, frame: NSRect, firstRow: NSTextLineFragment)] = []
    layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) {
      fragment in
      let frame = fragment.layoutFragmentFrame.offsetBy(
        dx: textContainerOrigin.x,
        dy: textContainerOrigin.y
      )
      guard frame.minY <= rect.maxY else {
        return false
      }
      let location = fragment.rangeInElement.location
      let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
      if let id = lineID(offset), let row = fragment.textLineFragments.first {
        lines.append((id, location, frame, row))
      }
      return true
    }
    return lines
  }
}

/// Draws answers and underlines above the text view's content without
/// taking events.
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
    for (rect, color) in textView.underlineLayout(in: dirtyRect) {
      let path = NSBezierPath()
      path.move(to: NSPoint(x: rect.minX, y: rect.midY))
      path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
      path.lineWidth = rect.height
      path.setLineDash([2, 2], count: 2, phase: 0)
      color.setStroke()
      path.stroke()
    }
    for (line, cell, rect) in textView.answerLayout(in: dirtyRect) {
      let isSelected = line == textView.selectedAnswer
      if isSelected {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: 0), xRadius: 4, yRadius: 4).fill()
      }
      (cell.text as NSString).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: textView.attributes(for: cell, selected: isSelected)
      )
    }
  }
}
