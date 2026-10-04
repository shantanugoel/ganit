import AppKit
import GanitEngine

@MainActor
final class TableGridView: NSTableView {
  weak var controller: ExpandedTableViewController?
  var frozenColumn: Int?
  override var acceptsFirstResponder: Bool { controller?.isEditingCell != true }
  override var undoManager: UndoManager? { controller?.editor.documentUndoManager }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    reloadData()
  }
  private func target(_ event: NSEvent) -> TableCellPosition? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    let column = column(at: point) - 1
    guard row >= 0, column >= 0 else { return nil }
    guard let canonical = controller?.canonicalRow(row) else { return nil }
    return .init(row: canonical, column: frozenColumn ?? column)
  }
  override func mouseDown(with event: NSEvent) {
    guard let controller else { return }
    let point = convert(event.locationInWindow, from: nil)
    if column(at: point) == 0, let row = controller.canonicalRow(row(at: point)),
      controller.commitCellEditing()
    {
      controller.select(.init(row: row, column: 0))
      if let count = controller.projection?.columns.count, count > 0 {
        controller.select(.init(row: row, column: count - 1), extending: true)
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
    guard let row = controller.canonicalRow(row(at: point)) else { return controller.actionsMenu() }
    let column = frozenColumn ?? (column(at: point) - 1)
    if column < 0 {
      controller.select(.init(row: row, column: 0))
      if let count = controller.projection?.columns.count, count > 0 {
        controller.select(.init(row: row, column: count - 1), extending: true)
      }
      return controller.rowMenu()
    }
    let target = TableCellPosition(row: row, column: column)
    if !controller.selectionRows.contains(row) || !controller.rectangle.columns.contains(column) {
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
    case 125:
      target.row =
        controller.canonicalRow((controller.visibleRow(target.row) ?? 0) + 1) ?? target.row
    case 126:
      target.row =
        controller.canonicalRow((controller.visibleRow(target.row) ?? 0) - 1) ?? target.row
    case 48:
      controller.moveAfterCommit(horizontal: true, backwards: event.modifierFlags.contains(.shift))
      return
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
  var frozenColumn: Int?
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let controller, controller.commitCellEditing() else { return nil }
    let column = frozenColumn ?? (column(at: convert(event.locationInWindow, from: nil)) - 1)
    guard column >= 0 else { return controller.actionsMenu() }
    controller.select(.init(row: controller.displayedRows.first ?? 0, column: column))
    if let rows = controller.projection?.rows.count, rows > 0 {
      controller.select(
        .init(row: controller.displayedRows.last ?? rows - 1, column: column), extending: true)
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
    let column = frozenColumn ?? (column(at: convert(event.locationInWindow, from: nil)) - 1)
    guard column >= 0, controller.commitCellEditing() else { return }
    controller.select(.init(row: controller.position.row, column: column))
    if event.clickCount == 2 {
      controller.renameColumn()
      return
    }
    if let rows = controller.projection?.rows.count, rows > 0 {
      controller.select(.init(row: controller.displayedRows.first ?? 0, column: column))
      controller.select(
        .init(row: controller.displayedRows.last ?? rows - 1, column: column), extending: true)
    }
    super.mouseDown(with: event)
  }
}

@MainActor
final class TableGridCellView: NSTableCellView {}

@MainActor
final class TableGridRowView: NSTableRowView {
  override func drawBackground(in dirtyRect: NSRect) {
    backgroundColor.setFill()
    bounds.fill()
  }
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawSeparator(in dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    let y = isFlipped ? bounds.maxY - 1 : bounds.minY
    NSRect(x: bounds.minX, y: y, width: bounds.width, height: 1).fill()
  }
}
