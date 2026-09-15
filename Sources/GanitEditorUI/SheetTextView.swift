import AppKit
import GanitDiagnostics
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
  static let baseFontSize = VisualStyle.Typography.editorSize
  /// Text size steps; 1 is the standard 14 pt.
  static let textScales: [CGFloat] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

  /// Scales source, answers, and the answer column together.
  private(set) var textScale: CGFloat = 1 {
    didSet {
      font = VisualStyle.Typography.source(scale: textScale)
      setFrameSize(frame.size)
    }
  }

  /// A line's answer cell, computed when the line is drawn; lines without
  /// one show nothing.
  var answer: (LineID) -> AnswerCell? = { _ in nil }
  /// The rows of a line's interpretation card.
  var interpretation: (LineID) -> [AnswerCell.Detail] = { _ in [] }
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
  /// Every line's ID, UTF-16 start offset, and UTF-16 length, in order.
  var lineStarts: () -> [(id: LineID, start: Int, length: Int)] = { [] }
  private lazy var problemRotor = LineRotor(textView: self, failures: true)
  private lazy var resultRotor = LineRotor(textView: self, failures: false)

  /// Redraws answers after they change and clears a selection whose answer
  /// is gone.
  func answersDidChange() {
    if let selectedAnswer, answer(selectedAnswer) == nil {
      self.selectedAnswer = nil
    }
    answerOverlay().needsDisplay = true
  }

  /// Called after the overlay draws answers.
  var didDrawAnswers: () -> Void = {}
  /// Where Copy Result writes.
  var pasteboard = NSPasteboard.general
  private(set) var interpretationPopover: NSPopover?

  private var overlay: AnswerOverlayView?

  func attributes(for cell: AnswerCell, selected: Bool) -> [NSAttributedString.Key: Any] {
    let color =
      selected
      ? VisualStyle.Color.selectionText
      : cell.isFailure ? VisualStyle.Color.failure : VisualStyle.Color.primary
    return [.font: VisualStyle.Typography.answer(scale: textScale), .foregroundColor: color]
  }

  var answerColumnWidth: CGFloat {
    min(
      max(
        bounds.width * Self.answerColumnFraction,
        Self.answerColumnWidthRange.lowerBound * textScale
      ),
      Self.answerColumnWidthRange.upperBound * textScale
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
    let columnMaxX = bounds.maxX - textContainerInset.width
    let columnWidth = answerColumnWidth
    return visibleLines(in: rect).compactMap { line in
      guard let cell = answer(line.id) else {
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

  // MARK: Text size, appearance, and accessibility

  @objc func increaseTextSize(_ sender: Any?) {
    textScale = Self.textScales.first { $0 > textScale } ?? textScale
  }

  @objc func decreaseTextSize(_ sender: Any?) {
    textScale = Self.textScales.last { $0 < textScale } ?? textScale
  }

  @objc func resetTextSize(_ sender: Any?) {
    textScale = 1
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    guard window != nil else {
      return
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(displayOptionsDidChange(_:)),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    answerOverlay().needsDisplay = true
  }

  @objc private func displayOptionsDidChange(_ notification: Notification) {
    answerOverlay().needsDisplay = true
  }

  /// Visible answers and failure messages, as static text elements after the
  /// text view's own children.
  override func accessibilityChildren() -> [Any]? {
    let answerElements = answerLayout(in: visibleRect).map { line, cell, rect in
      let number = lineNumber(line) ?? 0
      let label =
        cell.isFailure
        ? String(
          format: String(
            localized: "accessibility.lineError", defaultValue: "Line %lld error", bundle: .main),
          number
        )
        : String(
          format: String(
            localized: "accessibility.lineResult", defaultValue: "Line %lld result", bundle: .main),
          number
        )
      let frame = window?.convertToScreen(convert(rect, to: nil)) ?? rect
      let element =
        NSAccessibilityElement.element(
          withRole: .staticText,
          frame: frame,
          label: label,
          parent: self
        ) as! NSAccessibilityElement
      element.setAccessibilityValue(cell.text)
      return element
    }
    return (super.accessibilityChildren() ?? []) + answerElements
  }

  /// Rotors that move VoiceOver between lines with problems or results.
  override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
    [
      NSAccessibilityCustomRotor(
        label: String(
          localized: "accessibility.problemsRotor", defaultValue: "Problems", bundle: .main),
        itemSearchDelegate: problemRotor),
      NSAccessibilityCustomRotor(
        label: String(
          localized: "accessibility.resultsRotor", defaultValue: "Results", bundle: .main),
        itemSearchDelegate: resultRotor),
    ]
  }

  /// The lines whose answers are failures, or results, in order.
  fileprivate func answerLines(failures: Bool) -> [(id: LineID, start: Int, length: Int)] {
    lineStarts().filter { answer($0.id).map { $0.isFailure == failures } ?? false }
  }

  /// `Line 3: This identifier is not defined.`, for announcements and rotors.
  fileprivate func spokenAnswer(_ id: LineID) -> String {
    String(
      format: String(
        localized: "accessibility.lineAnswer", defaultValue: "Line %lld: %@", bundle: .main),
      lineNumber(id) ?? 0, answer(id)?.text ?? ""
    )
  }

  /// Moves the insertion point to the next line with a problem, wrapping
  /// around, and announces the problem.
  @objc func nextProblem(_ sender: Any?) {
    moveToProblem(forward: true)
  }

  @objc func previousProblem(_ sender: Any?) {
    moveToProblem(forward: false)
  }

  private func moveToProblem(forward: Bool) {
    let problems = answerLines(failures: true)
    let caret = selectedRange().location
    let current = lineStarts().last { $0.start <= caret }?.start ?? 0
    let target =
      forward
      ? problems.first { $0.start > current } ?? problems.first
      : problems.last { $0.start < current } ?? problems.last
    guard let target else {
      NSSound.beep()
      return
    }
    setSelectedRange(NSRange(location: target.start, length: 0))
    scrollRangeToVisible(selectedRange())
    NSAccessibility.post(
      element: self, notification: .announcementRequested,
      userInfo: [
        .announcement: spokenAnswer(target.id),
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// Keyboard and VoiceOver equivalents of answer mouse interactions.
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    let actions: [(String, Selector)] = [
      (
        String(localized: "menu.copyResult", defaultValue: "Copy Result", bundle: .main),
        #selector(copyResult(_:))
      ),
      (
        String(
          localized: "menu.copyFullPrecision", defaultValue: "Copy Full Precision", bundle: .main),
        #selector(copyFullPrecision(_:))
      ),
      (
        String(
          localized: "menu.showInterpretation", defaultValue: "Show Interpretation", bundle: .main),
        #selector(showInterpretation(_:))
      ),
      (
        String(localized: "menu.insertReference", defaultValue: "Insert Reference", bundle: .main),
        #selector(insertReference(_:))
      ),
    ]
    return actions.map { name, action in
      NSAccessibilityCustomAction(name: name) { [weak self] in
        guard let self else {
          return false
        }
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        guard validateUserInterfaceItem(item) else {
          return false
        }
        perform(action, with: nil)
        return true
      }
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
    // Command-Return copies the current result; Return stays a newline.
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "\r"
    {
      copyResult(nil)
      return
    }
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

  /// Escape cancels up the responder chain, such as dismissing Quick Ganit,
  /// instead of offering text completion; it never changes the source.
  override func complete(_ sender: Any?) {
    nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
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
    popover.contentViewController = InterpretationViewController(
      details: interpretation(target.line)
    )
    popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    interpretationPopover = popover
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copyResult(_:)), #selector(showInterpretation(_:)):
      return targetAnswer != nil
    case #selector(copyFullPrecision(_:)):
      return targetAnswer?.cell.fullPrecision != nil
    case #selector(insertReference(_:)):
      return referenceTarget != nil
    case #selector(nextProblem(_:)), #selector(previousProblem(_:)):
      return !answerLines(failures: true).isEmpty
    case #selector(decreaseTextSize(_:)):
      return textScale > Self.textScales[0]
    case #selector(increaseTextSize(_:)):
      return textScale < Self.textScales[Self.textScales.count - 1]
    case #selector(resetTextSize(_:)):
      return textScale != 1
    case #selector(insertSubtotal(_:)), #selector(toggleHeading(_:)),
      #selector(toggleComment(_:)), #selector(insertDivider(_:)):
      return isEditable
    default:
      return super.validateUserInterfaceItem(item)
    }
  }

  /// The selected answer, or else the answer of the insertion point's line.
  private var targetAnswer: (line: LineID, cell: AnswerCell)? {
    let id = selectedAnswer ?? line(selectedRange().location)?.id
    return id.flatMap { id in answer(id).map { (id, $0) } }
  }

  /// Inserts a reference to the selected answer when it is above the
  /// insertion point, or else to the nearest result above.
  @objc func insertReference(_ sender: Any?) {
    guard let target = referenceTarget else {
      NSSound.beep()
      return
    }
    insertReference(to: target)
  }

  /// Inserts `subtotal` on a new line after the insertion point's line.
  @objc func insertSubtotal(_ sender: Any?) {
    insertLineAfterCurrent("subtotal")
  }

  @objc func insertDivider(_ sender: Any?) {
    insertLineAfterCurrent("---")
  }

  /// Adds or removes a `# ` prefix on every selected line.
  @objc func toggleHeading(_ sender: Any?) {
    togglePrefix("#")
  }

  /// Adds or removes a `// ` prefix on every selected line.
  @objc func toggleComment(_ sender: Any?) {
    togglePrefix("//")
  }

  private var referenceTarget: LineID? {
    guard let caret = line(selectedRange().location) else {
      return nil
    }
    if let selectedAnswer, let number = lineNumber(selectedAnswer), number < caret.number {
      return selectedAnswer
    }
    let string = self.string as NSString
    return nearestResult(
      before: string.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
    )
  }

  /// The nearest line with a result among the lines ending before `location`.
  private func nearestResult(before location: Int) -> LineID? {
    let string = self.string as NSString
    var location = location
    while location > 0 {
      let previous = string.lineRange(for: NSRange(location: location - 1, length: 0))
      if let id = lineID(previous.location), answer(id)?.isFailure == false {
        return id
      }
      location = previous.location
    }
    return nil
  }

  /// Copies the insertion point's result, or else the sheet's last result.
  /// Returns whether a result was copied.
  func copyCurrentOrLastResult() -> Bool {
    let id =
      targetAnswer.flatMap { $0.cell.isFailure ? nil : $0.line }
      ?? nearestResult(before: (string as NSString).length)
    guard let cell = id.flatMap(answer) else {
      return false
    }
    copyToPasteboard(cell.text)
    return true
  }

  private func insertLineAfterCurrent(_ text: String) {
    let string = self.string as NSString
    let lineRange = string.lineRange(for: selectedRange())
    var contentsEnd = 0
    string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
    let inserted = "\n" + text
    insertText(inserted, replacementRange: NSRange(location: contentsEnd, length: 0))
    setSelectedRange(NSRange(location: contentsEnd + (inserted as NSString).length, length: 0))
  }

  /// Toggles a marker on the selected lines as one edit: removes it when
  /// every non-blank line starts with it, and adds it otherwise.
  private func togglePrefix(_ marker: String) {
    let string = self.string as NSString
    let block = string.lineRange(for: selectedRange())
    let lines = string.substring(with: block).components(separatedBy: "\n")
    let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let removing =
      !contentLines.isEmpty
      && contentLines.allSatisfy { $0.drop(while: \.isWhitespace).hasPrefix(marker) }
    let toggled = lines.map { line -> String in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        return line
      }
      let indent = line.prefix(while: \.isWhitespace)
      var rest = line.dropFirst(indent.count)
      guard removing else {
        return indent + marker + " " + rest
      }
      rest = rest.dropFirst(marker.count)
      if rest.first == " " {
        rest = rest.dropFirst()
      }
      return String(indent + rest)
    }.joined(separator: "\n")
    insertText(toggled, replacementRange: block)
    setSelectedRange(NSRange(location: block.location, length: (toggled as NSString).length))
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
                height: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2.5 : 1.5
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
    let layoutInterval = SignpostedInterval.begin("AnswerLayout")
    defer {
      layoutInterval.end()
      textView.didDrawAnswers()
    }
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
        VisualStyle.Color.selectionBackground.setFill()
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

/// Finds the next or previous line with a problem or a result for a
/// VoiceOver rotor.
@MainActor
private final class LineRotor: NSObject,
  @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate
{
  private unowned let textView: SheetTextView
  private let failures: Bool

  init(textView: SheetTextView, failures: Bool) {
    self.textView = textView
    self.failures = failures
  }

  func rotor(
    _ rotor: NSAccessibilityCustomRotor,
    resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
  ) -> NSAccessibilityCustomRotor.ItemResult? {
    let lines = textView.answerLines(failures: failures)
    let current = searchParameters.currentItem?.targetRange.location
    let line: (id: LineID, start: Int, length: Int)?
    switch (searchParameters.searchDirection, current) {
    case (.next, let current?):
      line = lines.first { $0.start > current }
    case (.previous, let current?):
      line = lines.last { $0.start < current }
    case (.next, nil):
      line = lines.first
    default:
      line = lines.last
    }
    guard let line else {
      return nil
    }
    let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
    result.targetRange = NSRange(location: line.start, length: line.length)
    result.customLabel = textView.spokenAnswer(line.id)
    return result
  }
}
