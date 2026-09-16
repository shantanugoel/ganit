import AppKit
import GanitDiagnostics
import GanitEngine
import GanitFormatting

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

  /// Writes each answer just after its own line rather than in the column,
  /// which gives the source the full width to be prose in.
  var writesAnswersInline = false {
    didSet {
      guard writesAnswersInline != oldValue else {
        return
      }
      setFrameSize(frame.size)
    }
  }

  /// Draws the rule at the answer column's edge.
  var showsAnswerSeparator = true {
    didSet { answerOverlay().needsDisplay = true }
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
  /// How the sheet's grammar reads numbers, for finding the one a scrub steps.
  var lexingConfiguration = LexingConfiguration.englishUnitedStates
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
  /// Opens Help on a topic id, such as `function.sqrt`.
  var openHelp: ((String) -> Void)?
  /// The diagnostic the newest evaluation flagged for a line, if any.
  var lineDiagnostic: (LineID) -> FormattedDiagnostic? = { _ in nil }
  /// Whether Ask Assistant can send the current line.
  var canAskAssistant: () -> Bool = { false }
  /// Asks the assistant again about the current line.
  var onAskAssistant: () -> Void = {}
  /// Whether Change Answer can replace the current assistant value.
  var canChangeAssistantAnswer: () -> Bool = { false }
  /// Opens a field to replace the current assistant value.
  var onChangeAssistantAnswer: () -> Void = {}
  /// Overrides the Autocomplete preference, for tests.
  var completesWhileTyping: Bool?
  private var helpTracking: NSTrackingArea?
  private var helpTooltip = ""
  private let completionList = CompletionList()

  private func configureCompletions() {
    guard completionList.onChoose == nil else {
      return
    }
    completionList.onChoose = { [weak self] in
      _ = self?.insertSelectedCompletion()
    }
  }

  private var overlay: AnswerOverlayView?

  func attributes(for cell: AnswerCell, selected: Bool) -> [NSAttributedString.Key: Any] {
    [
      .font: VisualStyle.Typography.answer(scale: textScale),
      .foregroundColor: color(cell, selected),
    ]
  }

  /// An answer beside the source is a column of its own; an answer sitting in
  /// a line of prose is a remark on that line, and is written as one.
  private func color(_ cell: AnswerCell, _ selected: Bool) -> NSColor {
    if selected {
      return VisualStyle.Color.selectionText
    }
    if cell.isFailure {
      return VisualStyle.Color.failure
    }
    if cell.isAssisted {
      return VisualStyle.Color.assisted
    }
    if cell.isPending {
      return VisualStyle.Color.secondary
    }
    return writesAnswersInline ? VisualStyle.Color.secondary : VisualStyle.Color.primary
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

  /// Where the rule between source and answers belongs, or `nil` when it is
  /// hidden or there is no column for it to mark.
  var answerSeparatorX: CGFloat? {
    guard showsAnswerSeparator, !writesAnswersInline else {
      return nil
    }
    return (bounds.maxX - textContainerInset.width - answerColumnWidth - Self.columnGap / 2)
      .rounded()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    answerOverlay().frame = bounds
    answerOverlay().needsDisplay = true
    let available = newSize.width - textContainerInset.width * 2
    let sourceWidth =
      writesAnswersInline ? available : available - answerColumnWidth - Self.columnGap
    textContainer?.size = NSSize(
      width: max(sourceWidth, Self.answerColumnWidthRange.lowerBound),
      height: CGFloat.greatestFiniteMagnitude
    )
  }

  override func didChangeText() {
    super.didChangeText()
    // Edits move lines, so answers must be redrawn in their new positions.
    answerOverlay().needsDisplay = true
    updateCompletions()
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

  /// The answers to draw for lines whose layout fragment intersects `rect`:
  /// right-aligned in the answer column on the line's first row, or, written
  /// inline, just past where the line's last row of text ends.
  func answerLayout(in rect: NSRect) -> [(line: LineID, cell: AnswerCell, rect: NSRect)] {
    let rightEdge = bounds.maxX - textContainerInset.width
    let columnWidth = answerColumnWidth
    return visibleLines(in: rect).compactMap { line in
      guard let cell = answer(line.id) else {
        return nil
      }
      let wanted = ceil(
        (cell.text as NSString).size(withAttributes: attributes(for: cell, selected: false)).width
      )
      let row = writesAnswersInline ? line.lastRow : line.firstRow
      let x =
        writesAnswersInline
        ? line.frame.minX + row.typographicBounds.maxX + Self.columnGap
        : rightEdge - min(wanted, columnWidth)
      return (
        line.id,
        cell,
        NSRect(
          x: x,
          y: line.frame.minY + row.typographicBounds.minY,
          width: min(wanted, max(rightEdge - x, 0)),
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
      completionList.hide()
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

  private var answerCommands: [(String, Selector)] {
    [
      (
        String(localized: "menu.copyResult", defaultValue: "Copy Result", bundle: .main),
        #selector(copyResult(_:))
      ),
      (
        String(localized: "menu.copyWithResults", defaultValue: "Copy with Results", bundle: .main),
        #selector(copyLinesWithResults(_:))
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
        String(localized: "menu.askAssistant", defaultValue: "Ask Assistant", bundle: .main),
        #selector(askAssistant(_:))
      ),
      (
        String(localized: "menu.changeAnswer", defaultValue: "Change Answer…", bundle: .main),
        #selector(changeAssistantAnswer(_:))
      ),
      (
        String(localized: "menu.insertReference", defaultValue: "Insert Reference", bundle: .main),
        #selector(insertReference(_:))
      ),
    ]
  }

  /// Keyboard and VoiceOver equivalents of answer mouse interactions.
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    return answerCommands.map { name, action in
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

  // MARK: Hover and contextual help

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let helpTracking {
      removeTrackingArea(helpTracking)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    helpTracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateHelpTooltip(at: convert(event.locationInWindow, from: nil))
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    if let hit = answerHit(at: point) {
      selectedAnswer = hit.line
    }
    let offset = characterIndexForInsertion(at: point)
    if !NSLocationInRange(offset, selectedRange()) {
      setSelectedRange(NSRange(location: offset, length: 0))
    }
    let menu = NSMenu()
    if let help = lookupHelp(at: point) {
      let item = NSMenuItem(
        title: help.menuTitle, action: #selector(openLanguageHelp(_:)), keyEquivalent: "")
      item.representedObject = help
      menu.addItem(item)
      menu.addItem(.separator())
    }
    for (title, action) in answerCommands {
      menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    for (title, action) in [
      (String(localized: "menu.cut", defaultValue: "Cut", bundle: .main), #selector(cut(_:))),
      (String(localized: "menu.copy", defaultValue: "Copy", bundle: .main), #selector(copy(_:))),
      (String(localized: "menu.paste", defaultValue: "Paste", bundle: .main), #selector(paste(_:))),
      (
        String(localized: "menu.selectAll", defaultValue: "Select All", bundle: .main),
        #selector(selectAll(_:))
      ),
    ] {
      menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
    }
    return menu
  }

  @objc func openLanguageHelp(_ sender: Any?) {
    guard let help = (sender as? NSMenuItem)?.representedObject as? SourceHelp else {
      return
    }
    if let topicID = help.topicID {
      openHelp?(topicID)
    } else {
      showInterpretation(nil)
    }
  }

  func lookupHelp(atUTF16 offset: Int) -> SourceHelp? {
    guard let info = line(offset),
      let start = lineStarts().first(where: { $0.id == info.id })
    else {
      return nil
    }
    let text = (string as NSString).substring(
      with: NSRange(location: start.start, length: start.length))
    return SourceHelpLookup.at(
      utf16Offset: offset - start.start,
      in: text,
      diagnostic: lineDiagnostic(info.id),
      configuration: lexingConfiguration
    )
  }

  func lookupHelp(at point: NSPoint) -> SourceHelp? {
    if let hit = answerHit(at: point), hit.cell.isFailure {
      return SourceHelp(
        tooltip: hit.cell.text,
        topicID: nil,
        menuTitle: String(
          localized: "help.menu.problem", defaultValue: "Show Interpretation", bundle: .main)
      )
    }
    return lookupHelp(atUTF16: characterIndexForInsertion(at: point))
  }

  /// The full answer or error beside the pointer, even when the column cuts it
  /// off. Source help is what hovering a function or keyword in the line uses.
  func tooltip(at point: NSPoint) -> String? {
    if let hit = answerHit(at: point) {
      return hit.cell.text
    }
    return lookupHelp(at: point)?.tooltip
  }

  private func updateHelpTooltip(at point: NSPoint) {
    removeAllToolTips()
    guard let text = tooltip(at: point) else {
      helpTooltip = ""
      return
    }
    helpTooltip = text
    addToolTip(tooltipRect(at: point), owner: self, userData: nil)
  }

  /// The answer's own frame when the pointer is on one, so a cut-off result
  /// still has a tooltip where it is drawn rather than on the source.
  private func tooltipRect(at point: NSPoint) -> NSRect {
    if let hit = answerHit(at: point) {
      return hit.rect.insetBy(dx: -4, dy: 0)
    }
    let offset = characterIndexForInsertion(at: point)
    let rect = firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
    if let window, rect.width > 0 {
      return convert(window.convertFromScreen(rect), from: nil)
    }
    return NSRect(x: point.x, y: point.y - 8, width: 12, height: 16)
  }

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    helpTooltip
  }

  // MARK: Answer selection and commands

  /// The answer under `point`, with a little extra width so a short result is
  /// still easy to hit.
  func answerHit(at point: NSPoint) -> (line: LineID, cell: AnswerCell, rect: NSRect)? {
    answerLayout(in: NSRect(x: point.x, y: point.y, width: 1, height: 1))
      .first { $0.rect.insetBy(dx: -4, dy: 0).contains(point) }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let hit = answerHit(at: point) else {
      selectedAnswer = nil
      if event.modifierFlags.contains(.option), beginScrub(at: point) {
        return
      }
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

  // MARK: Scrubbing a number

  /// How far a pointer travels for one step. Digits move at a pace a person
  /// can follow and stop on, rather than flickering past.
  static let pointsPerScrubStep: CGFloat = 4

  private struct Scrub {
    let number: ScrubbableNumber
    /// The line's start in the sheet, in UTF-16 code units.
    let lineStart: Int
    /// Where the drag began, so every step counts from the number as written
    /// rather than compounding a rounding of it.
    let anchor: CGFloat
    var written: String
  }

  private var scrub: Scrub?
  private var showsScrubCursor = false

  override func mouseDragged(with event: NSEvent) {
    guard scrub != nil else {
      super.mouseDragged(with: event)
      return
    }
    step(to: convert(event.locationInWindow, from: nil), event.modifierFlags)
  }

  override func mouseUp(with event: NSEvent) {
    guard scrub != nil else {
      super.mouseUp(with: event)
      return
    }
    scrub = nil
    undoManager?.endUndoGrouping()
  }

  /// The pointer shows the drag while Option is held over a number, so the
  /// gesture can be found without being described.
  override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    guard scrub == nil, let window else {
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let scrubbable =
      event.modifierFlags.contains(.option) && bounds.contains(point)
      && number(at: characterIndexForInsertion(at: point)) != nil
    if scrubbable {
      NSCursor.resizeLeftRight.set()
      showsScrubCursor = true
    } else if showsScrubCursor {
      NSCursor.iBeam.set()
      showsScrubCursor = false
    }
  }

  @objc func stepNumberUp(_ sender: Any?) {
    stepNumberAtInsertionPoint(by: 1)
  }

  @objc func stepNumberDown(_ sender: Any?) {
    stepNumberAtInsertionPoint(by: -1)
  }

  private func beginScrub(at point: NSPoint) -> Bool {
    let offset = characterIndexForInsertion(at: point)
    guard isEditable, let found = number(at: offset) else {
      return false
    }
    scrub = Scrub(
      number: found.number,
      lineStart: found.lineStart,
      anchor: point.x,
      written: found.number.text
    )
    undoManager?.beginUndoGrouping()
    undoManager?.setActionName(localized("scrub.undo", "Change Number"))
    NSCursor.resizeLeftRight.set()
    showsScrubCursor = true
    return true
  }

  private func step(to point: NSPoint, _ modifiers: NSEvent.ModifierFlags) {
    guard var state = scrub else {
      return
    }
    // Shift steps ten of the number's last place at a time and Command a tenth
    // of it, as they coarsen and refine elsewhere.
    let scale =
      state.number.scale + (modifiers.contains(.command) ? 1 : 0)
      - (modifiers.contains(.shift) ? 1 : 0)
    let steps = Int((point.x - state.anchor) / Self.pointsPerScrubStep)
    guard
      let stepped = state.number.stepped(
        by: steps,
        scale: scale,
        configuration: lexingConfiguration
      ), stepped != state.written
    else {
      return
    }
    let range = NSRange(
      location: state.lineStart + state.number.range.location,
      length: state.written.utf16.count
    )
    guard write(stepped, in: range) else {
      return
    }
    state.written = stepped
    scrub = state
  }

  private func stepNumberAtInsertionPoint(by steps: Int) {
    guard isEditable, let found = number(at: selectedRange().location),
      let stepped = found.number.stepped(
        by: steps,
        scale: found.number.scale,
        configuration: lexingConfiguration
      )
    else {
      NSSound.beep()
      return
    }
    let start = found.lineStart + found.number.range.location
    let range = NSRange(location: start, length: found.number.range.length)
    guard write(stepped, in: range) else {
      return
    }
    // The insertion point stays in the number, so stepping again steps it.
    setSelectedRange(NSRange(location: start + stepped.utf16.count, length: 0))
  }

  private func write(_ text: String, in range: NSRange) -> Bool {
    guard shouldChangeText(in: range, replacementString: text) else {
      return false
    }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    return true
  }

  /// The number written at an offset in the sheet, with the start of the line
  /// holding it.
  private func number(at offset: Int) -> (number: ScrubbableNumber, lineStart: Int)? {
    let text = string as NSString
    guard offset <= text.length else {
      return nil
    }
    let line = text.paragraphRange(for: NSRange(location: offset, length: 0))
    guard
      let number = ScrubbableNumber(
        in: text.substring(with: line),
        at: offset - line.location,
        configuration: lexingConfiguration
      )
    else {
      return nil
    }
    return (number, line.location)
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

  /// Escape dismisses the completion list when it is showing, and otherwise
  /// cancels up the responder chain, such as dismissing Quick Ganit.
  override func complete(_ sender: Any?) {
    if completionList.isVisible {
      completionList.hide()
      return
    }
    nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
  }

  override func insertNewline(_ sender: Any?) {
    if insertSelectedCompletion() {
      return
    }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    if insertSelectedCompletion() {
      return
    }
    if selectNextCompletionArgument() {
      return
    }
    super.insertTab(sender)
  }

  override func moveUp(_ sender: Any?) {
    if completionList.move(-1) {
      return
    }
    super.moveUp(sender)
  }

  override func moveDown(_ sender: Any?) {
    if completionList.move(1) {
      return
    }
    super.moveDown(sender)
  }

  /// Completions currently offered, for tests.
  var offeredCompletions: [String] {
    completionList.titles
  }

  private func updateCompletions() {
    configureCompletions()
    guard completesWhileTyping ?? GanitPreferences.completesWhileTyping,
      let prefix = completionPrefix()
    else {
      completionList.hide()
      return
    }
    let matches = LanguageCompletions.matching(prefix.text).filter { $0 != prefix.text }
    guard !matches.isEmpty, let window else {
      completionList.hide()
      return
    }
    var rect = firstRect(forCharacterRange: prefix.range, actualRange: nil)
    rect = convert(window.convertFromScreen(rect), from: nil)
    if rect.width <= 0 {
      rect = NSRect(x: 0, y: 0, width: 12, height: 16)
    }
    completionList.show(matches, at: rect, in: self)
  }

  private func completionPrefix() -> (range: NSRange, text: String)? {
    let cursor = selectedRange()
    guard cursor.length == 0 else {
      return nil
    }
    let text = string as NSString
    var start = cursor.location
    let characters = CharacterSet.letters.union(.decimalDigits).union(
      CharacterSet(charactersIn: "_π"))
    while start > 0 {
      let previous = start - 1
      let unit = text.substring(with: text.rangeOfComposedCharacterSequence(at: previous))
      guard unit.unicodeScalars.allSatisfy({ characters.contains($0) }) else {
        break
      }
      start = previous
    }
    let length = cursor.location - start
    guard length > 0 else {
      return nil
    }
    let range = NSRange(location: start, length: length)
    return (range, text.substring(with: range))
  }

  private var completionArguments: [NSRange] = []
  private var completionArgument = 0

  @discardableResult
  private func insertSelectedCompletion() -> Bool {
    guard let item = completionList.selectedItem, let prefix = completionPrefix() else {
      return false
    }
    completionList.hide()
    let arguments = LanguageCompletions.argumentRanges(in: item, at: prefix.range.location)
    guard write(item, in: prefix.range) else {
      return false
    }
    completionArguments = arguments
    completionArgument = 0
    if let first = arguments.first {
      setSelectedRange(first)
    } else {
      setSelectedRange(NSRange(location: prefix.range.location + item.utf16.count, length: 0))
    }
    return true
  }

  /// Tab moves from one completed argument to the next, as a spreadsheet does.
  @discardableResult
  func selectNextCompletionArgument() -> Bool {
    guard completionArgument + 1 < completionArguments.count else {
      completionArguments = []
      return false
    }
    completionArgument += 1
    setSelectedRange(completionArguments[completionArgument])
    return true
  }

  override func copy(_ sender: Any?) {
    guard selectedAnswer != nil else {
      super.copy(sender)
      return
    }
    copyResult(sender)
  }

  /// Copies the displayed answer of the selected answer or the insertion
  /// point's line, including a failure's message.
  @objc func copyResult(_ sender: Any?) {
    guard let cell = targetAnswer?.cell, !cell.isPending else {
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

  @objc func askAssistant(_ sender: Any?) {
    onAskAssistant()
  }

  @objc func changeAssistantAnswer(_ sender: Any?) {
    onChangeAssistantAnswer()
  }

  /// Copies each selected line, or the insertion point's line, with the
  /// answer that line shows.
  @objc func copyLinesWithResults(_ sender: Any?) {
    copyToPasteboard(linesWithResults(in: selectedRange()))
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copyResult(_:)):
      return targetAnswer.map { !$0.cell.isPending } ?? false
    case #selector(showInterpretation(_:)):
      return targetAnswer != nil
    case #selector(askAssistant(_:)):
      return canAskAssistant()
    case #selector(changeAssistantAnswer(_:)):
      return canChangeAssistantAnswer()
    case #selector(copyLinesWithResults(_:)):
      return (string as NSString).length > 0
    case #selector(openLanguageHelp(_:)):
      return true
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
    case #selector(stepNumberUp(_:)), #selector(stepNumberDown(_:)):
      return isEditable && number(at: selectedRange().location) != nil
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
      if let id = lineID(previous.location), let cell = answer(id),
        !cell.isFailure, !cell.isPending
      {
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
      targetAnswer.flatMap { $0.cell.isFailure || $0.cell.isPending ? nil : $0.line }
      ?? nearestResult(before: (string as NSString).length)
    guard let cell = id.flatMap(answer), !cell.isFailure, !cell.isPending else {
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

  /// Each selected line, or the insertion point's line, with the answer it
  /// shows. Pending Asking… text is omitted.
  func linesWithResults(in range: NSRange) -> String {
    let string = self.string as NSString
    let range = range.length == 0 ? string.lineRange(for: range) : expandedToLines(range)
    var pieces: [String] = []
    var location = range.location
    while location < range.upperBound {
      let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
      var contentsEnd = 0
      string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
      let source = string.substring(
        with: NSRange(location: lineRange.location, length: contentsEnd - lineRange.location))
      let cell = line(lineRange.location).flatMap { answer($0.id) }
      if let cell, !cell.isPending {
        pieces.append("\(source)\t\(cell.text)")
      } else {
        pieces.append(source)
      }
      let next = lineRange.upperBound
      if next <= location {
        break
      }
      location = next
    }
    return pieces.joined(separator: "\n")
  }

  private func expandedToLines(_ range: NSRange) -> NSRange {
    let string = self.string as NSString
    let start = string.lineRange(for: NSRange(location: range.location, length: 0)).location
    let last = max(range.upperBound - 1, range.location)
    let end = string.lineRange(for: NSRange(location: last, length: 0)).upperBound
    return NSRange(location: start, length: end - start)
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

  /// A laid-out line: where it starts, where its fragment sits in the view,
  /// and the rows an answer can be aligned with.
  private struct VisibleLine {
    let id: LineID
    let location: NSTextLocation
    let frame: NSRect
    let firstRow: NSTextLineFragment
    let lastRow: NSTextLineFragment
  }

  /// Lines whose layout fragment intersects `rect`, in order.
  private func visibleLines(in rect: NSRect) -> [VisibleLine] {
    guard let layoutManager = textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let start = layoutManager.textLayoutFragment(
        for: CGPoint(x: 0, y: max(rect.minY - textContainerOrigin.y, 0))
      )?.rangeInElement.location
    else {
      return []
    }
    var lines: [VisibleLine] = []
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
      if let id = lineID(offset), let first = fragment.textLineFragments.first,
        let last = fragment.textLineFragments.last
      {
        lines.append(
          VisibleLine(id: id, location: location, frame: frame, firstRow: first, lastRow: last))
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
    if let x = textView.answerSeparatorX {
      VisualStyle.Color.separator.setFill()
      NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
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
