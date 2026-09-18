import AppKit
import GanitDiagnostics
import GanitEngine
import GanitFormatting

/// Hosts the sheet's source in a standard `NSTextView`.
///
/// The text view owns editing: selection, marked text and IME composition,
/// bidirectional layout, the responder chain, Find, and undo. The controller
/// mirrors committed text-storage edits into a `SheetSource` so stable line
/// identities follow the text, schedules evaluation once IME composition has
/// committed, shows formatted answers beside the source, and decorates exact
/// source ranges with rendering attributes.
@MainActor
public final class SheetEditorViewController: NSViewController {
  public var textView: NSTextView {
    sheetTextView
  }
  public private(set) var sheet: SheetSource
  /// The newest evaluation shown, which may trail the source while a
  /// generation is running.
  public private(set) var latestEvaluation: SheetEvaluation?
  /// Undo belongs to the document, not the window, so each sheet has its own
  /// history.
  public let documentUndoManager = UndoManager()
  /// Receives the time from an edit until its answers were drawn, for each
  /// generation that reaches the screen.
  public var editToAnswerHandler: ((Duration) -> Void)?
  /// Where result commands copy.
  public var resultPasteboard: NSPasteboard {
    get { sheetTextView.pasteboard }
    set { sheetTextView.pasteboard = newValue }
  }

  /// Copies the insertion point's result, or else the sheet's last result,
  /// and returns whether one was copied.
  public func copyCurrentOrLastResult() -> Bool {
    sheetTextView.copyCurrentOrLastResult()
  }

  /// Called after each committed source edit, for saving.
  public var sourceDidChange: (() -> Void)?
  /// Called when the variables and units this sheet defines change, so the
  /// definitions sheet can share them with every other sheet.
  public var definitionsDidChange: ((SheetDefinitions) -> Void)?
  /// Asks something outside Ganit about a line Ganit could not work out, when
  /// the reader has set an assistant up. A line is asked about once, only
  /// after typing on it stops, and its answer arrives later.
  public var askAssistant: ((String) async -> String?)? {
    didSet {
      askAboutUnansweredLines()
    }
  }
  /// Opens Help on a topic the pointer is over, such as a function name.
  public var openHelp: ((String) -> Void)? {
    didSet {
      sheetTextView.openHelp = openHelp
    }
  }

  private var context: EvaluationContext
  private let scrollView = NSScrollView()
  let summaryBar = SelectionSummaryBar()
  private let sheetTextView = SheetTextView(usingTextLayoutManager: true)
  private let storageObserver = StorageObserver()
  private(set) var scheduler: SheetEvaluationScheduler?
  private var resultFormatter: ResultFormatter
  private let diagnosticFormatter: DiagnosticFormatter
  /// Answer cells by line, reused while the line's result, editing state,
  /// assistant answer, and pending request are unchanged.
  private var cells:
    [LineID: (
      result: CalculationResult, isEditing: Bool, assisted: String?, pending: Bool,
      cell: AnswerCell?
    )] = [:]
  /// What the assistant said about a line, by the text that was asked, so an
  /// answer outlives the evaluations and line identities of the text it
  /// belongs to.
  private var assistantAnswers: [String: String] = [:]
  /// Lines already sent, including ones that came back empty, so a failed
  /// request is not retried on every keystroke.
  private var assistantAsked: Set<String> = []
  /// Line texts whose request has not come back yet, shown as Asking….
  private var assistantLineInFlight: Set<String> = []
  /// Parsed values for `ask_assistant` prompts, reused across evaluations.
  private var assistantValues: [String: AssistantAnswer] = [:]
  private var assistantPromptsInFlight: Set<String> = []
  /// Each line's UTF-16 start offset, in line order.
  private var cachedUTF16Starts: [Int]?
  /// The text and result of each line in the newest shown evaluation.
  private var shownLines: [LineID: (text: String, result: SheetLineResult)] = [:]
  private var decorations: [LineID: LineDecoration] = [:]
  /// Lines edited since they were decorated; edits can drop attributes.
  private var editedLines: Set<LineID> = []
  /// The line holding the insertion point, whose incomplete input is not
  /// flagged yet.
  private var editingLine: LineID?
  /// The edit-to-answer interval of a shown generation awaiting its draw.
  private var pendingAnswerDraw: SignpostedInterval?
  /// The text as of the last mirrored edit, for converting UTF-16 edit
  /// ranges into the sheet's UTF-8 offsets.
  private var mirroredText: String
  /// What this sheet last defined, for reporting only real changes.
  private var shownDefinitions = SheetDefinitions.none
  /// How this sheet writes its answers.
  public private(set) var displayOptions: DisplayOptions

