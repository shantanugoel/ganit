import AppKit

@MainActor
final class TableRuleForm: NSView, NSTextFieldDelegate {
  let field: NSTextField
  let sample = NSTextField(wrappingLabelWithString: "")
  let check: (String) -> (Bool, String)
  private let references = NSPopUpButton()
  private var choices: [(String, String)] = []
  private var cursor: NSRange?
  weak var applyButton: NSButton?
  init(
    source: String, help: String, choices: [(String, String)],
    check: @escaping (String) -> (Bool, String)
  ) {
    self.check = check
    self.choices = choices
    field = NSTextField(string: source)
    super.init(frame: .init(x: 0, y: 0, width: 420, height: 224))
    let hint = NSTextField(wrappingLabelWithString: help)
    hint.frame = .init(x: 0, y: 156, width: 420, height: 64)
    field.frame = .init(x: 0, y: 76, width: 420, height: 44)
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.delegate = self
    field.setAccessibilityLabel("Column formula")
    sample.frame = .init(x: 0, y: 0, width: 420, height: 72)
    sample.setAccessibilityLabel("Formula sample and problem")
    references.addItems(
      withTitles: ["Insert row reference or note definition…"] + choices.map { $0.0 })
    references.frame = .init(x: 0, y: 122, width: 420, height: 28)
    references.target = self
    references.action = #selector(insertReference)
    references.setAccessibilityLabel("Insert formula reference")
    addSubview(references)
    addSubview(hint)
    addSubview(field)
    addSubview(sample)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc private func insertReference() {
    let index = references.indexOfSelectedItem - 1
    guard choices.indices.contains(index) else { return }
    window?.makeFirstResponder(field)
    if let editor = field.currentEditor() as? NSTextView {
      if let cursor, cursor.upperBound <= editor.string.utf16.count {
        editor.setSelectedRange(cursor)
      }
      editor.insertText(choices[index].1, replacementRange: editor.selectedRange())
      field.stringValue = editor.string
      cursor = editor.selectedRange()
    } else {
      field.stringValue += choices[index].1
    }
    references.selectItem(at: 0)
    validate()
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    cursor = (field.currentEditor() as? NSTextView)?.selectedRange()
  }
  func validate() {
    let (valid, message) = check(field.stringValue)
    sample.stringValue = message
    sample.textColor = valid ? .secondaryLabelColor : .systemRed
    applyButton?.isEnabled = valid
  }
  func controlTextDidChange(_ notification: Notification) { validate() }
}
