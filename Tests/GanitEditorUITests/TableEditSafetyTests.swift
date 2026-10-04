import AppKit
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

@MainActor
@Suite(.serialized)
struct TableEditSafetyTests {
  @Test func escapeClearsSelectionAndDraft() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor()
    let before = editor.sheet.text
    controller.beginEditing(inline: true)
    controller.formula.stringValue = "999"
    controller.clearSelection()
    #expect(editor.sheet.text == before)
    #expect(!controller.hasCellSelection)
    #expect(!controller.isEditingCell)
    #expect(controller.selectionRows.isEmpty)
    #expect(controller.formula.stringValue.isEmpty)
    controller.refresh()
    #expect(!controller.hasCellSelection)
    controller.select(.init(row: 0, column: 1))
    #expect(controller.hasCellSelection)
    #expect(controller.formula.isEnabled)
  }

  @Test func tabAndReturnToSheetDiscardDraft() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor()
    let before = editor.sheet.text
    controller.beginEditing(inline: true)
    controller.formula.stringValue = "999"
    let field = try #require(controller.editingInput.currentEditor() as? NSTextView)
    #expect(
      controller.control(
        controller.editingInput, textView: field,
        doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(editor.sheet.text == before)
    #expect(controller.position.column == 1)
    controller.beginEditing()
    controller.formula.stringValue = "888"
    editor.returnFromTable(nil)
    #expect(editor.sheet.text == before)
    #expect(editor.expandedTable == nil)
    #expect(!editor.documentUndoManager.canUndo)
  }

  @Test func enterSavesAndUndoRedoUsesDocumentHistory() async throws {
    let (editor, _, controller) = try await ExpandedTableTests().makeEditor()
    let before = editor.sheet.text
    controller.beginEditing()
    controller.formula.stringValue = "123"
    let field = try #require(controller.editingInput.currentEditor() as? NSTextView)
    #expect(
      controller.control(
        controller.formula, textView: field,
        doCommandBy: #selector(NSResponder.insertNewline(_:))))
    let after = editor.sheet.text
    #expect(after != before)
    controller.undo(nil)
    #expect(editor.sheet.text == before)
    controller.redo(nil)
    #expect(editor.sheet.text == after)
  }

  @Test func inlineEscapeDiscardsDraftAndClearsSelection() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    let preview = try #require(editor.inlineTableViews[table.id])
    let before = editor.sheet.text
    preview.revealFindMatch(.init(row: 0, column: 0))
    preview.beginPreviewEdit()
    preview.cellInput.stringValue = "999"
    preview.cancelOperation(nil)
    #expect(editor.sheet.text == before)
    #expect(preview.selectedCell == nil)
    #expect(preview.cells.selected == nil)
    #expect(preview.cellInput.superview == nil)
    #expect(!editor.documentUndoManager.canUndo)
  }
}