  public init(
    text: String = "",
    context: EvaluationContext,
    display: DisplayOptions = .standard
  ) {
    self.context = context.with(
      dollarCurrency: display.dollarCurrency, isMarkdownMode: display.writesAnswersInline)
    displayOptions = display
    resultFormatter = ResultFormatter(context: context, display: display)
    diagnosticFormatter = DiagnosticFormatter(context: context)
    sheet = SheetSource(text)
    mirroredText = text
    super.init(nibName: nil, bundle: nil)

    configureTextView(text: text)
    placeAnswers(display)
    sheetTextView.lexingConfiguration = context.lexingConfiguration
    storageObserver.controller = self
    textView.textStorage?.delegate = storageObserver
    textView.delegate = storageObserver
    sheetTextView.lineID = { [weak self] offset in
      guard let self else {
        return nil
      }
      let index = lineIndex(atUTF16: offset)
      return utf16Starts()[index] == offset ? sheet.lines[index].id : nil
    }
    sheetTextView.lineStarts = { [weak self] in
      guard let self else {
        return []
      }
      return zip(sheet.lines, utf16Starts()).map { ($0.id, $1, $0.text.utf16.count) }
    }
    sheetTextView.line = { [weak self] offset in
      guard let self else {
        return nil
      }
      let index = lineIndex(atUTF16: offset)
      return (index + 1, sheet.lines[index].id)
    }
    sheetTextView.lineNumber = { [weak self] id in
      self?.sheet.lines.firstIndex { $0.id == id }.map { $0 + 1 }
    }
    editingLine = sheet.lines.first?.id
    sheetTextView.answer = { [weak self] id in
      self?.answerCell(for: id)
    }
    sheetTextView.interpretation = { [weak self] id in
      self?.interpretation(for: id) ?? []
    }
    sheetTextView.lineDiagnostic = { [weak self] id in
      guard let self, let shown = shownLines[id], let result = shown.result.result else {
        return nil
      }
      return flaggedDiagnostic(result, isEditing: id == editingLine)
    }
    sheetTextView.canAskAssistant = { [weak self] in
      self?.canAskAssistant() ?? false
    }
    sheetTextView.onAskAssistant = { [weak self] in
      self?.refetchAssistant()
    }
    sheetTextView.canChangeAssistantAnswer = { [weak self] in
      self?.canChangeAssistantAnswer() ?? false
    }
    sheetTextView.onChangeAssistantAnswer = { [weak self] in
      self?.changeAssistantAnswer()
    }
    sheetTextView.didDrawAnswers = { [weak self] in
      guard let self, let interval = pendingAnswerDraw else {
        return
      }
      pendingAnswerDraw = nil
      editToAnswerHandler?(interval.end())
    }
    scheduler = SheetEvaluationScheduler(context: context) {
      [weak self] snapshot, evaluation, editToAnswer in
      guard let self else {
        return editToAnswer.cancel()
      }
      pendingAnswerDraw?.cancel()
      pendingAnswerDraw = editToAnswer
      show(evaluation, of: snapshot)
    }
    scheduler?.schedule(sheet)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    let container = NSView(frame: scrollView.frame)
    container.addSubview(scrollView)
    container.addSubview(summaryBar)
    view = container
  }

