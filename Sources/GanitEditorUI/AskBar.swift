import AppKit
import GanitEngine

/// ⏎ in the field asks; Esc closes the bar before it can reach the editor.
extension AskBar: NSTextFieldDelegate {
  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)):
      session.dismiss()
      return true
    case #selector(NSResponder.insertNewline(_:)):
      submitInstruction()
      return true
    default:
      return false
    }
  }
}

/// The Ask bar: one field, one status line, and the proposal Ganit checked.
/// It never supplies an ordinary answer cell, and only Apply touches the source.
@MainActor
final class AskBar: NSView {
  private let session: SheetSuggestionSession
  private weak var editor: SheetEditorViewController?
  private let scroll = NSScrollView()
  private let stack = NSStackView()
  private let instructionField = NSTextField()
  private var actions: [() -> Void] = []
  private var popover: NSPopover?
  private var displayedClarification: Int?

  init(session: SheetSuggestionSession, editor: SheetEditorViewController) {
    self.session = session
    self.editor = editor
    super.init(frame: .zero)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = stack
    addSubview(scroll)
    addSubview(instructionField)
    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
    setAccessibilityLabel(localized("ask.bar", "Ask"))
    instructionField.placeholderString =
      localized("ask.placeholder", "Ask Ganit about these lines…")
    instructionField.setAccessibilityLabel(localized("ask.field", "What to ask Ganit"))
    instructionField.target = self
    instructionField.action = #selector(submitInstruction)
    instructionField.delegate = self
  }

  @objc private func submitInstruction() {
    if session.clarification != nil {
      session.submitClarification(instructionField.stringValue, autoSend: true)
      return
    }
    if session.canSend && instructionField.stringValue == session.instruction {
      session.send()
      return
    }
    session.prepare(instruction: instructionField.stringValue, autoSend: true)
  }

