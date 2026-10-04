import AppKit

struct Projection {
  let source: String
  let text: String
  let sourceBlock: NSRange
  let visibleBlock: NSRange

  init(_ source: String) throws {
    guard let block = Codec.blocks(source).first, let table = block.table else {
      throw SpikeFailure(message: "projection needs a valid block")
    }
    self.source = source
    sourceBlock = block.range
    func display(_ text: String) -> String {
      let firstLine = text.components(separatedBy: .newlines).first ?? ""
      return String(firstLine.prefix(18)).padding(toLength: 20, withPad: " ", startingAt: 0)
    }
    let headers = table.columns.map { display($0.name) }.joined()
    let rows = table.rows.map { row in
      table.columns.map { column in
        let cell = table.cells.first { $0.key.row == row && $0.key.column == column.id }
        let input = cell?.input ?? ""
        return display(input.isEmpty && cell?.override == true ? "(blank override)" : input)
      }.joined()
    }.joined(separator: "\n")
    let preview = "\n\(table.name) · Open Table\n" + headers + "\n" + rows + "\n\n"
    visibleBlock = NSRange(location: block.range.location, length: preview.utf16.count)
    text = (source as NSString).replacingCharacters(in: block.range, with: preview)
  }
  func canonicalRange(_ range: NSRange) -> NSRange {
    let delta = sourceBlock.length - visibleBlock.length
    func offset(_ value: Int, end: Bool) -> Int {
      if value <= visibleBlock.location { return value }
      if value >= NSMaxRange(visibleBlock) { return value + delta }
      return end ? NSMaxRange(sourceBlock) : sourceBlock.location
    }
    let lower = offset(range.location, end: false)
    let upper = offset(NSMaxRange(range), end: true)
    return NSRange(location: lower, length: upper - lower)
  }
}
// Read-only native inline projection. The answer divider skips the entire table.
@MainActor
final class PreviewTextView: NSTextView {
  var mapped: Projection?
  override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType)
    -> Bool
  {
    guard let mapped, type == .string || type.rawValue == "NSStringPboardType" else {
      return super.writeSelection(to: pasteboard, type: type)
    }
    let range = mapped.canonicalRange(selectedRange())
    return pasteboard.setString((mapped.source as NSString).substring(with: range), forType: type)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.separatorColor.setStroke()
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: bounds.width - 90, y: 0))
    divider.line(to: NSPoint(x: bounds.width - 90, y: 30))
    divider.move(to: NSPoint(x: bounds.width - 90, y: 205))
    divider.line(to: NSPoint(x: bounds.width - 90, y: bounds.height))
    divider.stroke()
  }
}