  public override func viewDidLayout() {
    super.viewDidLayout()
    let height = summaryBar.fittingHeight
    summaryBar.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: height)
    scrollView.frame = NSRect(
      x: 0, y: height, width: view.bounds.width, height: view.bounds.height - height)
  }

  public override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(textView)
  }

  private func configureTextView(text: String) {
    // An initial size lets autoresizing track the window from the start.
    scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    scrollView.documentView = textView
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = false
    textView.string = text
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.font = VisualStyle.Typography.source(scale: 1)
    textView.baseWritingDirection = .natural
    textView.textContainerInset = NSSize(
      width: VisualStyle.Spacing.standard, height: VisualStyle.Spacing.standard)
    // Substitutions would silently change calculation source, such as `--`
    // into an em dash or quotes into typographic quotes.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.usesFontPanel = false
    textView.usesRuler = false
    textView.enabledTextCheckingTypes = 0
    textView.setAccessibilityLabel(
      String(localized: "editor.accessibilityLabel", defaultValue: "Sheet", bundle: .main)
    )
  }

  fileprivate func mirrorEdit(newRange: NSRange, changeInLength delta: Int) {
    let current = textView.string
    let old = mirroredText.utf16
    let lower = old.index(old.startIndex, offsetBy: newRange.location)
    let upper = old.index(lower, offsetBy: newRange.length - delta)
    let new = current.utf16
    let replacementLower = new.index(new.startIndex, offsetBy: newRange.location)
    let replacementUpper = new.index(replacementLower, offsetBy: newRange.length)

    let utf8 = mirroredText.utf8
    let utf8Lower = utf8.distance(from: utf8.startIndex, to: lower)
    sheet.replace(
      utf8Range: utf8Lower..<(utf8Lower + utf8.distance(from: lower, to: upper)),
      with: String(current[replacementLower..<replacementUpper])
    )
    mirroredText = current
    cachedUTF16Starts = nil
    for index in lineIndex(atUTF16: newRange.location)...lineIndex(atUTF16: newRange.upperBound) {
      let id = sheet.lines[index].id
      editedLines.insert(id)
      // Underline ranges no longer match the edited text.
      sheetTextView.underlines[id] = nil
    }
    sourceDidChange?()
    // Undo and other programmatic edits do not send `textDidChange`.
    textDidChange()
  }

  /// Lines an edit is adding or removing, until `renumberLineReferences`
  /// applies them. Undo and redo restore text as it was, so they note none.
  private var pendingLineShift: (firstMovedLine: Int, delta: Int, editedLines: ClosedRange<Int>)?

  fileprivate func noteLineShift(replacing range: NSRange, with replacement: String?) {
    guard let replacement, !documentUndoManager.isUndoing, !documentUndoManager.isRedoing,
      let shift = LineReferenceRenumbering.shift(
        replacing: range, in: textView.string, with: replacement)
    else {
      return
    }
    // End typing coalescence before opening the transaction: AppKit otherwise
    // separates a reference rewrite from the newline that triggered it.
    textView.breakUndoCoalescing()
    documentUndoManager.beginUndoGrouping()
    let first = lineIndex(atUTF16: range.location)
    let inserted = replacement.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
    pendingLineShift = (shift.firstMovedLine, shift.delta, first...(first + inserted))
  }

  /// Keeps each `line N` below an edit naming the line it named before.
  fileprivate func renumberLineReferences() {
    guard let shift = pendingLineShift else {
      return
    }
    pendingLineShift = nil
    defer {
      textView.breakUndoCoalescing()
      documentUndoManager.endUndoGrouping()
    }
    let edits = LineReferenceRenumbering.edits(
      in: textView.string, firstMovedLine: shift.firstMovedLine, delta: shift.delta,
      editedLines: shift.editedLines, configuration: context.lexingConfiguration)
    for edit in edits.reversed()
    where textView.shouldChangeText(in: edit.range, replacementString: edit.number) {
      textView.textStorage?.replaceCharacters(in: edit.range, with: edit.number)
      textView.didChangeText()
    }
  }

  /// Schedules evaluation unless marked text is still being composed. A
  /// composition commit may clear its marked text only after the storage
  /// edit, so this also runs for `textDidChange`; a repeated schedule simply
  /// supersedes the previous one.
  fileprivate func textDidChange() {
    guard !textView.hasMarkedText() else {
      return
    }
    scheduler?.schedule(sheet)
  }

  /// Evaluates the sheet with new exchange rates.
  /// Reads bare angles in degrees or radians, and answers again.
  public func setAngleMode(_ mode: AngleMode) {
    guard context.angleMode != mode else {
      return
    }
    context = context.with(angleMode: mode)
    scheduler?.context = context
    scheduler?.schedule(sheet)
  }

  public func setCurrencyRates(_ rates: CurrencyRates) {
    context = context.with(rates)
    scheduler?.context = context
    scheduler?.schedule(sheet)
  }

  /// Evaluates the sheet with the definitions sheet's variables and units.
  public func setDefinitions(_ definitions: SheetDefinitions) {
    guard definitions != scheduler?.definitions else {
      return
    }
    scheduler?.setDefinitions(definitions, of: sheet)
  }

  /// Evaluates the current source again.
  @objc public func recalculate(_ sender: Any?) {
    scheduler?.schedule(sheet)
  }

  /// Stops the running evaluation; answers stay at the last completed one.
  @objc public func stopCalculation(_ sender: Any?) {
    scheduler?.cancel()
  }

  fileprivate func selectionDidChange() {
    summarizeSelection()
    let line = sheet.lines[lineIndex(atUTF16: textView.selectedRange().location)].id
    guard line != editingLine else {
      return
    }
    let previous = editingLine
    editingLine = line
    for index in sheet.lines.indices where [previous, line].contains(sheet.lines[index].id) {
      decorate(index)
    }
    sheetTextView.answersDidChange()
    // Leaving a line is what makes it worth asking about.
    askAboutUnansweredLines()
  }

  /// Counts all selected calculations and aggregates only complete selections.
  /// Incompatible values, such as money and metres, also leave counts alone.
  private func summarizeSelection() {
    let selection = textView.selectedRange()
    // An insertion point covers one line at most, which keeps moving it and
    // typing off this path entirely.
    guard selection.length > 0 else {
      summaryBar.summary = nil
      view.needsLayout = true
      return
    }
    var values: [EngineValue] = []
    var failedCount = 0
    var pendingCount = 0
    for (line, start) in zip(sheet.lines, utf16Starts()) {
      guard start < selection.upperBound, start + line.text.utf16.count > selection.location else {
        continue
      }
      let shown = shownLines[line.id]
      let isCurrent = shown?.text == line.text
      let syntax = isCurrent ? shown?.result.syntax : LineSyntax(line.text)
      guard case .calculation(_, _, .some, _) = syntax else { continue }
      guard isCurrent, let result = shown?.result.result else {
        pendingCount += 1
        continue
      }
      switch result {
      case .value(let value): values.append(value)
      case .syntaxFailure, .evaluationFailure:
        if isAssistantPending(text: line.text, result: result) {
          pendingCount += 1
        } else {
          failedCount += 1
        }
      }
    }
    let count = values.count + failedCount + pendingCount
    guard count > 1 else {
      summaryBar.summary = nil
      view.needsLayout = true
      return
    }
    let evaluator = Evaluator(context: context)
    func formatted(_ aggregate: Aggregate) -> String? {
      guard failedCount == 0, pendingCount == 0,
        let value = try? evaluator.aggregating(aggregate, of: values)
      else {
        return nil
      }
      return (try? resultFormatter.format(value))?.display
    }
    summaryBar.summary = SelectionSummary(
      count: count, calculatedCount: values.count, failedCount: failedCount,
      pendingCount: pendingCount,
      total: formatted(.sum),
      average: formatted(.average)
    )
    view.needsLayout = true
  }

  private func show(_ evaluation: SheetEvaluation, of snapshot: SheetSource) {
    latestEvaluation = evaluation
    if evaluation.definitions != shownDefinitions {
      shownDefinitions = evaluation.definitions
      definitionsDidChange?(evaluation.definitions)
    }
    let previous = shownLines
    shownLines = Dictionary(
      uniqueKeysWithValues: zip(snapshot.lines, evaluation.lines).map {
        ($1.id, ($0.text, $1))
      }
    )
    cells = cells.filter { shownLines[$0.key] != nil }
    decorations = decorations.filter { shownLines[$0.key] != nil }
    sheetTextView.underlines = sheetTextView.underlines.filter { shownLines[$0.key] != nil }

    // A decoration depends on text, role, failure diagnostics, and editing,
    // so lines whose values alone changed keep theirs.
    for index in sheet.lines.indices {
      let id = sheet.lines[index].id
      guard let shown = shownLines[id] else {
        continue
      }
      if let old = previous[id], !editedLines.contains(id), old.text == shown.text,
        old.result.syntax == shown.result.syntax,
        !(old.result.result?.isFailure ?? false) && !(shown.result.result?.isFailure ?? false)
          || old.result.result == shown.result.result
      {
        continue
      }
      decorate(index)
    }
    sheetTextView.answersDidChange()
    summarizeSelection()
    askAboutUnansweredLines()
  }

  /// How long a line must sit still before it is worth asking about, so that
  /// typing a line does not ask about each of its halves.
  var assistantPause = Duration.milliseconds(1_200)
  private var assistantPauseTask: Task<Void, Never>?

  /// Waits for typing to stop, then asks the assistant about each line Ganit
  /// flagged as one it could not work out. Every answer redraws its column.
  private func askAboutUnansweredLines() {
    guard askAssistant != nil else {
      return
    }
    assistantPauseTask?.cancel()
    assistantPauseTask = Task { [weak self, assistantPause] in
      try? await Task.sleep(for: assistantPause)
      guard !Task.isCancelled else {
        return
      }
      self?.askNow()
    }
  }

  private func askNow() {
    guard askAssistant != nil else {
      return
    }
    askAboutPrompts()
    for (id, shown) in shownLines {
      guard let asked = lineLevelAssistantPrompt(for: shown, id: id),
        !assistantAsked.contains(asked), !assistantLineInFlight.contains(asked)
      else {
        continue
      }
      startLineAssistantRequest(asked)
    }
  }

  /// Sends `asked` to the assistant and writes the reply beside the line.
  /// Asking… appears immediately; typing is not blocked.
  private func startLineAssistantRequest(_ asked: String) {
    guard let askAssistant else {
      return
    }
    assistantLineInFlight.insert(asked)
    sheetTextView.answersDidChange()
    summarizeSelection()
    Task { [weak self] in
      let answer = await askAssistant(asked)
      guard let self else {
        return
      }
      assistantLineInFlight.remove(asked)
      assistantAsked.insert(asked)
      if let answer {
        assistantAnswers[asked] = answer
      }
      sheetTextView.answersDidChange()
      summarizeSelection()
    }
  }

  /// Asks about each `ask_assistant` prompt that still has no value, then
  /// evaluates again so later lines can use the answer.
  private func askAboutPrompts() {
    guard let evaluation = latestEvaluation else {
      return
    }
    for line in evaluation.lines {
      guard case .evaluationFailure(let error) = line.result,
        error.code == .unresolvedAssistantPrompt,
        case .assistantPrompt(let prompt) = error.context
      else {
        continue
      }
      requestAssistantPrompt(prompt)
    }
  }

  private func requestAssistantPrompt(_ prompt: String) {
    guard let askAssistant, !prompt.isEmpty, assistantValues[prompt] == nil,
      !assistantPromptsInFlight.contains(prompt)
    else {
      return
    }
    assistantPromptsInFlight.insert(prompt)
    sheetTextView.answersDidChange()
    summarizeSelection()
    Task { [weak self] in
      let answer = await askAssistant(prompt)
      self?.finishAssistantPrompt(prompt, answer: answer)
    }
  }

  private func finishAssistantPrompt(_ prompt: String, answer: String?) {
    assistantPromptsInFlight.remove(prompt)
    if let answer, case .value(let value) = CalculationEngine().evaluate(answer, context: context) {
      assistantValues[prompt] = .value(value)
    } else {
      assistantValues[prompt] = .unusable
    }
    context = context.with(assistantAnswers: assistantValues)
    scheduler?.context = context
    scheduler?.schedule(sheet)
  }

  /// Whether Ask Assistant can send the selected answer's line, or the
  /// insertion point's, including a line already asked about.
  func canAskAssistant() -> Bool {
    askAssistant != nil && assistantTarget() != nil
  }

  /// Whether the selected answer, or the insertion point's line, already has
  /// an assistant value that can be replaced.
  func canChangeAssistantAnswer() -> Bool {
    switch assistantTarget() {
    case .line(_, let asked):
      return assistantAnswers[asked] != nil
    case .prompts(let prompts):
      return prompts.contains { assistantValues[$0] != nil }
    case nil:
      return false
    }
  }

  /// Asks again about the selected answer's line, or the insertion point's,
  /// even when that text already has an answer.
  func refetchAssistant() {
    guard askAssistant != nil, let target = assistantTarget() else {
      NSSound.beep()
      return
    }
    switch target {
    case .prompts(let prompts):
      for prompt in prompts {
        assistantValues.removeValue(forKey: prompt)
      }
      context = context.with(assistantAnswers: assistantValues)
      scheduler?.context = context
      scheduler?.schedule(sheet)
      for prompt in prompts {
        requestAssistantPrompt(prompt)
      }
    case .line(let id, let asked):
      assistantAnswers.removeValue(forKey: asked)
      assistantAsked.remove(asked)
      assistantLineInFlight.remove(asked)
      cells[id] = nil
      sheetTextView.answersDidChange()
      startLineAssistantRequest(asked)
    }
  }

  /// Offers a field to replace the current assistant value.
  func changeAssistantAnswer() {
    guard canChangeAssistantAnswer(), let window = view.window else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.messageText = localized("assistant.change", "Change Answer")
    alert.informativeText = localized(
      "assistant.changeLifetime",
      "Temporary corrections are discarded when Ganit quits. Save Value into Sheet replaces this line with your value and keeps the original as a comment."
    )
    let field = NSTextField(string: currentAssistantAnswerText())
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: localized("assistant.saveValue", "Save Value into Sheet"))
    alert.addButton(withTitle: localized("assistant.useTemporarily", "Use Temporarily"))
    alert.addButton(withTitle: localized("restore.cancel", "Cancel"))
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        if !saveAssistantAnswerAsValue(field.stringValue) {
          let error = NSAlert()
          error.messageText = localized("assistant.invalidValue", "Enter a valid value")
          error.informativeText = localized(
            "assistant.saveValueHelp",
            "Use a single-line value Ganit can calculate without assistance, such as 12345 ml. The sheet has not changed."
          )
          error.beginSheetModal(for: window)
        }
      case .alertSecondButtonReturn: applyAssistantAnswer(field.stringValue)
      default: break
      }
    }
  }

  /// Saves a reviewed correction as ordinary source, retaining the original
  /// line in a comment. No session-only answer cache is needed to reopen it.
  @discardableResult
  func saveAssistantAnswerAsValue(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.contains(where: { $0.isNewline }),
      let expression = CalculationEngine().parse(value, context: context).expression,
      expression.assistantPrompts.isEmpty,
      case .value = CalculationEngine().evaluate(value, context: context)
    else { return false }
    let id =
      sheetTextView.selectedAnswer
      ?? sheet.lines[lineIndex(atUTF16: textView.selectedRange().location)].id
    guard let index = sheet.lines.firstIndex(where: { $0.id == id }),
      assistantTarget() != nil
    else { return false }
    let line = sheet.lines[index]
    let replacement = value + " // Manual answer; original: " + line.text
    textView.breakUndoCoalescing()
    textView.insertText(
      replacement,
      replacementRange: NSRange(
        location: utf16Starts()[index], length: line.text.utf16.count))
    textView.breakUndoCoalescing()
    return true
  }

  /// Replaces the current assistant value with `text`. An empty string drops
  /// it so the line is as Ganit found it.
  func applyAssistantAnswer(_ text: String) {
    guard let target = assistantTarget() else {
      NSSound.beep()
      return
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == currentAssistantAnswerText() {
      return
    }
    switch target {
    case .line(let id, let asked):
      assistantLineInFlight.remove(asked)
      assistantAsked.insert(asked)
      if trimmed.isEmpty {
        assistantAnswers.removeValue(forKey: asked)
      } else {
        assistantAnswers[asked] = trimmed
      }
      cells[id] = nil
      sheetTextView.answersDidChange()
    case .prompts(let prompts):
      for prompt in prompts {
        assistantPromptsInFlight.remove(prompt)
        if trimmed.isEmpty {
          assistantValues.removeValue(forKey: prompt)
        } else if case .value(let value) = CalculationEngine().evaluate(trimmed, context: context) {
          assistantValues[prompt] = .value(value)
        } else {
          assistantValues[prompt] = .unusable
        }
      }
      context = context.with(assistantAnswers: assistantValues)
      scheduler?.context = context
      scheduler?.schedule(sheet)
    }
  }

  private func currentAssistantAnswerText() -> String {
    switch assistantTarget() {
    case .line(_, let asked):
      return assistantAnswers[asked] ?? ""
    case .prompts(let prompts):
      guard let prompt = prompts.first, case .value(let value) = assistantValues[prompt] else {
        return ""
      }
      return (try? resultFormatter.format(value))?.display ?? ""
    case nil:
      return ""
    }
  }

  private enum AssistantTarget {
    case prompts([String])
    case line(LineID, String)
  }

  /// What Ask Assistant would send for the selected answer or the insertion
  /// point's line: `ask_assistant` prompts, or a flagged line's text.
  private func assistantTarget() -> AssistantTarget? {
    let id =
      sheetTextView.selectedAnswer
      ?? sheet.lines[lineIndex(atUTF16: textView.selectedRange().location)].id
    guard let shown = shownLines[id] else {
      return nil
    }
    let prompts = assistantPrompts(in: shown)
    if !prompts.isEmpty {
      return .prompts(prompts)
    }
    if let asked = lineLevelAssistantPrompt(for: shown, id: id) {
      return .line(id, asked)
    }
    return nil
  }

  private func assistantPrompts(in shown: (text: String, result: SheetLineResult)) -> [String] {
    var prompts: [String] = []
    if case .evaluationFailure(let error) = shown.result.result,
      case .assistantPrompt(let prompt) = error.context, !prompt.isEmpty
    {
      prompts.append(prompt)
    }
    if case .calculation(_, _, let range?, _) = shown.result.syntax,
      let text = range.text(in: shown.text),
      let found = CalculationEngine().parse(String(text), context: context).expression?
        .assistantPrompts
    {
      for prompt in found where !prompts.contains(prompt) {
        prompts.append(prompt)
      }
    }
    return prompts
  }

  /// The line text the assistant is asked about when Ganit could not work the
  /// line out, or `nil` when this is not such a line.
  private func lineLevelAssistantPrompt(
    for shown: (text: String, result: SheetLineResult), id: LineID
  ) -> String? {
    guard let result = shown.result.result,
      flaggedDiagnostic(result, isEditing: id == editingLine) != nil
    else {
      return nil
    }
    if case .evaluationFailure(let error) = result,
      error.code == .unresolvedAssistantPrompt
        || error.code == .unusableAssistantAnswer
        || error.code == .unavailableReference
    {
      return nil
    }
    let asked = shown.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return asked.isEmpty ? nil : asked
  }

  /// The formatted value of a line, or the message of a failure its
  /// decoration flags.
  /// Every line with the answer it shows once evaluation settles, as if no
  /// line were being edited, for export and printing.
  public func exportedLines() async -> [ExportedLine] {
    await scheduler?.waitUntilIdle()
    return sheet.lines.map { line in
      let cell = shownLines[line.id]?.result.result.flatMap {
        makeCell(
          for: $0, isEditing: false, assisted: assistantAnswer(to: line.text),
          pending: isAssistantPending(text: line.text, result: $0))
      }
      return ExportedLine(
        source: line.text, answer: cell?.text,
        status: cell.map {
          $0.isPending
            ? .pending
            : $0.isAssisted
              ? .aiUnverified
              : $0.isFailure ? .failure : .calculated
        } ?? .none)
    }
  }

  /// Writes every answer again the way `options` asks, and re-evaluates when
  /// markdown mode changes what a line means.
  public func writeAnswers(_ options: DisplayOptions) {
    guard options != displayOptions else {
      return
    }
    displayOptions = options
    context = context.with(
      dollarCurrency: options.dollarCurrency, isMarkdownMode: options.writesAnswersInline)
    scheduler?.context = context
    resultFormatter = ResultFormatter(context: context, display: options)
    placeAnswers(options)
    cells.removeAll()
    decorations.removeAll()
    scheduler?.schedule(sheet)
    sheetTextView.answersDidChange()
    summarizeSelection()
  }

  private func placeAnswers(_ options: DisplayOptions) {
    sheetTextView.writesAnswersInline = options.writesAnswersInline
    sheetTextView.showsAnswerSeparator = options.showsAnswerSeparator
  }

  private func answerCell(for id: LineID) -> AnswerCell? {
    guard let shown = shownLines[id], let result = shown.result.result else {
      return nil
    }
    let isEditing = id == editingLine
    let assisted = assistantAnswer(to: shown.text)
    let pending = isAssistantPending(text: shown.text, result: result)
    if let cached = cells[id], cached.isEditing == isEditing, cached.result == result,
      cached.assisted == assisted, cached.pending == pending
    {
      return cached.cell
    }
    let cell = makeCell(for: result, isEditing: isEditing, assisted: assisted, pending: pending)
    cells[id] = (result, isEditing, assisted, pending, cell)
    return cell
  }

  private func assistantAnswer(to text: String) -> String? {
    assistantAnswers[text.trimmingCharacters(in: .whitespacesAndNewlines)]
  }

  private func isAssistantPending(text: String, result: CalculationResult) -> Bool {
    let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if assistantLineInFlight.contains(asked) {
      return true
    }
    if case .evaluationFailure(let error) = result,
      case .assistantPrompt(let prompt) = error.context,
      assistantPromptsInFlight.contains(prompt)
    {
      return true
    }
    return false
  }

  private func makeCell(
    for result: CalculationResult, isEditing: Bool, assisted: String? = nil, pending: Bool = false
  ) -> AnswerCell? {
    switch result {
    case .value(let value):
      return (try? resultFormatter.format(value)).map {
        AnswerCell(text: $0.display, fullPrecision: $0.fullPrecision)
      }
    case .syntaxFailure, .evaluationFailure:
      if pending {
        return AnswerCell(
          text: localized("assistant.testing", "Asking…"), fullPrecision: nil, isPending: true)
      }
      // What the assistant said answers the line; what Ganit says only
      // explains why it could not.
      if let assisted {
        return AnswerCell(text: assisted, fullPrecision: nil, isAssisted: true)
      }
      return flaggedDiagnostic(result, isEditing: isEditing).map {
        AnswerCell(text: $0.message, fullPrecision: nil)
      }
    }
  }

  private func flaggedDiagnostic(_ result: CalculationResult, isEditing: Bool)
    -> FormattedDiagnostic?
  {
    let diagnostic: FormattedDiagnostic
    switch result {
    case .syntaxFailure(let diagnostics) where !diagnostics.isEmpty:
      diagnostic = diagnosticFormatter.format(diagnostics[0])
    case .evaluationFailure(let error):
      diagnostic = diagnosticFormatter.format(error)
    default:
      return nil
    }
    return LineDecoration.style(for: diagnostic.severity, isEditing: isEditing) == nil
      ? nil : diagnostic
  }

  /// The interpretation card rows for a line's shown answer.
  private func interpretation(for id: LineID) -> [AnswerCell.Detail] {
    guard let shown = shownLines[id], let result = shown.result.result else {
      return []
    }
    var details: [AnswerCell.Detail] = []
    if case .calculation(_, _, let range?, _) = shown.result.syntax {
      let utf8 = shown.text.utf8
      let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
      details.append(
        AnswerCell.Detail(
          label: localized("interpretation.expression", "Expression"),
          value: String(shown.text[lower..<utf8.index(lower, offsetBy: range.utf8Length)])
        )
      )
    }
    switch result {
    case .value(let value):
      guard let formatted = try? resultFormatter.format(value) else {
        return details
      }
      details += [
        AnswerCell.Detail(
          label: localized("interpretation.result", "Result"), value: formatted.display),
        AnswerCell.Detail(
          label: localized("interpretation.fullPrecision", "Full precision"),
          value: formatted.fullPrecision
        ),
        AnswerCell.Detail(label: localized("interpretation.kind", "Kind"), value: kindName(value)),
        AnswerCell.Detail(
          label: localized("interpretation.exactness", "Exactness"),
          value: formatted.isApproximate
            ? localized("interpretation.approximate", "Approximate")
            : localized("interpretation.exact", "Exact")
        ),
      ]
      if case .instant(let instant) = value,
        let zone = TimeZone(identifier: instant.timeZoneIdentifier)
      {
        let offset = zone.secondsFromGMT(for: instant.date)
        details += [
          AnswerCell.Detail(
            label: localized("interpretation.timeZone", "Time zone"),
            value: instant.timeZoneIdentifier),
          AnswerCell.Detail(
            label: localized("interpretation.utcOffset", "UTC offset"),
            value: String(
              format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3_600,
              abs(offset) / 60 % 60)
          ),
        ]
      }
      // A finance answer means nothing without what it assumed.
      details += FinanceFunction.allCases.filter(shown.result.financeUses.contains).map {
        AnswerCell.Detail(
          label: localized("interpretation.assumption", "Assumption"),
          value: assumption(of: $0)
        )
      }
      // Rate status depends on the current day, not the evaluation's.
      details += RateProvenanceFormatter(context: context.at(Date()))
        .details(for: shown.result.rateUses)
        .map { AnswerCell.Detail(label: $0.label, value: $0.value) }
    case .syntaxFailure, .evaluationFailure:
      guard let diagnostic = flaggedDiagnostic(result, isEditing: false) else {
        return details
      }
      details += [
        AnswerCell.Detail(
          label: localized("interpretation.problem", "Problem"), value: diagnostic.message)
      ]
      // The text the underline marks, so the card says where as well as what.
      if let range = diagnostic.ranges.first, !range.isEmpty,
        let flagged = range.text(in: shown.text).map(String.init), flagged != details.first?.value
      {
        details.insert(
          AnswerCell.Detail(
            label: localized("interpretation.where", "Where"), value: "“\(flagged)”"),
          at: details.count - 1)
      }
      details += diagnostic.fixIts.map {
        AnswerCell.Detail(
          label: localized("interpretation.suggestion", "Suggestion"), value: $0.replacement)
      }
    }
    return details
  }

  /// What a finance function took for granted, which its answer depends on.
  private func assumption(of function: FinanceFunction) -> String {
    switch function {
    case .futureValue:
      return localized(
        "interpretation.assumption.futureValue",
        "The rate is per period and compounds once each period."
      )
    case .presentValue:
      return localized(
        "interpretation.assumption.presentValue",
        "The rate is per period and discounts once each period."
      )
    case .payment:
      return localized(
        "interpretation.assumption.payment",
        "Equal payments at the end of each period, at the rate for one period."
      )
    }
  }

  private func kindName(_ value: EngineValue) -> String {
    switch value {
    case .number:
      return localized("interpretation.kind.number", "Number")
    case .percentage:
      return localized("interpretation.kind.percentage", "Percentage")
    case .quantity:
      return localized("interpretation.kind.quantity", "Quantity")
    case .rate:
      return localized("interpretation.kind.rate", "Rate")
    case .date:
      return localized("interpretation.kind.date", "Date")
    case .time:
      return localized("interpretation.kind.time", "Time of day")
    case .instant:
      return localized("interpretation.kind.instant", "Date and time")
    case .period:
      return localized("interpretation.kind.period", "Calendar period")
    case .money:
      return localized("interpretation.kind.money", "Money")
    }
  }

  /// Applies a line's decoration when the shown evaluation still matches its
  /// text and the decoration or the text's attributes may have changed.
  private func decorate(_ index: Int) {
    let line = sheet.lines[index]
    guard let shown = shownLines[line.id], shown.text == line.text,
      let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let start = contentManager.location(
        contentManager.documentRange.location,
        offsetBy: utf16Starts()[index]
      ),
      let end = contentManager.location(start, offsetBy: line.text.utf16.count),
      let lineRange = NSTextRange(location: start, end: end)
    else {
      return
    }
    let decoration = LineDecoration(
      text: line.text,
      syntax: shown.result.syntax,
      result: shown.result.result,
      isEditing: line.id == editingLine
    )
    guard decoration != decorations[line.id] || editedLines.contains(line.id) else {
      return
    }
    layoutManager.setRenderingAttributes([:], for: lineRange)
    let underlines = decoration.runs.compactMap { run in
      run.style.underlineColor.map { (range: run.range, color: $0) }
    }
    sheetTextView.underlines[line.id] = underlines.isEmpty ? nil : underlines
    for run in decoration.runs where !run.style.attributes.isEmpty {
      guard let runStart = contentManager.location(start, offsetBy: run.range.location),
        let runEnd = contentManager.location(runStart, offsetBy: run.range.length),
        let runRange = NSTextRange(location: runStart, end: runEnd)
      else {
        continue
      }
      for (key, value) in run.style.attributes {
        layoutManager.addRenderingAttribute(key, value: value, for: runRange)
      }
    }
    decorations[line.id] = decoration
    editedLines.remove(line.id)
  }

  private func utf16Starts() -> [Int] {
    if let cachedUTF16Starts {
      return cachedUTF16Starts
    }
    var starts: [Int] = []
    starts.reserveCapacity(sheet.lines.count)
    var offset = 0
    for line in sheet.lines {
      starts.append(offset)
      offset += line.text.utf16.count + (line.terminator?.rawValue.utf16.count ?? 0)
    }
    cachedUTF16Starts = starts
    return starts
  }

  /// The index of the line containing a UTF-16 offset.
  private func lineIndex(atUTF16 offset: Int) -> Int {
    let starts = utf16Starts()
    var low = 0
    var high = starts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if starts[middle] <= offset {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return low
  }
}

/// Receives text-system callbacks for the controller.
@MainActor
private final class StorageObserver: NSObject, @preconcurrency NSTextStorageDelegate,
  NSTextViewDelegate
{
  weak var controller: SheetEditorViewController?

  func textStorage(
    _ textStorage: NSTextStorage,
    didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else {
      return
    }
    controller?.mirrorEdit(newRange: editedRange, changeInLength: delta)
  }

  func textView(
    _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
  ) -> Bool {
    controller?.noteLineShift(replacing: range, with: replacementString)
    return true
  }

  func textDidChange(_ notification: Notification) {
    controller?.renumberLineReferences()
    controller?.textDidChange()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    controller?.selectionDidChange()
  }

  func undoManager(for view: NSTextView) -> UndoManager? {
    controller?.documentUndoManager
  }
}

func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}

extension CalculationResult {
  fileprivate var isFailure: Bool {
    if case .value = self {
      return false
    }
    return true
  }
}
