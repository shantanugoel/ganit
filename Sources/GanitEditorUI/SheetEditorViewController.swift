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
  package private(set) var tableEvaluationSource: String?
  package var tableProjectionObservers: [UUID: () -> Void] = [:]
  public var evaluationDidCommit: ((SheetEvaluation) -> Void)?
  private func refreshTableProjections() {
    for observer in tableProjectionObservers.values { observer() }
    refreshInlineTables()
  }
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
  /// Forgets a kept reply to the text asked, so that Ask Assistant asks the
  /// model again rather than repeating it.
  public var forgetAssistantAnswer: ((String) -> Void)?
  /// Opens Help on a topic the pointer is over, such as a function name.
  public var openHelp: ((String) -> Void)? {
    didSet {
      sheetTextView.openHelp = openHelp
    }
  }

  private var context: EvaluationContext
  let scrollView = NSScrollView()
  package private(set) var expandedTable: ExpandedTableViewController?
  private var tableViewStates: [TableID: (TableCellPosition, TableCellPosition, NSPoint)] = [:]
  private var proseScroll = NSPoint.zero
  private let permitsTableEditing: Bool
  package var permitsInlineTables: Bool { permitsTableEditing && !showsTableSource }
  package private(set) var showsTableSource = false
  var inlineTableViews: [TableID: InlineTablePreview] = [:]
  private var normalizingInlineSelection = false
  private var previousProseSelection = NSRange(location: 0, length: 0)
  package var inlineTableRanges: [TableID: NSRange] = [:]
  let summaryBar = SelectionSummaryBar()
  private let sheetTextView = SheetTextView(usingTextLayoutManager: true)
  private let storageObserver = StorageObserver()
  /// Applies edits that are not typed, such as structural table edits,
  /// through the same source, Undo, rewrite, autosave and evaluation path.
  private(set) lazy var sourceCoordinator = SheetSourceCoordinator(
    textView: sheetTextView, undoManager: documentUndoManager)
  private(set) var scheduler: SheetEvaluationScheduler?
  /// How this sheet reads numbers, which line references are lexed with.
  var lexingConfiguration: LexingConfiguration { context.lexingConfiguration }
  package func formatTableValue(_ value: EngineValue) -> FormattedResult? {
    try? resultFormatter.format(value)
  }
  package func formatTableValue(
    _ value: EngineValue, column: ColumnID, result: TableResultSnapshot?
  ) -> FormattedResult? {
    let presented = result?.percentageValue(value, column: column) ?? value
    guard let digits = result?.percentageDecimals(column: column) else {
      return formatTableValue(presented)
    }
    var options = displayOptions
    options.numbers = .fixedDecimals(digits)
    return try? ResultFormatter(context: context, display: options).format(presented)
  }
  package var tableEvaluationContext: EvaluationContext { context }
  package func formatTableError(_ error: EngineError) -> String {
    diagnosticFormatter.format(error).message
  }
  /// The sheet's number locale, which table exports and headless readers
  /// follow so values read the same everywhere.
  package var tableExportLocale: Locale {
    Locale(identifier: context.localeIdentifier)
  }
  package func tableFinanceAssumption(_ name: String) -> String {
    FinanceFunction(rawValue: name).map { assumption(of: $0) } ?? name
  }
  private var resultFormatter: ResultFormatter
  /// Writes values to fewer digits for an answer column too narrow for them.
  private var compactFormatter: ResultFormatter
  private var diagnosticFormatter: DiagnosticFormatter
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
  /// Lines already sent, including ones that came back empty or whose
  /// request was cancelled, so none is retried on every keystroke. Ask
  /// Assistant asks again.
  private var assistantAsked: Set<String> = []
  /// Requests that have not come back yet, by the line text asked, shown as
  /// Asking… until they finish or are cancelled.
  private var assistantLineInFlight: [String: Task<Void, Never>] = [:]
  /// Parsed values for `ask_assistant` prompts, reused across evaluations.
  private var assistantValues: [AssistantPrompt: AssistantAnswer] = [:]
  private var assistantPromptsInFlight: [AssistantPrompt: Task<Void, Never>] = [:]
  /// Prompts whose request was cancelled, which are not asked again until
  /// Ask Assistant.
  private var assistantPromptsCancelled: Set<AssistantPrompt> = []
  /// Each line's UTF-16 start offset, in line order.
  private var cachedUTF16Starts: [Int]?
  /// Gutter drawing must not scan the whole sheet for every visible number.
  private var cachedLineNumbers: [LineID: Int]?
  /// The physical lines of every table block, valid or not, which editor
  /// conveniences such as completion and scrubbing never rewrite.
  private var cachedTableLines: IndexSet?
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
  /// Called when the editor itself changes `displayOptions`, such as one
  /// answer's format, so they can be saved with the sheet.
  public var displayOptionsDidChange: ((DisplayOptions) -> Void)?

  /// `surface` is where the sheet is shown: off the workspace, as in the
  /// definitions sheet and Quick Ganit, its tables are kept but never
  /// calculated, and each block's first line says why.
  public init(
    text: String = "",
    context: EvaluationContext,
    display: DisplayOptions = .standard,
    surface: SheetSurface = .workspace
  ) {
    permitsTableEditing = surface == .workspace
    self.context = context.with(
      dollarCurrency: display.dollarCurrency, isMarkdownMode: display.writesAnswersInline,
      ambiguousSuffixes: display.ambiguousSuffixes)
    displayOptions = display
    resultFormatter = ResultFormatter(context: context, display: display)
    compactFormatter = Self.compactFormatter(context: context, display: display)
    diagnosticFormatter = DiagnosticFormatter(context: context)
    sheet = SheetSource(text)
    mirroredText = text
    super.init(nibName: nil, bundle: nil)

    configureTextView(text: text)
    placeAnswers(display)
    sheetTextView.findTableHit = { [weak self] in self?.openTableAtFindSelection() }
    sheetTextView.previewTableFindHit = { [weak self] in self?.previewTableAtFindSelection() }
    sheetTextView.tableCreationTarget = permitsTableEditing ? self : nil
    sheetTextView.inlineLayout = { [weak self] in self?.layoutInlineTables() }
    sheetTextView.inlineRefresh = { [weak self] in self?.refreshInlineTables() }
    sheetTextView.inlineRanges = { [weak self] in
      Array(self?.inlineTableRanges.values ?? [:].values)
    }
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
    sheetTextView.isTableLine = { [weak self] offset in
      guard let self else { return false }
      return tableLines().contains(lineIndex(atUTF16: offset))
    }
    sheetTextView.touchesTableLine = { [weak self] range in
      guard let self else { return false }
      return tableLines().intersects(
        integersIn: lineIndex(atUTF16: range.location)...lineIndex(atUTF16: range.upperBound))
    }
    sheetTextView.lineNumber = { [weak self] id in
      guard let self else { return nil }
      if cachedLineNumbers == nil {
        cachedLineNumbers = Dictionary(
          uniqueKeysWithValues:
            sheet.lines.enumerated().map { ($0.element.id, $0.offset + 1) })
      }
      return cachedLineNumbers?[id]
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
      return flaggedDiagnostic(result, text: shown.text, isEditing: id == editingLine)
    }
    sheetTextView.onSetSheetDollarCurrency = { [weak self] code in
      guard let self else { return }
      var options = displayOptions
      options.dollarCurrency = code
      writeAnswers(options)
      displayOptionsDidChange?(options)
    }
    sheetTextView.onSetSheetSuffixMeaning = { [weak self] suffix, meaning in
      guard let self else { return }
      var options = displayOptions
      options.ambiguousSuffixes[suffix] = meaning
      writeAnswers(options)
      displayOptionsDidChange?(options)
    }
    sheetTextView.variableNames = { [weak self] in
      self?.variableNames() ?? []
    }
    sheetTextView.referenceCompletions = { [weak self] offset in
      self?.referenceCompletions(at: offset) ?? []
    }
    sheetTextView.variableCompletions = { [weak self] offset in
      self?.referenceCompletions(at: offset, includesLines: false) ?? []
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
    sheetTextView.answerFormat = { [weak self] in
      self?.answerFormat()
    }
    sheetTextView.onSetAnswerFormat = { [weak self] numbers in
      self?.setAnswerFormat(numbers)
    }
    sheetTextView.canCancelAssistantRequest = { [weak self] in
      self?.canCancelAssistantRequest() ?? false
    }
    sheetTextView.onCancelAssistantRequest = { [weak self] in
      self?.cancelAssistantRequest()
    }
    sheetTextView.didDrawAnswers = { [weak self] in
      guard let self, let interval = pendingAnswerDraw else {
        return
      }
      pendingAnswerDraw = nil
      editToAnswerHandler?(interval.end())
    }
    scheduler = SheetEvaluationScheduler(context: context, surface: surface) {
      [weak self] snapshot, evaluation, editToAnswer in
      guard let self else {
        return editToAnswer.cancel()
      }
      pendingAnswerDraw?.cancel()
      pendingAnswerDraw = editToAnswer
      show(evaluation, of: snapshot)
    }
    refreshInlineTables()
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
    view.window?.makeFirstResponder(expandedTable?.grid ?? textView)
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
    cachedLineNumbers = nil
    cachedTableLines = nil
    for index in lineIndex(atUTF16: newRange.location)...lineIndex(atUTF16: newRange.upperBound) {
      let id = sheet.lines[index].id
      editedLines.insert(id)
      // Underline ranges no longer match the edited text.
      sheetTextView.underlines[id] = nil
    }
    refreshTableProjections()
    sourceDidChange?()
    // Undo and other programmatic edits do not send `textDidChange`.
    textDidChange()
  }

  private var pendingReferenceEdits: [(range: NSRange, replacement: String)] = []
  private var isRewritingReferences = false

  fileprivate func noteLineShift(replacing ranges: [NSRange], with replacements: [String]?) {
    guard let replacements, !isRewritingReferences,
      !documentUndoManager.isUndoing, !documentUndoManager.isRedoing
    else { return }
    let edits = LineReferenceRenumbering.edits(
      replacing: ranges, in: textView.string, with: replacements,
      configuration: context.lexingConfiguration)
    guard !edits.isEmpty else { return }
    textView.breakUndoCoalescing()
    documentUndoManager.beginUndoGrouping()
    pendingReferenceEdits = edits
  }

  fileprivate func renumberLineReferences() {
    guard !pendingReferenceEdits.isEmpty else { return }
    let edits = pendingReferenceEdits
    pendingReferenceEdits = []
    isRewritingReferences = true
    defer {
      isRewritingReferences = false
      textView.breakUndoCoalescing()
      documentUndoManager.endUndoGrouping()
    }
    for edit in edits.reversed()
    where textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
      textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
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

  /// Reads and writes numbers as `localeIdentifier` does, with
  /// `lexingConfiguration`'s separators, and evaluates the sheet again.
  public func setNumberStyle(
    localeIdentifier: String, lexingConfiguration: LexingConfiguration
  ) {
    guard
      context.localeIdentifier != localeIdentifier
        || context.lexingConfiguration != lexingConfiguration
    else {
      return
    }
    context = context.with(
      localeIdentifier: localeIdentifier, lexingConfiguration: lexingConfiguration)
    resultFormatter = ResultFormatter(context: context, display: displayOptions)
    compactFormatter = Self.compactFormatter(context: context, display: displayOptions)
    diagnosticFormatter = DiagnosticFormatter(context: context)
    sheetTextView.lexingConfiguration = lexingConfiguration
    cells.removeAll()
    decorations.removeAll()
    scheduler?.context = context
    scheduler?.schedule(sheet)
    sheetTextView.answersDidChange()
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

  /// Stops the running evaluation and every assistant request; answers stay
  /// at the last completed evaluation.
  @objc public func stopCalculation(_ sender: Any?) {
    scheduler?.cancel()
    cancelAssistantRequests(
      lines: Array(assistantLineInFlight.keys), prompts: Array(assistantPromptsInFlight.keys))
  }

  fileprivate func selectionDidChange() {
    guard !normalizingInlineSelection, !sheetTextView.isCopyingSource else { return }
    let selected = textView.selectedRange()
    if permitsInlineTables, !textView.hasMarkedText(), !sheetTextView.isPerformingFind,
      !scrollView.isFindBarVisible, !sourceCoordinator.isApplying
    {
      var mapped = selected
      for block in inlineTableRanges.values {
        if mapped.length == 0, mapped.location > block.location, mapped.location < block.upperBound
        {
          let edge =
            previousProseSelection.location <= mapped.location ? block.upperBound : block.location
          mapped = NSRange(location: edge, length: 0)
        }
      }
      if mapped != selected {
        normalizingInlineSelection = true
        textView.setSelectedRange(mapped)
        normalizingInlineSelection = false
      }
    }
    previousProseSelection = textView.selectedRange()
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
    let tableLines = tableLines()
    for (index, (line, start)) in zip(sheet.lines, utf16Starts()).enumerated() {
      guard start < selection.upperBound, start + line.text.utf16.count > selection.location,
        !tableLines.contains(index)
      else {
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
        if let shown, isAssistantPending(text: line.text, line: shown.result) {
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
    tableEvaluationSource = snapshot.text
    refreshTableProjections()
    evaluationDidCommit?(evaluation)
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
    sheetTextView.refreshReferenceCompletions()
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
        !assistantAsked.contains(asked), assistantLineInFlight[asked] == nil
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
    assistantLineInFlight[asked] = Task { [weak self] in
      let answer = await askAssistant(asked)
      guard let self, !Task.isCancelled else {
        return
      }
      assistantLineInFlight[asked] = nil
      assistantAsked.insert(asked)
      if let answer {
        assistantAnswers[asked] = answer
        // Lines referring to this one now say why they cannot use it.
        cells.removeAll()
      }
      sheetTextView.answersDidChange()
      summarizeSelection()
    }
    sheetTextView.answersDidChange()
    summarizeSelection()
  }

  /// Asks about each `ask_assistant` prompt that still has no value, then
  /// evaluates again so later lines can use the answer.
  private func askAboutPrompts() {
    for line in latestEvaluation?.lines ?? [] {
      line.assistantPrompts.forEach(requestAssistantPrompt)
    }
  }

  private func requestAssistantPrompt(_ prompt: AssistantPrompt) {
    guard let askAssistant, assistantValues[prompt] == nil,
      assistantPromptsInFlight[prompt] == nil, !assistantPromptsCancelled.contains(prompt)
    else {
      return
    }
    let text = text(of: prompt)
    assistantPromptsInFlight[prompt] = Task { [weak self] in
      let answer = await askAssistant(text)
      guard !Task.isCancelled else {
        return
      }
      self?.finishAssistantPrompt(prompt, answer: answer)
    }
    sheetTextView.answersDidChange()
    summarizeSelection()
  }

  /// The text sent for `prompt`, its values written as the sheet shows them.
  private func text(of prompt: AssistantPrompt) -> String {
    prompt.text { (try? resultFormatter.format($0))?.display ?? "" }
  }

  private func finishAssistantPrompt(_ prompt: AssistantPrompt, answer: String?) {
    assistantPromptsInFlight[prompt] = nil
    if let answer, case .value(let value) = CalculationEngine().evaluate(answer, context: context) {
      assistantValues[prompt] = .value(value)
    } else {
      assistantValues[prompt] = .unusable
    }
    context = context.with(assistantAnswers: assistantValues)
    scheduler?.context = context
    scheduler?.schedule(sheet)
  }

  /// The names a `{…}` placeholder can complete to: this sheet's variables
  /// and the definitions sheet's.
  private func variableNames() -> [String] {
    referenceCompletions(at: textView.selectedRange().location, includesLines: false)
      .filter { !$0.insertion.hasPrefix("@") }.map(\.insertion)
  }

  /// Values the caret can read: inherited definitions, variables in scope,
  /// and successfully calculated lines above it. Previews use existing results.
  private func referenceCompletions(at offset: Int, includesLines: Bool = true) -> [CompletionItem]
  {
    let inherited = scheduler?.definitions.variables ?? [:]
    func item(_ name: String, _ value: EngineValue) -> CompletionItem {
      CompletionItem(name, detail: (try? resultFormatter.format(value))?.display ?? "")
    }
    var variables = inherited.reduce(into: [String: CompletionItem]()) {
      $0[$1.key.lowercased()] = item($1.key, $1.value)
    }
    let defaults = variables
    var lines: [CompletionItem] = []
    let tableLines = tableLines()
    for (index, line) in sheet.lines.prefix(lineIndex(atUTF16: offset)).enumerated() {
      // A `---` line inside a table block is block source, not a divider.
      if !tableLines.contains(index), case .divider = LineSyntax(line.text) {
        variables = defaults
      }
      guard let shown = shownLines[line.id], shown.text == line.text else { continue }
      let result = shown.result
      if let name = result.declaredVariableName {
        variables[name] = nil
        if case .value(let value) = result.result,
          case .calculation(_, let range?, _, _) = result.syntax,
          let written = range.text(in: line.text)
        {
          let spelling = written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
          variables[name] = item(spelling, value)
        }
      }
      if includesLines, case .value(let value) = result.result {
        let preview = (try? resultFormatter.format(value))?.display ?? ""
        lines.append(CompletionItem("@\(index + 1)", detail: line.text + " → " + preview))
      }
    }
    return variables.values.sorted {
      $0.insertion.localizedCaseInsensitiveCompare($1.insertion) == .orderedAscending
    } + lines
  }

  /// Whether Ask Assistant can send the selected answer's line, or the
  /// insertion point's, including a line already asked about.
  func canAskAssistant() -> Bool {
    askAssistant != nil && assistantTarget() != nil
  }

  /// Whether the selected answer, or the insertion point's line, is waiting
  /// for the assistant.
  func canCancelAssistantRequest() -> Bool {
    switch assistantTarget() {
    case .line(_, let asked):
      return assistantLineInFlight[asked] != nil
    case .prompts(let prompts):
      return prompts.contains { assistantPromptsInFlight[$0] != nil }
    case nil:
      return false
    }
  }

  /// Cancels the selected answer's request, or the insertion point's line's.
  func cancelAssistantRequest() {
    switch assistantTarget() {
    case .line(_, let asked):
      cancelAssistantRequests(lines: [asked], prompts: [])
    case .prompts(let prompts):
      cancelAssistantRequests(lines: [], prompts: prompts)
    case nil:
      NSSound.beep()
    }
  }

  /// Stops waiting for these requests and does not ask again until Ask
  /// Assistant. A cancelled request may already have reached the provider.
  private func cancelAssistantRequests(lines: [String], prompts: [AssistantPrompt]) {
    for asked in lines {
      assistantLineInFlight.removeValue(forKey: asked)?.cancel()
      assistantAsked.insert(asked)
    }
    for prompt in prompts {
      assistantPromptsInFlight.removeValue(forKey: prompt)?.cancel()
      assistantPromptsCancelled.insert(prompt)
    }
    sheetTextView.answersDidChange()
    summarizeSelection()
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
      cancelAssistantRequests(lines: [], prompts: prompts)
      for prompt in prompts {
        assistantValues.removeValue(forKey: prompt)
        assistantPromptsCancelled.remove(prompt)
        forgetAssistantAnswer?(text(of: prompt))
      }
      context = context.with(assistantAnswers: assistantValues)
      scheduler?.context = context
      scheduler?.schedule(sheet)
      for prompt in prompts {
        requestAssistantPrompt(prompt)
      }
    case .line(_, let asked):
      cancelAssistantRequests(lines: [asked], prompts: [])
      assistantAnswers.removeValue(forKey: asked)
      assistantAsked.remove(asked)
      forgetAssistantAnswer?(asked)
      cells.removeAll()
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
      case .value = CalculationEngine().evaluate(
        value, context: context.with(assistantAnswers: [:]))
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
    case .line(_, let asked):
      cancelAssistantRequests(lines: [asked], prompts: [])
      if trimmed.isEmpty {
        assistantAnswers.removeValue(forKey: asked)
      } else {
        assistantAnswers[asked] = trimmed
      }
      cells.removeAll()
      sheetTextView.answersDidChange()
    case .prompts(let prompts):
      cancelAssistantRequests(lines: [], prompts: prompts)
      for prompt in prompts {
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
    case prompts([AssistantPrompt])
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
    let prompts = shown.result.assistantPrompts
    if !prompts.isEmpty {
      return .prompts(prompts)
    }
    if let asked = lineLevelAssistantPrompt(for: shown, id: id) {
      return .line(id, asked)
    }
    return nil
  }

  /// The line text the assistant is asked about when Ganit could not work the
  /// line out, or `nil` when this is not such a line.
  private func lineLevelAssistantPrompt(
    for shown: (text: String, result: SheetLineResult), id: LineID
  ) -> String? {
    guard let result = shown.result.result,
      flaggedDiagnostic(result, text: shown.text, isEditing: id == editingLine) != nil,
      separatorMismatch(in: shown.text) == nil
    else {
      return nil
    }
    // A trailing `=` is answered by removing it, not by a model.
    if case .syntaxFailure(let diagnostics) = result, diagnostics.first?.code == .trailingEquals {
      return nil
    }
    if case .evaluationFailure(let error) = result,
      error.code == .unresolvedAssistantPrompt
        || error.code == .unusableAssistantAnswer
        || error.code == .brokenReference
        || error.code == .unavailableReference
        // Tables are calculated locally; no table error is sent to a model.
        || error.code == .tableReference
        || error.code == .typeMismatch
        || error.code == .incompatibleDimensions
        || error.code == .missingCurrencyRate
        || error.code == .currencyRatesUnavailable
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
      let cell = shownLines[line.id].flatMap { shown in
        shown.result.result.flatMap {
          makeCell(
            for: $0, text: line.text, isEditing: false, assisted: assistantAnswer(to: line.text),
            pending: isAssistantPending(text: line.text, line: shown.result))
        }
      }
      return ExportedLine(
        source: line.text, answer: cell?.text, fullPrecision: cell?.fullPrecision,
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
      dollarCurrency: options.dollarCurrency, isMarkdownMode: options.writesAnswersInline,
      ambiguousSuffixes: options.ambiguousSuffixes)
    scheduler?.context = context
    resultFormatter = ResultFormatter(context: context, display: options)
    compactFormatter = Self.compactFormatter(context: context, display: options)
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
    sheetTextView.showsLineNumbers = options.showsLineNumbers
    sheetTextView.dollarCurrency = options.dollarCurrency
    sheetTextView.ambiguousSuffixes = options.ambiguousSuffixes
  }

  private func answerCell(for id: LineID) -> AnswerCell? {
    guard let shown = shownLines[id], let result = shown.result.result else {
      return nil
    }
    // In Markdown Mode, as in Calca, a line shows its answer only when it
    // asks for one with `=>`.
    if displayOptions.writesAnswersInline, LineSyntax.arrow(in: shown.text) == nil {
      return nil
    }
    let isEditing = id == editingLine
    let assisted = assistantAnswer(to: shown.text)
    let pending = isAssistantPending(text: shown.text, line: shown.result)
    if let cached = cells[id], cached.isEditing == isEditing, cached.result == result,
      cached.assisted == assisted, cached.pending == pending
    {
      return cached.cell
    }
    let cell = makeCell(
      for: result, text: shown.text, isEditing: isEditing, assisted: assisted, pending: pending)
    cells[id] = (result, isEditing, assisted, pending, cell)
    return cell
  }

  private func assistantAnswer(to text: String) -> String? {
    assistantAnswers[text.trimmingCharacters(in: .whitespacesAndNewlines)]
  }

  private func isAssistantPending(text: String, line: SheetLineResult) -> Bool {
    assistantLineInFlight[text.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
      || line.assistantPrompts.contains { assistantPromptsInFlight[$0] != nil }
  }

  private func makeCell(
    for result: CalculationResult, text: String, isEditing: Bool, assisted: String? = nil,
    pending: Bool = false
  ) -> AnswerCell? {
    switch result {
    case .value(let value):
      let formatters = formatters(for: text)
      return (try? formatters.full.format(value)).map {
        var cell = AnswerCell(text: $0.display, fullPrecision: $0.fullPrecision)
        if let compact = try? formatters.compact.format(value).display, compact != $0.display {
          cell.compactText = compact.hasPrefix("≈") ? compact : "≈ " + compact
        }
        return cell
      }
    case .syntaxFailure, .evaluationFailure:
      if pending {
        return AnswerCell(
          text: localized("assistant.testing", "Asking…"), fullPrecision: nil, isPending: true)
      }
      // What the assistant said answers the line; what Ganit says only
      // explains why it could not.
      if let assisted, canUseLineAssistantAnswer(result) {
        return AnswerCell(text: assisted, fullPrecision: nil, isAssisted: true)
      }
      return flaggedDiagnostic(result, text: text, isEditing: isEditing).map {
        AnswerCell(text: $0.message, fullPrecision: nil)
      }
    }
  }

  private func canUseLineAssistantAnswer(_ result: CalculationResult) -> Bool {
    if case .evaluationFailure(let error) = result {
      return ![
        .unresolvedAssistantPrompt, .unusableAssistantAnswer, .unavailableReference,
        .brokenReference, .tableReference,
        .typeMismatch, .incompatibleDimensions, .missingCurrencyRate,
        .currencyRatesUnavailable,
      ].contains(error.code)
    }
    if case .syntaxFailure(let diagnostics) = result {
      return diagnostics.first?.code != .trailingEquals
    }
    return false
  }

  /// The sheet's formatters, or ones writing numbers in the format chosen for
  /// this line's answer.
  private func formatters(for text: String) -> (full: ResultFormatter, compact: ResultFormatter) {
    guard let numbers = displayOptions.answerFormats[Self.answerFormatKey(text)] else {
      return (resultFormatter, compactFormatter)
    }
    var options = displayOptions
    options.numbers = numbers
    return (
      ResultFormatter(context: context, display: options),
      Self.compactFormatter(context: context, display: options)
    )
  }

  private static func answerFormatKey(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }

  /// The line of the selected answer, or of the insertion point.
  private var targetLineText: String? {
    let id =
      sheetTextView.selectedAnswer
      ?? sheet.lines[lineIndex(atUTF16: textView.selectedRange().location)].id
    return sheet.lines.first { $0.id == id }?.text
  }

  /// The format chosen for the target answer, or `nil` for the sheet's.
  func answerFormat() -> NumberDisplay? {
    targetLineText.flatMap { displayOptions.answerFormats[Self.answerFormatKey($0)] }
  }

  /// Writes the target answer in `numbers`, or in the sheet's format again
  /// for `nil`, and reports the sheet's changed display options.
  func setAnswerFormat(_ numbers: NumberDisplay?) {
    guard let text = targetLineText else {
      NSSound.beep()
      return
    }
    var options = displayOptions
    options.answerFormats[Self.answerFormatKey(text)] = numbers
    writeAnswers(options)
    displayOptionsDidChange?(options)
  }

  private static func compactFormatter(context: EvaluationContext, display: DisplayOptions)
    -> ResultFormatter
  {
    let precision =
      (try? PrecisionContext(
        significantDecimalDigits: min(6, context.precision.significantDecimalDigits),
        roundingRule: context.precision.roundingRule)) ?? context.precision
    return ResultFormatter(context: context.with(precision: precision), display: display)
  }

  private func flaggedDiagnostic(_ result: CalculationResult, text: String, isEditing: Bool)
    -> FormattedDiagnostic?
  {
    let diagnostic: FormattedDiagnostic
    switch result {
    case .syntaxFailure(let diagnostics) where !diagnostics.isEmpty:
      diagnostic =
        separatorMismatchDiagnostic(diagnostics[0], text: text)
        ?? diagnosticFormatter.format(diagnostics[0])
    case .evaluationFailure(let error):
      diagnostic = assistedReferenceDiagnostic(error) ?? diagnosticFormatter.format(error)
    default:
      return nil
    }
    return LineDecoration.style(for: diagnostic.severity, isEditing: isEditing) == nil
      ? nil : diagnostic
  }

  /// The expression of a line that reads only with the other number style,
  /// and that expression rewritten with `.` and `,` swapped when this sheet
  /// reads the rewrite.
  private func separatorMismatch(in text: String) -> (
    range: SourceRange, rewrite: String?
  )? {
    guard case .calculation(_, _, let range?, _) = LineSyntax(text),
      let expression = range.text(in: text).map(String.init)
    else {
      return nil
    }
    let current = context.lexingConfiguration
    let other: LexingConfiguration =
      current.decimalSeparator == "," ? .englishUnitedStates : .decimalComma
    let reads = { (source: String, lexing: LexingConfiguration) in
      let parsed = CalculationEngine().parse(
        source,
        context: self.context.with(
          localeIdentifier: self.context.localeIdentifier, lexingConfiguration: lexing))
      return parsed.expression != nil && parsed.diagnostics.isEmpty
    }
    guard !reads(expression, current), reads(expression, other) else {
      return nil
    }
    let swapped = String(expression.map { $0 == "." ? "," : $0 == "," ? "." : $0 })
    return (range, reads(swapped, current) ? swapped : nil)
  }

  /// Says which number style a line was written in instead of calling its
  /// separators unexpected, and offers the line rewritten for this sheet.
  private func separatorMismatchDiagnostic(_ syntax: SyntaxDiagnostic, text: String)
    -> FormattedDiagnostic?
  {
    guard let mismatch = separatorMismatch(in: text) else {
      return nil
    }
    let formatted = diagnosticFormatter.format(syntax)
    let message =
      context.lexingConfiguration.decimalSeparator == ","
      ? localized(
        "diagnostic.pointDecimalNumbers",
        "Numbers here are written 1,234.56, but this sheet uses 1.234,56. Turn off Format ▸ Decimal Comma, or rewrite them."
      )
      : localized(
        "diagnostic.commaDecimalNumbers",
        "Numbers here are written 1.234,56, but this sheet uses 1,234.56. Choose Format ▸ Decimal Comma, or rewrite them."
      )
    return FormattedDiagnostic(
      code: formatted.code, severity: formatted.severity, ranges: formatted.ranges,
      message: message,
      fixIts: mismatch.rewrite.map {
        [DiagnosticFixIt(range: mismatch.range, replacement: $0, messageKey: "fixIt.separators")]
      } ?? [])
  }

  /// A reference to a line that shows only an AI display answer, which the
  /// engine cannot read, says so and how to make that answer a value.
  private func assistedReferenceDiagnostic(_ error: EngineError) -> FormattedDiagnostic? {
    guard error.code == .unavailableReference, case .failedLine(let number) = error.context,
      sheet.lines.indices.contains(number - 1),
      assistantAnswer(to: sheet.lines[number - 1].text) != nil
    else {
      return nil
    }
    let formatted = diagnosticFormatter.format(error)
    return FormattedDiagnostic(
      code: formatted.code, severity: formatted.severity, ranges: formatted.ranges,
      message: String(
        format: localized(
          "assistant.unreferenceable",
          "Line %lld has an AI display answer, which formulas cannot use. Change Answer… can save it into the sheet."
        ), number),
      fixIts: formatted.fixIts)
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
      guard let formatted = try? formatters(for: shown.text).full.format(value) else {
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
            : formatted.isRounded
              ? localized(
                "interpretation.exactRounded",
                "Exact; shown rounded by Format ▸ Number Format")
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
      guard let diagnostic = flaggedDiagnostic(result, text: shown.text, isEditing: false) else {
        return details
      }
      if let assisted = assistantAnswer(to: shown.text) {
        details += [
          AnswerCell.Detail(
            label: localized("interpretation.aiAnswer", "AI answer"), value: assisted),
          AnswerCell.Detail(
            label: localized("interpretation.aiAnswerUse", "Use"),
            value: localized(
              "interpretation.aiAnswerNote",
              "An unverified AI display answer. Formulas cannot refer to it; Change Answer… ▸ Save Value into Sheet makes a reviewed value they can use."
            )),
        ]
      }
      details += [
        AnswerCell.Detail(
          label: localized("interpretation.problem", "Problem"), value: diagnostic.message)
      ]
      // A table cell is where a failure that came from a table started.
      details += tableFailureOrigins(shown.result.failureOriginTableCells)
      for number in shown.result.failureOriginLineNumbers
      where sheet.lines.indices.contains(number - 1) && sheet.lines[number - 1].id != id {
        details.append(
          AnswerCell.Detail(
            label: localized("interpretation.errorOrigin", "Fix first"),
            value: String(format: localized("interpretation.errorLine", "Line %lld"), number),
            lineNumber: number))
      }
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

  /// "Fix first" rows that select each original failing table cell's source
  /// in the current text: its record, inherited rule or header, or the whole
  /// block for a table that could not be calculated. Origins whose table is
  /// gone are left out.
  private func tableFailureOrigins(_ origins: [TableCellFailureOrigin]) -> [AnswerCell.Detail] {
    origins.compactMap { origin in
      guard let utf8 = TableSourceDocument.sourceRange(of: origin, in: sheet),
        let range = utf16Range(forUTF8: utf8)
      else { return nil }
      let table = latestEvaluation?.tableResult(origin.table)
      let name =
        origin.column.flatMap { table?.address(row: origin.row, column: $0) } ?? table?.name
      return AnswerCell.Detail(
        label: localized("interpretation.errorOrigin", "Fix first"),
        value: name ?? localized("interpretation.errorTable", "Table"), sourceRange: range)
    }
  }

  /// A UTF-8 range of the current source as text view UTF-16 offsets.
  private func utf16Range(forUTF8 range: Range<Int>) -> NSRange? {
    let text = textView.string
    let utf8 = text.utf8
    guard
      let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound, limitedBy: utf8.endIndex),
      let upper = utf8.index(lower, offsetBy: range.count, limitedBy: utf8.endIndex)
    else { return nil }
    let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
    return NSRange(location: start, length: text.utf16.distance(from: lower, to: upper))
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
      isEditing: line.id == editingLine,
      lexingConfiguration: context.lexingConfiguration
    )
    guard decoration != decorations[line.id] || editedLines.contains(line.id) else {
      return
    }
    layoutManager.setRenderingAttributes([:], for: lineRange)
    let underlines = decoration.runs.compactMap { run in
      run.style.underlineColor.map { (range: run.range, color: $0) }
    }
    sheetTextView.underlines[line.id] = underlines.isEmpty ? nil : underlines
    // TextKit 2 throws on a rendering attribute for an empty text range. A
    // blank table block line has a zero-length comment run, so opening a
    // sheet with one crashed on first display.
    for run in decoration.runs where !run.style.attributes.isEmpty && run.range.length > 0 {
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

  /// Physical lines of table blocks, found by scanning line starts only.
  private func tableLines() -> IndexSet {
    if let cachedTableLines {
      return cachedTableLines
    }
    var lines = IndexSet()
    for range in TableSourceDocument.blockLineRanges(in: sheet) {
      lines.insert(integersIn: range)
    }
    cachedTableLines = lines
    return lines
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
    _ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue],
    replacementStrings: [String]?
  ) -> Bool {
    guard
      controller?.permitsInlineEdit(ranges.map(\.rangeValue), replacements: replacementStrings)
        != false
    else { return false }
    controller?.noteLineShift(replacing: ranges.map(\.rangeValue), with: replacementStrings)
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

extension SheetEditorViewController {
  fileprivate func permitsInlineEdit(_ ranges: [NSRange], replacements: [String]?) -> Bool {
    guard permitsInlineTables, !sourceCoordinator.isApplying, !isRewritingReferences,
      !documentUndoManager.isUndoing, !documentUndoManager.isRedoing
    else {
      return true
    }
    for (index, range) in ranges.enumerated() {
      for block in inlineTableRanges.values {
        if range.length == 0 {
          if range.location > block.location && range.location < block.upperBound { return false }
          if range.location == block.location, let replacements,
            replacements.indices.contains(index),
            !replacements[index].isEmpty, !replacements[index].hasSuffix("\n"),
            !replacements[index].hasSuffix("\r")
          {
            return false
          }
        } else if NSIntersectionRange(range, block).length > 0,
          !(range.location <= block.location && range.upperBound >= block.upperBound)
        {
          return false
        }
      }
    }
    return true
  }
  @objc public func inspectTableSource(_ sender: Any?) {
    returnFromTable(nil)
    guard expandedTable == nil, !textView.hasMarkedText() else { return }
    showsTableSource.toggle()
    resetInlineLayout()
    refreshInlineTables()
    textView.scrollRangeToVisible(textView.selectedRange())
  }
  package func resetInlineLayout() {
    guard let storage = textView.textStorage else { return }
    storage.addAttributes(
      [
        .font: VisualStyle.Typography.source(scale: sheetTextView.textScale),
        .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default,
      ], range: NSRange(location: 0, length: storage.length))
    for preview in inlineTableViews.values { preview.removeFromSuperview() }
    inlineTableViews = [:]
    inlineTableRanges = [:]
  }
  @objc public override func performTextFinderAction(_ sender: Any?) {
    returnFromTable(nil)
    guard expandedTable == nil else { return }
    view.window?.makeFirstResponder(textView)
    textView.performTextFinderAction(sender)
  }
  package func previewTableAtFindSelection() {
    guard !showsTableSource, !textView.hasMarkedText() else { return }
    let selection = textView.selectedRange()
    let document = TableSourceDocument(sheet)
    for (id, range) in inlineTableRanges
    where selection.length > 0 && selection.location >= range.location
      && selection.upperBound <= range.upperBound
    {
      let offset = (sheet.text as NSString).substring(to: selection.location).utf8.count
      guard let projection = TableEditingSnapshot(document, id: id),
        let position = projection.cell(atUTF8: offset, in: document)
      else { continue }
      inlineTableViews[id]?.revealFindMatch(position)
      return
    }
  }
  package func openTableAtFindSelection() {
    guard !showsTableSource, !textView.hasMarkedText() else { return }
    let selection = textView.selectedRange()
    let document = TableSourceDocument(sheet)
    for (id, range) in inlineTableRanges
    where selection.length > 0
      && selection.location >= range.location && selection.upperBound <= range.upperBound
    {
      guard let projection = TableEditingSnapshot(document, id: id) else { continue }
      let prefix = (sheet.text as NSString).substring(to: selection.location)
      let position = projection.cell(atUTF8: prefix.utf8.count, in: document)
      if expandedTable?.tableID != id { openTable(id) }
      if let position, expandedTable?.isEditingCell != true { expandedTable?.select(position) }
      return
    }
  }
  /// Printing shows values. Source inspection and source copy keep the block.
  /// Every table is its own block, with displayed values, units and failure
  /// messages exactly as the editor shows them.
  public func renderedBlocks() async -> [RenderedBlock] {
    let lines = await exportedLines()
    var output: [RenderedBlock] = []
    var prose: [ExportedLine] = []
    var index = 0
    let tables = latestEvaluation?.tableResults ?? []
    while index < lines.count {
      if let result = tables.first(where: { $0.physicalLines.lowerBound == index }) {
        if !prose.isEmpty {
          output.append(.lines(prose))
          prose = []
        }
        output.append(.table(renderedTable(result)))
        index = result.physicalLines.upperBound
      } else {
        prose.append(lines[index])
        index += 1
      }
    }
    if !prose.isEmpty {
      output.append(.lines(prose))
    }
    return output
  }

  /// One table as a renderer shows it: a quarantined block reports its
  /// diagnostics; a calculated table shows its values, totals and failures.
  private func renderedTable(_ result: TableResultSnapshot) -> RenderedTable {
    guard let id = result.id,
      let projection = TableEditingSnapshot(TableSourceDocument(sheet), id: id)
    else {
      return RenderedTable(
        name: nil, headers: [], rows: [], totals: [],
        failures: result.diagnostics.map { diagnosticFormatter.format($0).message })
    }
    let rows: [[RenderedTableCell]] = projection.rows.map { row in
      projection.columns.map { column in
        renderedCell(
          result.value(row: row, column: column.id), result: result, row: row,
          column: column.id)
      }
    }
    let totals: [RenderedTotal] = projection.columns.enumerated().compactMap {
      index, column in
      guard let total = column.total else { return nil }
      let value = result.aggregate(
        total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
      return RenderedTotal(
        columnIndex: index,
        label: column.header + " " + total.rawValue,
        text: value.flatMap { formatTableValue($0)?.display }
          ?? localized(
            "table.failure", "Error"))
    }
    return RenderedTable(
      name: projection.name, headers: projection.columns.map(\.header), rows: rows,
      totals: totals,
      failures: result.calculationFailure.map { [formatTableError($0)] } ?? [])
  }

  /// A cell as the renderer shows it: the display text, or the message that
  /// names the problem.
  private func renderedCell(
    _ value: TableCellValue?, result: TableResultSnapshot, row: RowID, column: ColumnID
  ) -> RenderedTableCell {
    switch value {
    case .value(let scalar):
      return RenderedTableCell(
        text: formatTableValue(scalar, column: column, result: result)?.display ?? "")
    case .text(let text): return RenderedTableCell(text: text)
    case .blank: return RenderedTableCell(text: "")
    case .failure:
      return RenderedTableCell(
        text: result.cellProblem(row: row, column: column) ?? result.cellError(
          row: row, column: column
        ).map { formatTableError($0) }
          ?? localized("table.failure", "Error"), isFailure: true)
    case nil:
      if let failure = result.calculationFailure {
        return RenderedTableCell(text: formatTableError(failure), isFailure: true)
      }
      return RenderedTableCell(text: localized("table.pending", "Pending…"))
    }
  }

  /// The sheet as flat lines for a reader that shows one line per row: a
  /// table becomes its name, headers, rows and spelled totals.
  public func printableLines() async -> [ExportedLine] {
    func line(_ text: String) -> ExportedLine { .init(source: text, answer: nil, status: .none) }
    var output: [ExportedLine] = []
    for block in await renderedBlocks() {
      switch block {
      case .lines(let lines):
        output += lines
      case .table(let table):
        if let name = table.name { output.append(line(name)) }
        output += table.failures.map(line)
        guard !table.headers.isEmpty else { continue }
        output.append(line(table.headers.joined(separator: " | ")))
        output += table.rows.map { row in
          line(row.map(\.text).joined(separator: " | "))
        }
        for total in table.totals {
          output.append(line(total.label + ": " + total.text))
        }
      }
    }
    return output
  }
  @objc public func insertCalculationTable(_ sender: Any?) {
    showTableCreation(pasted: nil)
  }
  @objc public func pasteAsCalculationTable(_ sender: Any?) {
    guard let text = resultPasteboard.string(forType: .string) else {
      NSSound.beep()
      return
    }
    showTableCreation(pasted: text)
  }
  @objc public func convertSelectionToCalculationTable(_ sender: Any?) {
    let range = textView.selectedRange()
    guard range.length > 0 else { return }
    showTableCreation(
      pasted: (textView.string as NSString).substring(with: range), replacing: range)
  }
  private func showTableCreation(pasted: String?, replacing: NSRange? = nil) {
    guard permitsTableEditing, textView.isEditable, expandedTable == nil,
      !textView.hasMarkedText(), let window = view.window
    else { return }
    let grid = pasted.map(TableSourceDocument.tabSeparated)
    if let grid,
      grid.isEmpty || grid[0].isEmpty || grid.count * grid[0].count > 4000
        || grid[0].count > 32 || !grid.allSatisfy({ $0.count == grid[0].count })
    {
      let alert = NSAlert()
      alert.messageText = "Use a rectangle with at most 32 columns and 4,000 cells."
      alert.beginSheetModal(for: window)
      return
    }
    let before = sheet.text
    let start =
      replacing?.location ?? (before as NSString).lineRange(for: textView.selectedRange()).location
    let offset = (before as NSString).substring(to: start).utf8.count
    guard !inlineTableRanges.values.contains(where: { NSLocationInRange(start, $0) }) else {
      return
    }
    let alert = NSAlert()
    alert.messageText =
      replacing != nil
      ? "Convert Selection to Table" : pasted == nil ? "Insert Table" : "Paste as Table"
    let form = TableCreationForm(pasted: grid)
    let names = Set(
      TableSourceDocument(sheet).editingTableIDs.compactMap {
        TableEditingSnapshot(TableSourceDocument(sheet), id: $0)?.name.lowercased()
      })
    var tableName = "Table"
    var suffix = 2
    while names.contains(tableName.lowercased()) {
      tableName = "Table\(suffix)"
      suffix += 1
    }
    form.name.stringValue = tableName
    alert.accessoryView = form
    alert.addButton(withTitle: pasted == nil ? "Insert" : "Paste as Table")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = form.name
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      do {
        let data = grid.map { form.headerRow.state == .on ? Array($0.dropFirst()) : $0 }
        let rowCount = data?.count ?? form.rows.integerValue
        guard rowCount > 0, rowCount * form.settings.count <= 4000 else {
          throw TableTransformError.invalidSelection
        }
        let id = try insertTableRectangle(
          named: form.name.stringValue, headers: form.settings, rows: data,
          formulas: form.formulas.state == .on, atUTF8: offset, expectedSource: before,
          rowCount: rowCount, replacing: replacing, columnRules: form.columnRules,
          percentageColumn: form.percentageColumn)
        if let id { openTable(id) }
      } catch { window.presentError(error) }
    }
  }
  /// Build the complete insert and paste before applying one document edit.
  @discardableResult
  package func insertTableRectangle(
    named name: String, headers: [(String, TableInputPolicy)], rows: [[String]]?,
    formulas: Bool, atUTF8 offset: Int, expectedSource: String, rowCount: Int = 3,
    replacing: NSRange? = nil, columnRules: [Int: String] = [:], percentageColumn: Int? = nil
  ) throws -> TableID? {
    guard expectedSource == sheet.text else { throw SheetSourceCoordinator.Failure.staleEdit }
    let base: String
    if let replacing {
      base = (expectedSource as NSString).replacingCharacters(in: replacing, with: "")
    } else {
      base = expectedSource
    }
    let create = try TableSourceDocument(base).createTable(
      name: name, headers: headers, rowCount: rows?.count ?? rowCount, atUTF8: offset)
    var after = try create.applying(to: base)
    if let rows, !rows.isEmpty, let id = create.createdTable {
      guard rows.allSatisfy({ $0.count == headers.count }), rows.count * headers.count <= 4000
      else {
        throw TableTransformError.invalidSelection
      }
      func quoted(_ input: String) -> String {
        "\"" + input.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
      let tsv = rows.map { $0.map(quoted).joined(separator: "\t") }.joined(separator: "\n")
      let paste = try TableSourceDocument(SheetSource(after)).pastePlainText(
        tsv, table: id, at: .init(row: 0, column: 0), formulas: formulas)
      after = try paste.applying(to: after)
    }
    if let id = create.createdTable,
      let projection = TableEditingSnapshot(TableSourceDocument(after), id: id)
    {
      for (index, rule) in columnRules.sorted(by: { $0.key < $1.key })
      where projection.columns.indices.contains(index) {
        let edit = try TableSourceDocument(after).setColumnRule(
          table: id, column: projection.columns[index].id, source: rule)
        after = try edit.applying(to: after)
      }
      if let index = percentageColumn, projection.columns.indices.contains(index) {
        let edit = try TableSourceDocument(after).setColumnPresentation(
          table: id, column: projection.columns[index].id, percentageDecimals: 0)
        after = try edit.applying(to: after)
      }
    }
    try replaceTableSource(
      before: expectedSource, after: after,
      action: replacing == nil ? "Insert Table" : "Convert Selection to Table")
    return create.createdTable
  }
  @objc public func openCalculationTable(_ sender: Any?) {
    guard permitsTableEditing else { return }
    let ids = TableSourceDocument(sheet).editingTableIDs
    if let id = latestEvaluation?.tableResult(
      atLine: lineIndex(atUTF16: textView.selectedRange().location))?.id, ids.contains(id)
    {
      openTable(id)
      return
    }
    if ids.count == 1 {
      openTable(ids[0])
      return
    }
    let menu = NSMenu()
    for id in ids {
      let item = NSMenuItem(
        title: TableEditingSnapshot(TableSourceDocument(sheet), id: id)?.name ?? "Table",
        action: #selector(openNamedTable(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = id
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 12, y: view.bounds.maxY - 12), in: view)
  }
  @objc private func openNamedTable(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? TableID { openTable(id) }
  }
  public func openTable(_ id: TableID) {
    guard !textView.hasMarkedText(), permitsTableEditing,
      TableEditingSnapshot(TableSourceDocument(sheet), id: id) != nil
    else { return }
    loadViewIfNeeded()
    if expandedTable != nil {
      returnFromTable(nil)
      guard expandedTable == nil else { return }
    }
    guard inlineTableViews.values.allSatisfy({ $0.commitPreviewEdit() }) else { return }
    proseScroll = scrollView.contentView.bounds.origin
    if textView.hasMarkedText() { textView.unmarkText() }
    let controller = ExpandedTableViewController(editor: self, table: id)
    expandedTable = controller
    controller.returnToSheet = { [weak self] in self?.returnFromTable(nil) }
    controller.navigateFailure = { [weak self] origin in self?.navigateToTableFailure(origin) }
    addChild(controller)
    controller.view.frame = view.bounds
    controller.view.autoresizingMask = [.width, .height]
    scrollView.isHidden = true
    summaryBar.isHidden = true
    view.addSubview(controller.view)
    if let saved = tableViewStates[id] {
      controller.select(saved.0)
      if let projection = controller.projection, !projection.rows.isEmpty,
        !projection.columns.isEmpty
      {
        controller.anchor = .init(
          row: min(saved.1.row, projection.rows.count - 1),
          column: min(saved.1.column, projection.columns.count - 1))
      }
      controller.scroll.contentView.scroll(to: saved.2)
    } else {
      controller.select(.init(row: 0, column: 0))
    }
    view.window?.makeFirstResponder(controller.grid)
  }
  @objc public func returnFromTable(_ sender: Any?) {
    guard let controller = expandedTable, controller.commitCellEditing() else { return }
    tableViewStates[controller.tableID] = (
      controller.position, controller.anchor, controller.scroll.contentView.bounds.origin
    )
    tableProjectionObservers[controller.observerID] = nil
    controller.stopReviewObservers()
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    expandedTable = nil
    scrollView.isHidden = false
    scrollView.contentView.scroll(to: proseScroll)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    summarizeSelection()
    view.window?.makeFirstResponder(textView)
  }
  private func navigateToTableFailure(_ origin: TableCellFailureOrigin) {
    guard expandedTable?.commitCellEditing() != false else { return }
    openTable(origin.table)
    guard let grid = expandedTable, let projection = grid.projection,
      let row = origin.row.flatMap({ projection.rows.firstIndex(of: $0) }),
      let column = origin.column.flatMap({ id in projection.columns.firstIndex { $0.id == id } })
    else { return }
    grid.select(.init(row: row, column: column))
  }
}
