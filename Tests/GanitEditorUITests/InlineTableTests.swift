import AppKit
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

@MainActor
@Suite(.serialized)
struct InlineTableTests {
  func makeEditor() async throws -> (SheetEditorViewController, TableModel) {
    let (editor, table, _) = try await ExpandedTableTests().makeEditor()
    editor.returnFromTable(nil)
    editor.textView.textLayoutManager?.ensureLayout(
      for: editor.textView.textLayoutManager!.textContentManager!.documentRange)
    editor.textView.layoutSubtreeIfNeeded()
    editor.layoutInlineTables()
    return (editor, table)
  }
  @Test func previewMapsSourceAndReservesSpace() async throws {
    let (editor, table) = try await makeEditor()
    let preview = try #require(editor.inlineTableViews[table.id])
    let range = try #require(editor.inlineTableRanges[table.id])
    #expect(editor.textView.string == editor.sheet.text)
    #expect(!editor.sheet.text.contains("\u{fffc}"))
    #expect(preview.frame.height >= 180)
    let manager = try #require(editor.textView.textLayoutManager)
    let content = try #require(manager.textContentManager)
    let after = try #require(
      content.location(content.documentRange.location, offsetBy: range.upperBound))
    let frame = try #require(manager.textLayoutFragment(for: after)).layoutFragmentFrame
    #expect(frame.minY + editor.textView.textContainerOrigin.y >= preview.frame.maxY)
    #expect(preview.open.accessibilityLabel() == "Open Items table")
  }
  @Test func sourceCopyCrossesBothBoundaries() async throws {
    let (editor, _) = try await makeEditor()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.sheet.text.utf16.count))
    pasteboard.declareTypes(editor.textView.writablePasteboardTypes, owner: nil)
    #expect(
      editor.textView.writeSelection(to: pasteboard, types: editor.textView.writablePasteboardTypes)
    )
    let copied = pasteboard.string(forType: editor.textView.writablePasteboardTypes[0])
    #expect(copied?.utf8.elementsEqual(editor.sheet.text.utf8) == true)
  }
  @Test func rectangleInsertIsOneUndoAndPreservesProse() async throws {
    let (editor, _) = try await makeEditor()
    let before = editor.sheet.text
    let id = try #require(
      try editor.insertTableRectangle(
        named: "New", headers: [("Name", .text), ("Qty", .value)],
        rows: [["Café", "2"], ["שלום", "4"]], formulas: false, atUTF8: 0, expectedSource: before))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableResult(id)?.rows.count == 2)
    #expect(editor.sheet.text.hasSuffix(before))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text.utf8.elementsEqual(before.utf8))
    editor.documentUndoManager.redo()
    #expect(editor.inlineTableViews[id] != nil)
  }
  @Test func rejectedRectangleAndFormulaLeaveSourceUnchanged() async throws {
    let (editor, _) = try await makeEditor()
    let before = editor.sheet.text
    #expect(throws: TableTransformError.self) {
      try editor.insertTableRectangle(
        named: "New", headers: [("Qty", .value)],
        rows: [["=2+3"]], formulas: false, atUTF8: 0, expectedSource: before)
    }
    #expect(editor.sheet.text == before)
    #expect(throws: SheetSourceCoordinator.Failure.self) {
      try editor.insertTableRectangle(
        named: "New", headers: [("Qty", .value)],
        rows: [["1"]], formulas: false, atUTF8: 0, expectedSource: "old")
    }
  }
  @Test func findCellUsesSourceOffsetsAndReturnKeepsSelection() async throws {
    let (editor, table) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 2, column: 1), source: "=12345+1")
    await editor.scheduler?.waitUntilIdle()
    let match = (editor.sheet.text as NSString).range(of: "12345")
    // Native Find keeps its bar visible while it selects a source match.
    editor.scrollView.isFindBarVisible = true
    editor.textView.setSelectedRange(match)
    editor.openTableAtFindSelection()
    #expect(editor.expandedTable?.position == .init(row: 2, column: 1))
    editor.returnFromTable(nil)
    #expect(editor.textView.selectedRange() == match)
    #expect(editor.expandedTable == nil)
  }
  @Test func inspectionRestoresSourceLayout() async throws {
    let (editor, table) = try await makeEditor()
    let before = editor.sheet.text
    editor.inspectTableSource(nil)
    #expect(editor.showsTableSource)
    #expect(editor.inlineTableViews.isEmpty)
    #expect(editor.textView.string == before)
    editor.inspectTableSource(nil)
    #expect(!editor.showsTableSource)
    #expect(editor.inlineTableViews[table.id] != nil)
    #expect(editor.sheet.text == before)
  }
  @Test func markedProseDoesNotOpenTableOrRewriteSource() async throws {
    let (editor, table) = try await makeEditor()
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.documentUndoManager.beginUndoGrouping()
    defer { editor.documentUndoManager.endUndoGrouping() }
    editor.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: editor.textView.selectedRange())
    let before = editor.sheet.text
    editor.openTable(table.id)
    #expect(editor.expandedTable == nil)
    #expect(editor.textView.hasMarkedText())
    #expect(editor.sheet.text == before)
    editor.textView.unmarkText()
  }
  @Test func partialBlockEditsAreRejectedAndWholeBlockDeleteUndoes() async throws {
    let (editor, table) = try await makeEditor()
    let before = editor.sheet.text
    let block = try #require(editor.inlineTableRanges[table.id])
    editor.documentUndoManager.beginUndoGrouping()
    #expect(
      !editor.textView.shouldChangeText(
        in: NSRange(location: block.location + 8, length: 1), replacementString: "x"))
    #expect(editor.textView.shouldChangeText(in: block, replacementString: ""))
    editor.textView.textStorage?.replaceCharacters(in: block, with: "")
    editor.textView.didChangeText()
    #expect(editor.inlineTableViews[table.id] == nil)
    #expect(editor.sheet.text.hasPrefix("rate = 3\n"))
    editor.documentUndoManager.endUndoGrouping()
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    #expect(editor.inlineTableViews[table.id] != nil)
  }
  @Test func printUsesValuesAndSourceExportKeepsBlocks() async throws {
    let (editor, table) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "2")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=A2*3")
    try editor.setTableColumnTotal(table.id, column: table.columns[1].id, total: .sum)
    await editor.scheduler?.waitUntilIdle()
    let printed = await editor.printableLines().map(\.source).joined(separator: "\n")
    #expect(printed.contains("2 | 6"))
    #expect(printed.contains("Amount sum: 6"))
    #expect(!printed.contains("@ganit-table"))
    #expect(
      await editor.exportedLines().map(\.source).contains(where: { $0.contains("@ganit-table") }))
  }
  @Test func bothModesKeepPreviewAndFormulaSemantics() async throws {
    let (editor, table) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "2")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=A2*3")
    await editor.scheduler?.waitUntilIdle()
    let original = editor.sheet.text
    var display = editor.displayOptions
    display.writesAnswersInline = true
    editor.writeAnswers(display)
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.inlineTableViews[table.id] != nil)
    #expect(editor.sheet.text == original)
    if case .value(let scalar) = editor.latestEvaluation?.tableResult(table.id)?.value(
      row: table.rows[0], column: table.columns[1].id)
    {
      #expect(editor.formatTableValue(scalar)?.display == "6")
    } else {
      Issue.record("Missing table result")
    }
    if #available(macOS 15.0, *) { #expect(editor.textView.writingToolsBehavior == .none) }
  }
  @Test func previewShowsErrorsAndInspectionWithoutEditing() async throws {
    let (editor, table) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=1/0")
    await editor.scheduler?.waitUntilIdle()
    let preview = try #require(editor.inlineTableViews[table.id])
    let button = try #require(
      preview.cells.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 1 })
    let before = editor.sheet.text
    #expect(button.title == "Error")
    button.performClick(nil)
    #expect(preview.inspection.stringValue.contains("=1/0"))
    #expect(editor.sheet.text == before)
    preview.open.performClick(nil)
    #expect(editor.expandedTable?.position == .init(row: 0, column: 1))
  }
  @Test func partialCrossBoundaryCopyIncludesTheCompleteBlock() async throws {
    let (editor, table) = try await makeEditor()
    let block = try #require(editor.inlineTableRanges[table.id])
    let selected = NSRange(location: 0, length: block.location + 12)
    editor.textView.setSelectedRange(selected)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.declareTypes(editor.textView.writablePasteboardTypes, owner: nil)
    #expect(
      editor.textView.writeSelection(to: pasteboard, types: editor.textView.writablePasteboardTypes)
    )
    #expect(
      pasteboard.string(forType: editor.textView.writablePasteboardTypes[0])
        == (editor.sheet.text as NSString).substring(to: block.upperBound))
    #expect(editor.textView.selectedRange() == selected)
  }
  @Test func nativeFinderOpensCellsAndPreservesSource() async throws {
    let (editor, table) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 1, column: 1), source: "=7654321+1")
    await editor.scheduler?.waitUntilIdle()
    let before = editor.sheet.text
    let pasteboard = NSPasteboard(name: .find)
    let old = pasteboard.string(forType: .string)
    defer {
      pasteboard.clearContents()
      if let old { pasteboard.setString(old, forType: .string) }
    }
    pasteboard.clearContents()
    pasteboard.setString("7654321", forType: .string)
    // The find bar opens first, exactly like Command-F in the app, and the
    // field search action runs when its text changes.
    editor.scrollView.isFindBarVisible = true
    let menu = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
    menu.tag = NSTextFinder.Action.showFindInterface.rawValue
    editor.textView.performTextFinderAction(menu)
    // Typing in the native field runs its own search action.
    func firstSearchField(_ view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      for child in view.subviews { if let found = firstSearchField(child) { return found } }
      return nil
    }
    let searchField = editor.scrollView.findBarView.flatMap { firstSearchField($0) }
    #expect(searchField != nil)
    if let searchField {
      searchField.stringValue = "7654321"
      searchField.sendAction(searchField.action, to: searchField.target)
    }
    // The finder searches on a background queue and delivers matches on the
    // main queue, so yield before asking for the next match.
    try await Task.sleep(nanoseconds: 200_000_000)
    menu.tag = NSTextFinder.Action.nextMatch.rawValue
    editor.textView.performTextFinderAction(menu)
    // Match selection and grid mapping arrive on a later main-queue turn.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(editor.expandedTable?.position == .init(row: 1, column: 1))
    #expect(editor.sheet.text == before)
  }
  @Test func narrowScaledPreviewExposesNativeControls() async throws {
    let (editor, table) = try await makeEditor()
    let text = try #require(editor.textView as? SheetTextView)
    text.setFrameSize(NSSize(width: 340, height: 450))
    let preview = try #require(editor.inlineTableViews[table.id])
    editor.layoutInlineTables()
    preview.layoutSubtreeIfNeeded()
    let standard = preview.reservedHeight
    text.increaseTextSize(nil)
    text.increaseTextSize(nil)
    editor.layoutInlineTables()
    preview.layoutSubtreeIfNeeded()
    #expect(preview.reservedHeight > standard)
    #expect(preview.scroll.frame.width <= preview.frame.width)
    #expect(preview.cells.frame.width >= preview.scroll.frame.width)
    #expect((text.accessibilityChildren() ?? []).contains { ($0 as? NSButton) === preview.open })
    #expect(preview.open.accessibilityRole() == .button)
  }
  @Test func proseCompositionUndoKeepsTheTableAndItsLayout() async throws {
    let (editor, table) = try await makeEditor()
    let before = editor.sheet.text
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: editor.textView.selectedRange())
    editor.textView.insertText("日本語", replacementRange: editor.textView.markedRange())
    editor.documentUndoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.sheet.text.hasPrefix("日本語"))
    #expect(editor.inlineTableViews[table.id] != nil)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
    #expect(editor.inlineTableViews[table.id] != nil)
  }

}
