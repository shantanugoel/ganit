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
    guard let controller else { return }
    let point = convert(event.locationInWindow, from: nil)
    if column(at: point) == 0, row(at: point) >= 0, controller.commitCellEditing() {
      controller.select(.init(row: row(at: point), column: 0))
      if let count = controller.projection?.columns.count, count > 0 {
        controller.select(.init(row: row(at: point), column: count - 1), extending: true)
      }
      return
    }
    guard let target = target(event) else { return }
    if controller.isEditingCell {
      if controller.formula.stringValue.trimmingCharacters(in: .whitespaces).hasPrefix("=")
        || controller.normalizedCellInput(controller.formula.stringValue).hasPrefix("=")
      {
        if !controller.formula.stringValue.hasPrefix("=") {
          controller.editingInput.stringValue = controller.normalizedCellInput(
            controller.formula.stringValue)
          controller.formula.stringValue = controller.editingInput.stringValue
        }
        controller.pickReference(target)
        trackSelectionDrag()
        return
      }
      guard controller.commitCellEditing() else { return }
    }
    window?.makeFirstResponder(self)
    controller.select(target, extending: event.modifierFlags.contains(.shift))
    if event.clickCount == 2 { controller.beginEditing(inline: true) } else { trackSelectionDrag() }
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
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let controller, controller.commitCellEditing() else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    let column = column(at: point) - 1
    guard row >= 0 else { return controller.actionsMenu() }
    if column < 0 {
      controller.select(.init(row: row, column: 0))
      if let count = controller.projection?.columns.count, count > 0 {
        controller.select(.init(row: row, column: count - 1), extending: true)
      }
      return controller.rowMenu()
    }
    let target = TableCellPosition(row: row, column: column)
    if !controller.rectangle.rows.contains(row) || !controller.rectangle.columns.contains(column) {
      controller.select(target)
    }
    return controller.cellMenu()
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self,
      event.modifierFlags.intersection([.command, .control, .option]) == .command
    {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "d":
        controller?.fillDown()
        return true
      case "r":
        controller?.fillRight()
        return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }
  @objc override func selectAll(_ sender: Any?) { controller?.selectAllCells(sender) }
  @objc func copy(_ sender: Any?) { controller?.copyFormulas() }
  @objc func paste(_ sender: Any?) { controller?.pasteCells() }
  @objc func undo(_ sender: Any?) { undoManager?.undo() }
  @objc func redo(_ sender: Any?) { undoManager?.redo() }
  override func keyDown(with event: NSEvent) {
    guard let controller else { return }
    var target = controller.position
    switch event.keyCode {
    case 51, 117:
      controller.clearCells()
      return
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
    case 36, 76, 120:
      controller.beginEditing(inline: true)
      return
    case 53:
      controller.cancelEditing()
      return
    default:
      if event.modifierFlags.intersection([.command, .control]).isEmpty,
        let text = event.characters,
        !text.isEmpty,
        text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      {
        controller.beginEditing(inline: true)
        controller.editingInput.currentEditor()?.insertText(text)
      } else {
        super.keyDown(with: event)
      }
      return
    }
    controller.select(
      target, extending: event.keyCode != 48 && event.modifierFlags.contains(.shift))
  }
}

@MainActor
final class TableGridHeaderView: NSTableHeaderView {
  weak var controller: ExpandedTableViewController?
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let controller, controller.commitCellEditing() else { return nil }
    let column = column(at: convert(event.locationInWindow, from: nil)) - 1
    guard column >= 0 else { return controller.actionsMenu() }
    controller.select(.init(row: 0, column: column))
    if let rows = controller.projection?.rows.count, rows > 0 {
      controller.select(.init(row: rows - 1, column: column), extending: true)
    } else {
      controller.position.column = column
    }
    return controller.columnMenu()
  }
  override func mouseDown(with event: NSEvent) {
    guard let controller else {
      super.mouseDown(with: event)
      return
    }
    let column = column(at: convert(event.locationInWindow, from: nil)) - 1
    guard column >= 0, controller.commitCellEditing() else { return }
    controller.select(.init(row: controller.position.row, column: column))
    if event.clickCount == 2 {
      controller.renameColumn()
      return
    }
    if let rows = controller.projection?.rows.count, rows > 0 {
      controller.select(.init(row: 0, column: column))
      controller.select(.init(row: rows - 1, column: column), extending: true)
    }
    super.mouseDown(with: event)
  }
}

@MainActor
final class TableGridCellView: NSTableCellView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.separatorColor.setStroke()
    let lines = NSBezierPath()
    lines.lineWidth = 1
    lines.move(to: .init(x: bounds.minX, y: bounds.minY + 0.5))
    lines.line(to: .init(x: bounds.maxX, y: bounds.minY + 0.5))
    lines.move(to: .init(x: bounds.maxX - 0.5, y: bounds.minY))
    lines.line(to: .init(x: bounds.maxX - 0.5, y: bounds.maxY))
    lines.stroke()
  }
}

@MainActor
final class TableGridRowView: NSTableRowView {
  override func drawBackground(in dirtyRect: NSRect) {
    backgroundColor.setFill()
    bounds.fill()
  }
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawSeparator(in dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: bounds.minY, width: bounds.width, height: 1).fill()
  }
}
