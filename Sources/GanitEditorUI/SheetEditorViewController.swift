import AppKit
import GanitEngine
import GanitFormatting

/// Hosts the sheet's source in a standard `NSTextView`.
///
/// The text view owns editing: selection, marked text and IME composition,
/// bidirectional layout, the responder chain, Find, and undo. The controller
/// mirrors committed text-storage edits into a `SheetSource` so stable line
/// identities follow the text, schedules evaluation once IME composition has
/// committed, and shows formatted answers beside the source.
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
  private var lineStarts: [Int: LineID]?
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
    sheetTextView.lineIDsByUTF16Start = { [unowned self] in lineIDsByUTF16Start() }
    scheduler = SheetEvaluationScheduler(context: context) { [weak self] evaluation in
      self?.show(evaluation)
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
    lineStarts = nil
  }

  fileprivate func textDidChange() {
    // Marked text is still being composed; evaluate once it commits.
    guard !textView.hasMarkedText() else {
      return
    }
    scheduler?.schedule(sheet)
  }

  private func show(_ evaluation: SheetEvaluation) {
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
  }

  private func lineIDsByUTF16Start() -> [Int: LineID] {
    if let lineStarts {
      return lineStarts
    }
    var starts: [Int: LineID] = [:]
    var offset = 0
    for line in sheet.lines {
      starts[offset] = line.id
      offset += line.text.utf16.count + (line.terminator?.rawValue.utf16.count ?? 0)
    }
    lineStarts = starts
    return starts
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

  func undoManager(for view: NSTextView) -> UndoManager? {
    controller?.documentUndoManager
  }
}