  /// ⌘↩ applies the proposal Ganit checked, and only while the bar is up with an
  /// applicable one; otherwise the key goes on to Copy Result as usual.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard session.isVisible, session.canApply,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "\r"
    else { return false }
    session.apply()
    return true
  }

  /// Puts the caret in the field when the bar opens, so words can be typed at
  /// once. Reports whether the window took it, which the tests need: a window
  /// that has never been key refuses a field editor.
  @discardableResult
  func focusField() -> Bool {
    guard let window = editor?.view.window else { return false }
    return window.makeFirstResponder(instructionField)
  }

  /// The field is the entry point, so it stays on screen for the whole Ask; it
  /// only stops accepting typing while a request is in flight.
  private var canSubmitInstruction: Bool {
    session.isVisible && !session.isRunning
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layout() {
    super.layout()
    // The field is the bar's fixed header, laid out by hand so that rebuilding
    // the scrolling body never touches it: removing and re-adding the field would
    // resign its first responder and drop the caret the reader is typing into.
    let height = instructionField.intrinsicContentSize.height
    let inset = instructionField.isHidden ? 0 : height + VisualStyle.Spacing.related
    instructionField.frame = NSRect(
      x: VisualStyle.Spacing.standard,
      y: bounds.maxY - VisualStyle.Spacing.compact - height,
      width: max(0, bounds.width - 2 * VisualStyle.Spacing.standard), height: height)
    scroll.frame = NSRect(
      x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - inset))
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    // AppKit can request drawing outside the bounds. Keep the background
    // inside the bar so that it cannot cover the sheet above it.
    bounds.intersection(dirtyRect).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  func clear() {
    popover?.close()
    popover = nil
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    actions = []
    isHidden = true
  }

  func refresh() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    actions = []
    instructionField.isHidden = !session.isVisible
    // The field is never disabled: a disabled control resigns first responder,
    // and the caret would leave the bar the reader just opened. Editing the
    // words while a request is in flight only changes what the next send carries.
    var focusQuestion = false
    if let question = session.clarification {
      if displayedClarification != session.clarificationCount {
        instructionField.stringValue = ""
        focusQuestion = true
      }
      displayedClarification = session.clarificationCount
      instructionField.placeholderString = question.question
      instructionField.setAccessibilityLabel(question.question)
    } else {
      if displayedClarification != nil { instructionField.stringValue = session.instruction }
      displayedClarification = nil
      instructionField.placeholderString = localized(
        "ask.placeholder", "Ask Ganit about these lines…")
      instructionField.setAccessibilityLabel(localized("ask.field", "What to ask Ganit"))
    }
    label(session.message)
    if let notice = session.repairNotice { label(notice) }
    if !session.nativeFunctionAlternatives.isEmpty {
      label(
        String(
          format: localized("ask.failure.nativeFunctions", "Ganit has these functions: %1$@."),
          session.nativeFunctionAlternatives.joined(separator: ", ")))
    }
    for (index, line) in session.proposalLines.enumerated() {
      let control = NSButton(
        checkboxWithTitle: line, target: self, action: #selector(run(_:)))
      control.state = session.omittedLines.contains(index) ? .off : .on
      control.setAccessibilityLabel(
        String(
          format: localized("ask.includeProposedLine", "Include proposed line %1$d: %2$@"),
          index + 1, line))
      control.isEnabled = !session.isRunning
      register(control) { [weak self, weak control] in
        self?.session.includeLine(index, included: control?.state == .on)
      }
      stack.addArrangedSubview(control)
    }
    if let preview = session.preview {
      for row in session.checkedLines {
        let answer = row.result.flatMap { editor?.formatTableValue($0)?.display }
        label(row.source + (answer.map { " = " + $0 } ?? ""), mono: true)
      }
      let result = editor?.formatTableValue(preview.result)?.display ?? ""
      label(localized("ask.calculated", "Ganit calculated: ") + result, bold: true)
      label(preview.interpretation)
      if session.automaticRepairs > 0 { label(session.checkedFooter) }
      if !preview.changedResults.isEmpty {
        label(String(preview.changedResults.count) + " downstream results change.")
      }
      if preview.readsClock { label("This expression uses the calculation clock.") }
      if !preview.rateUses.isEmpty {
        label("This expression uses frozen exchange rates. Review Show Working.")
      }
      let sources = preview.referencedLineIDs.compactMap { id in
        editor?.sheet.lines.first { $0.id == id }
      }
      for source in sources {
        button("Uses: " + source.text) { [weak self] in self?.focus(source.id) }
      }
      for choice in session.availableChoices {
        label(choice.question, bold: true)
        for option in choice.options {
          button((session.choices[choice.id] == option.id ? "Selected: " : "") + option.title) {
            [weak self] in self?.session.choose(choice.id, option: option.id)
          }
        }
      }
      for assumption in preview.candidate.assumptions {
        if assumption.id == preview.candidate.assumptions.first?.id {
          // The reader is about to be asked to trust a number Ganit found. Say
          // why this one was assumed and a tax rate was not (plan §6).
          label(
            localized(
              "ask.assumeOrAsk",
              "Ganit asks when only you know; it assumes and marks when the world knows."))
        }
        let button = NSButton(
          checkboxWithTitle: assumption.text, target: self, action: #selector(run(_:)))
        button.state = session.assumptions.contains(assumption.id) ? .on : .off
        register(button) { [weak self, weak button] in
          self?.session.approve(assumption.id, approved: button?.state == .on)
        }
        stack.addArrangedSubview(button)
      }
      if session.proposals.count > 1 {
        for (index, proposal) in session.proposals.enumerated() {
          button("Review: " + proposal.candidate.summary) { [weak self] in
            self?.session.selectProposal(index)
          }
        }
      }
    }
    if let question = session.clarification {
      button("‹ " + session.originalWording) { [weak self] in
        guard let self else { return }
        let wording = self.session.originalWording
        self.session.rephraseClarification()
        self.instructionField.stringValue = wording
        _ = self.focusField()
        self.instructionField.selectText(nil)
      }
      label(
        String(
          format: localized("ask.questionCount", "Question %1$d of 2 · Esc cancels the whole Ask"),
          session.clarificationCount))
      for choice in question.choices {
        button(choice) { [weak self] in
          self?.session.submitClarification(choice, autoSend: true)
        }
      }
      if let input = question.missingInput { label(input) }
    }
    if session.state == .needsContext {
      label("Additional source records", bold: true)
      for record in session.requestedContext {
        label(record.sourceText ?? record.name)
      }
      button("Include More Context") { [weak self] in self?.session.includeContext() }
    }
    let row = AskActionRow()
    if canSubmitInstruction {
      addButton(
        session.clarification == nil
          ? localized("ask.send", "Ask") : localized("ask.answer", "Answer"), to: row
      ) { [weak self] in
        self?.submitInstruction()
      }
    }
    if session.preview != nil {
      let apply = SuggestionApplyButton(
        title: localized("ask.apply", "Apply") + " ⌘↩", target: self,
        action: #selector(run(_:)))
      apply.editor = editor
      apply.isEnabled = session.canApply
      register(apply) { [weak self] in self?.session.apply() }
      row.addButton(apply)
      addButton("Show Working", to: row) { [weak self] in self?.showWorking() }
    }
    if session.state == .failed {
      addButton(localized("ask.editWords", "Edit words"), to: row) { [weak self] in
        guard let self else { return }
        _ = self.focusField()
        self.instructionField.selectText(nil)
      }
      if session.rejectedInspection != nil {
        addButton(localized("ask.showRejected", "Show what the model meant"), to: row) {
          [weak self] in
          guard let self, let text = self.session.rejectedInspection else { return }
          self.inspect(text, title: localized("ask.rejectedSource", "Rejected model reply"))
        }
      }
    } else if session.clarification == nil {
      addButton("Edit Request", to: row) { [weak self] in self?.session.editRequest() }
    }
    addButton(localized("ask.context", "Context ▸"), to: row) { [weak self] in self?.showContext() }
    if [.failed, .stale, .cancelled].contains(session.state) {
      addButton(localized("ask.retry", "Retry"), to: row) { [weak self] in
        self?.session.prepare(
          retry: true, instruction: self?.session.instruction ?? "", autoSend: true)
      }
    }
    addButton(
      session.clarification != nil
        ? localized("ask.cancel", "Cancel")
        : session.isRunning ? "Stop" : "Dismiss", to: row
    ) { [weak self] in
      self?.session.dismiss()
    }
    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    label(localized("ask.keys", "⏎ asks. ⌘↩ applies when Apply has focus. Esc closes."))
    // A hidden view cannot take the caret, and refresh() is what puts the field
    // on screen, so unhiding belongs here and not only in the editor's layout.
    isHidden = false
    needsLayout = true
    if focusQuestion { _ = focusField() }
  }

  private func label(_ text: String, bold: Bool = false, mono: Bool = false) {
    let field = NSTextField(wrappingLabelWithString: text)
    field.isSelectable = true
    field.font =
      mono
      ? .monospacedSystemFont(ofSize: 12, weight: .regular)
      : bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
    stack.addArrangedSubview(field)
    field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32).isActive =
      true
  }

  private func button(_ title: String, action: @escaping () -> Void) {
    let view = NSButton(title: title, target: self, action: #selector(run(_:)))
    register(view, action: action)
    stack.addArrangedSubview(view)
  }

  private func addButton(_ title: String, to row: AskActionRow, action: @escaping () -> Void) {
    let view = NSButton(title: title, target: self, action: #selector(run(_:)))
    view.bezelStyle = .rounded
    register(view, action: action)
    row.addButton(view)
  }

  private func register(_ button: NSButton, action: @escaping () -> Void) {
    button.tag = actions.count
    actions.append(action)
  }

  @objc private func run(_ sender: NSButton) {
    guard actions.indices.contains(sender.tag) else { return }
    actions[sender.tag]()
  }

  private func focus(_ id: LineID) {
    guard let editor, let line = editor.sheet.lines.first(where: { $0.id == id }) else { return }
    let text = editor.sheet.text
    let lower = text.utf8.index(text.utf8.startIndex, offsetBy: line.range.lowerBound)
    let upper = text.utf8.index(text.utf8.startIndex, offsetBy: line.range.upperBound)
    editor.textView.setSelectedRange(NSRange(lower..<upper, in: text))
    editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
  }

  private func showContext() {
    let bodies = session.preparedBody.map { [$0] } ?? session.requestBodies
    let content = bodies.enumerated().map { index, body in
      (bodies.count > 1 ? "Request \(index + 1)\n" : "")
        + Self.contextDisclosure(for: body)
    }.joined(separator: "\n\n")
    inspect(
      content.isEmpty ? localized("ask.noContext", "Nothing has been prepared to send.") : content,
      title: localized("ask.context", "Context ▸"))
  }

  /// The exact bytes, for the person who wants to check the claim rather than
  /// trust the summary.
  static func contextJSON(_ body: Data) -> String {
    String(decoding: body, as: UTF8.self)
  }

  static func contextDisclosure(for body: Data) -> String {
    guard let summary = contextSummary(for: body) else { return contextJSON(body) }
    return summary + "\n\n"
      + localized("ask.context.bytes", "Exact request bytes") + "\n" + contextJSON(body)
  }

  /// The disclosure the plan's rule 4 requires: what leaves the Mac, in words a
  /// reader can check against their own sheet. `nil` when the body is not a
  /// request Ganit built, and the raw JSON stands in.
  static func contextSummary(for body: Data) -> String? {
    guard
      let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let messages = payload["messages"] as? [[String: Any]],
      let contextText = messages.last?["content"] as? String,
      let contextData = contextText.data(using: .utf8),
      let context = try? JSONSerialization.jsonObject(with: contextData)
        as? [String: Any]
    else { return nil }
    // `target` and `settings` are objects and the rest are arrays, so the one
    // cast that would have been convenient is the one that is wrong.
    func array(_ key: String) -> [[String: Any]] { (context[key] as? [[String: Any]]) ?? [] }
    var sections: [String] = []
    func section(_ title: String, _ lines: [String]) {
      guard !lines.isEmpty else { return }
      sections.append(title + "\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }
    let target = context["target"] as? [String: Any]
    section(
      localized("ask.context.target", "Lines you asked about"),
      ((target?["source"] as? String) ?? "").split(
        separator: "\n", omittingEmptySubsequences: false
      ).map(String.init))
    let notes = array("notes").compactMap { $0["source"] as? String }
    section(
      localized("ask.context.words", "The words you typed"),
      notes.filter { $0.hasPrefix("// Task:") }.map { String($0.dropFirst("// Task:".count)) })
    section(
      localized("ask.context.notes", "Notes attached to those lines"),
      notes.filter { !$0.hasPrefix("// Task:") })
    section(
      localized("ask.context.symbols", "Source records Ganit matched"),
      array("symbols").compactMap { symbol in
        guard let name = symbol["name"] as? String else { return nil }
        let source = symbol["source"] as? String
        return source == nil ? name : "\(name) — \(source!)"
      })
    section(
      localized("ask.context.dependencies", "Lines these calculations read"),
      array("dependencySources").compactMap { $0["source"] as? String })
    let definitions = array("symbols").flatMap { symbol -> [[String: Any]] in
      let function = symbol["function"] as? [String: Any]
      return function?["definitions"] as? [[String: Any]] ?? []
    }
    section(
      localized("ask.context.functions", "Function definitions and their inputs"),
      definitions.flatMap { definition -> [String] in
        let captures = definition["captures"] as? [[String: Any]] ?? []
        return [definition["source"] as? String].compactMap { $0 }
          + captures.compactMap { $0["source"] as? String }
      })
    if let settings = context["settings"] as? [String: Any] {
      let keys = ["locale", "precision", "rounding", "now", "dollarCurrency", "markdown"]
      section(
        localized("ask.context.settings", "Calculation settings"),
        keys.compactMap { key in
          settings[key].map { "\(key): \(String(describing: $0))" }
        })
    }
    var provider: [String] = []
    if let model = payload["model"] as? String {
      provider.append(
        localized("ask.context.model", "Model") + ": " + model)
    }
    if let effort = payload["reasoning_effort"] as? String {
      provider.append(
        localized("ask.context.effort", "Effort") + ": " + effort)
    }
    section(localized("ask.context.provider", "Where it goes"), provider)
    return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
  }

  private func showWorking() {
    guard let preview = session.preview else { return }
    var text = "Before\n" + preview.sourceBefore + "\n\nProposed source\n" + preview.sourceAfter
    text += "\n\nInterpretation\n" + preview.interpretation
    text += "\n\nAssumptions\n" + preview.candidate.assumptions.map(\.text).joined(separator: "\n")
    inspect(text, title: "Show Working")
  }

  private func inspect(_ text: String, title: String) {
    let controller = NSViewController()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
    scroll.hasVerticalScroller = true
    let view = NSTextView(frame: scroll.contentView.bounds)
    view.string = text
    view.isEditable = false
    view.isSelectable = true
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.setAccessibilityLabel(title)
    scroll.documentView = view
    controller.view = scroll
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = controller
    self.popover?.close()
    self.popover = popover
    popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
  }
}

/// Keep actions on one row when they fit. Move excess buttons to the next row.
@MainActor
final class AskActionRow: NSView {
  private let spacing: CGFloat = 8

  override var isFlipped: Bool { true }

  func addButton(_ button: NSButton) {
    addSubview(button)
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: buttonFrames().map(\.maxY).max() ?? 0)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = frame.width != newSize.width
    super.setFrameSize(newSize)
    if widthChanged {
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }

  override func layout() {
    super.layout()
    for (button, frame) in zip(subviews, buttonFrames()) {
      button.frame = frame
    }
  }

  private func buttonFrames() -> [NSRect] {
    let width = bounds.width > 0 ? bounds.width : CGFloat.greatestFiniteMagnitude
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    return subviews.map { button in
      let size = button.fittingSize
      let buttonWidth = min(size.width, width)
      if x > 0 && x + buttonWidth > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      let frame = NSRect(x: x, y: y, width: buttonWidth, height: size.height)
      x += buttonWidth + spacing
      rowHeight = max(rowHeight, size.height)
      return frame
    }
  }
}

@MainActor
private final class SuggestionApplyButton: NSButton {
  weak var editor: SheetEditorViewController?
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { scrollToVisible(bounds) }
    return accepted
  }
  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == "\t", isEnabled {
      performClick(nil)
      return
    }
    if event.charactersIgnoringModifiers == "\r" {
      editor?.view.window?.makeFirstResponder(editor?.textView)
      editor?.textView.insertNewline(nil)
      return
    }
    super.keyDown(with: event)
  }
}
