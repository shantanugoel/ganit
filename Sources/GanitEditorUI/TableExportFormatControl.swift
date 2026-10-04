import AppKit
import UniformTypeIdentifiers

@MainActor
final class TableExportFormatControl: NSPopUpButton {
  weak var panel: NSSavePanel?
  let delimiter = NSTextField(labelWithString: "")
  var csvDelimiter = ","
  init(panel: NSSavePanel, delimiter: String) {
    self.panel = panel
    csvDelimiter = delimiter
    super.init(frame: .init(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
    addItems(withTitles: ["CSV", "TSV"])
    target = self
    action = #selector(changed)
    setAccessibilityLabel("File format")
    changed()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc func changed() {
    guard let panel else { return }
    let csv = indexOfSelectedItem == 0
    panel.allowedContentTypes = csv ? [.commaSeparatedText] : [.tabSeparatedText]
    let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
    panel.nameFieldStringValue = name + (csv ? ".csv" : ".tsv")
    delimiter.stringValue =
      csv ? "Delimiter: " + (csvDelimiter == ";" ? "semicolon" : "comma") : "Delimiter: tab"
  }
}
