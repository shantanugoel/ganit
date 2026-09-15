import AppKit
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

  private let context: EvaluationContext
  private let scrollView = NSScrollView()
  private let sheetTextView = SheetTextView(usingTextLayoutManager: true)
  private let storageObserver = StorageObserver()
  private(set) var scheduler: SheetEvaluationScheduler?
  private var formattedAnswers: [LineID: (value: EngineValue, text: String)] = [:]
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
  /// The text as of the last mirrored edit, for converting UTF-16 edit
  /// ranges into the sheet's UTF-8 offsets.
  private var mirroredText: String

  public init(text: String = "", context: EvaluationContext) {
    self.context = context
    sheet = SheetSource(text)
    mirroredText = text
    super.init(nibName: nil, bundle: nil)

    configureTextView(text: text)
    storageObserver.controller = self
    textView.textStorage?.delegate = storageObserver
    textView.delegate = storageObserver
    sheetTextView.lineID = { [unowned self] offset in
      let index = lineIndex(atUTF16: offset)
      return utf16Starts()[index] == offset ? sheet.lines[index].id : nil
    }
    editingLine = sheet.lines.first?.id
    scheduler = SheetEvaluationScheduler(context: context) { [weak self] snapshot, evaluation in
      self?.show(evaluation, of: snapshot)
    }
    scheduler?.schedule(sheet)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    view = scrollView
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
    textView.font = .systemFont(ofSize: 14)
    textView.baseWritingDirection = .natural
    textView.textContainerInset = NSSize(width: 8, height: 8)
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
    // Undo and other programmatic edits do not send `textDidChange`.
    textDidChange()
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

  fileprivate func selectionDidChange() {
    let line = sheet.lines[lineIndex(atUTF16: textView.selectedRange().location)].id
    guard line != editingLine else {
      return
    }
    let previous = editingLine
    editingLine = line
    for index in sheet.lines.indices where [previous, line].contains(sheet.lines[index].id) {
      decorate(index)
    }
  }

  private func show(_ evaluation: SheetEvaluation, of snapshot: SheetSource) {
    let formatter = ResultFormatter(context: context)
    var answers: [LineID: (value: EngineValue, text: String)] = [:]
    for line in evaluation.lines {
      guard case .value(let value) = line.result else {
        continue
      }
      if let formatted = formattedAnswers[line.id], formatted.value == value {
        answers[line.id] = formatted
      } else if let text = try? formatter.format(value).display {
        answers[line.id] = (value, text)
      }
    }
    formattedAnswers = answers
    latestEvaluation = evaluation
    sheetTextView.answers = answers.mapValues(\.text)

    shownLines = Dictionary(
      uniqueKeysWithValues: zip(snapshot.lines, evaluation.lines).map {
        ($1.id, ($0.text, $1))
      }
    )
    decorations = decorations.filter { shownLines[$0.key] != nil }
    sheetTextView.underlines = sheetTextView.underlines.filter { shownLines[$0.key] != nil }
    for index in sheet.lines.indices {
      decorate(index)
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

  func textDidChange(_ notification: Notification) {
    controller?.textDidChange()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    controller?.selectionDidChange()
  }

  func undoManager(for view: NSTextView) -> UndoManager? {
    controller?.documentUndoManager
  }
}
