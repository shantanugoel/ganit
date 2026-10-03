import AppKit
import GanitEngine

@MainActor
final class TableGridView: NSTableView {
  weak var controller: ExpandedTableViewController?
  override var acceptsFirstResponder: Bool { controller?.isEditingCell != true }
  override var undoManager: UndoManager? { controller?.editor.documentUndoManager }
  private func target(_ event: NSEvent) -> TableCellPosition? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    let column = column(at: point) - 1
    guard row >= 0, column >= 0 else { return nil }
    return .init(row: row, column: column)
  }
  override func mouseDown(with event: NSEvent) {
    guard let target = target(event), let controller else { return }
    if controller.isEditingCell {
      controller.pickReference(target)
      trackSelectionDrag()
      return
    }
    window?.makeFirstResponder(self)
    controller.select(target, extending: event.modifierFlags.contains(.shift))
    if event.clickCount == 2 { controller.beginEditing() } else { trackSelectionDrag() }
  }
  private func trackSelectionDrag() {
    while let event = window?.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
      dequeue: true)
    {
      if event.type == .leftMouseUp { return }
      mouseDragged(with: event)
    }
  }
  override func mouseDragged(with event: NSEvent) {
    if let target = target(event) {
      if controller?.isEditingCell == true {
        controller?.pickReference(target, dragging: true)
      } else {
        controller?.select(target, extending: true)
      }
    }
  }
  @objc func copy(_ sender: Any?) { controller?.copyValues() }
  @objc func paste(_ sender: Any?) { controller?.pasteCells() }
  @objc func undo(_ sender: Any?) { undoManager?.undo() }
  @objc func redo(_ sender: Any?) { undoManager?.redo() }
  override func keyDown(with event: NSEvent) {
    guard let controller else { return }
    var target = controller.position
    switch event.keyCode {
    case 123: target.column -= 1
    case 124: target.column += 1
    case 125: target.row += 1
    case 126: target.row -= 1
    case 48:
      target.column += event.modifierFlags.contains(.shift) ? -1 : 1
      let width = controller.projection?.columns.count ?? 0
      if target.column >= width {
        target.column = 0
        target.row += 1
      }
      if target.column < 0 {
        target.column = max(0, width - 1)
        target.row -= 1
      }
    case 36, 76:
      controller.beginEditing()
      return
    case 53:
      controller.cancelEditing()
      return
    default:
      if !event.modifierFlags.contains(.command), let text = event.characters, !text.isEmpty {
        controller.beginEditing()
        controller.formula.currentEditor()?.insertText(text)
      } else {
        super.keyDown(with: event)
      }
      return
    }
    controller.select(target, extending: event.modifierFlags.contains(.shift))
  }
}
