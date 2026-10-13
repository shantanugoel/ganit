import AppKit
import GanitEngine

/// A temporary review card. It never supplies an ordinary answer cell.
@MainActor
final class SuggestionCard: NSView {
  private let session: SheetSuggestionSession
  private weak var editor: SheetEditorViewController?
  private let scroll = NSScrollView()
  private let stack = NSStackView()
  private var actions: [() -> Void] = []
  private var popover: NSPopover?

  init(session: SheetSuggestionSession, editor: SheetEditorViewController) {
    self.session = session
    self.editor = editor
    super.init(frame: .zero)
    wantsLayer = true
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = stack
    addSubview(scroll)
    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
    setAccessibilityLabel(localized("suggestion.card", "Suggestion"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layout() {
    super.layout()
    scroll.frame = bounds
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    dirtyRect.fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  func refresh() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    actions = []
    label(localized("suggestion.card", "Suggestion"), bold: true)
    label(session.message)
    if let preview = session.preview {
      label(preview.candidate.edits.map(\.replacement).joined(separator: "\n"), mono: true)
      let result = editor?.formatTableValue(preview.result)?.display ?? ""
      label(localized("suggestion.calculated", "Calculated preview: ") + result, bold: true)
      label(preview.interpretation)
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
      for choice in question.choices {
        button(choice) { [weak self] in self?.session.submitClarification(choice) }
      }
      if let input = question.missingInput { label(input) }
      let field = NSTextField()
      field.placeholderString = "Supply a task constraint or missing input"
      field.setAccessibilityLabel("Clarification answer")
      stack.addArrangedSubview(field)
      button("Review New Request") { [weak self, weak field] in
        self?.session.submitClarification(field?.stringValue ?? "")
      }
    }
    if session.state == .needsContext {
      label("Additional source records", bold: true)
      for record in session.requestedContext {
        label(record.declaration?.text ?? record.name)
      }
      button("Include More Context") { [weak self] in self?.session.includeContext() }
    }
    let row = NSStackView()
    row.orientation = bounds.width < 500 ? .vertical : .horizontal
    row.spacing = 8
    if session.canSend { addButton("Send", to: row) { [weak self] in self?.session.send() } }
    if session.preview != nil {
      let apply = SuggestionApplyButton(
        title: localized("suggestion.use", "Use Expression"), target: self,
        action: #selector(run(_:)))
      apply.editor = editor
      apply.isEnabled = session.canApply
      register(apply) { [weak self] in self?.session.apply() }
      row.addArrangedSubview(apply)
      addButton("Show Working", to: row) { [weak self] in self?.showWorking() }
    }
    addButton("Edit Request", to: row) { [weak self] in self?.session.editRequest() }
    addButton("Context", to: row) { [weak self] in self?.showContext() }
    if [.failed, .stale, .cancelled].contains(session.state) {
      addButton("Retry", to: row) { [weak self] in self?.session.prepare(retry: true) }
    }
    addButton(session.isRunning ? "Stop" : "Dismiss", to: row) { [weak self] in
      self?.session.dismiss()
    }
    stack.addArrangedSubview(row)
    label("Return edits the sheet. Tab applies only when Use Expression has focus.")
    needsLayout = true
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

  private func addButton(_ title: String, to row: NSStackView, action: @escaping () -> Void) {
    let view = NSButton(title: title, target: self, action: #selector(run(_:)))
    view.bezelStyle = .rounded
    register(view, action: action)
    row.addArrangedSubview(view)
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
    let content = bodies.enumerated().map {
      "Request " + String($0.offset + 1) + "\n" + String(decoding: $0.element, as: UTF8.self)
    }.joined(separator: "\n\n")
    inspect(content.isEmpty ? "No request body is available." : content, title: "Context")
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
