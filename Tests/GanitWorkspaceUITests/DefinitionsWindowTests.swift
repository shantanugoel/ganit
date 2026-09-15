import AppKit
import Foundation
import GanitDocuments
import GanitEngine
import Testing

@testable import GanitEditorUI
@testable import GanitWorkspaceUI

@MainActor
@Suite
struct DefinitionsWindowTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitDefinitionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func opensEverySheetWithTheStoredDefinitions() async throws {
    let store = TextDocumentStore(url: root.appending(path: "Definitions.txt"))
    try store.save("hourly rate = 90\n1 bag = 25 kg")
    let library = try SheetLibrary(root: root)
    let id = try library.save(
      source: "hourly rate * 4\n2 bags in kg",
      metadata: library.create(preferences: .standard)
    ).id
    let workspace = try Workspace(library: library, definitions: store)
    defer { close(workspace) }

    #expect(workspace.definitions.variables.keys.sorted() == ["hourly rate"])
    let editor = try #require(workspace.openWindow(showing: id).editor)
    await editor.scheduler?.waitUntilIdle()
    let ids = editor.sheet.lines.map(\.id)

    #expect(answer(editor, ids[0]) == "360")
    #expect(answer(editor, ids[1]) == "50 kg")
  }

  @Test
  func editingDefinitionsReanswersOpenSheetsAndSavesOnClose() async throws {
    let store = TextDocumentStore(url: root.appending(path: "Definitions.txt"))
    let library = try SheetLibrary(root: root)
    let id = try library.save(
      source: "discount * 200", metadata: library.create(preferences: .standard)
    ).id
    let workspace = try Workspace(library: library, definitions: store)
    defer { close(workspace) }
    let sheet = try #require(workspace.openWindow(showing: id).editor)
    await sheet.scheduler?.waitUntilIdle()
    #expect(answer(sheet, try #require(sheet.sheet.lines.first?.id))?.isEmpty == false)

    try workspace.openDefinitions()
    let definitions = try #require(workspace.definitionsWindow?.editor)
    definitions.textView.insertText(
      "discount = 0.75", replacementRange: NSRange(location: 0, length: 0))
    await definitions.scheduler?.waitUntilIdle()
    await sheet.scheduler?.waitUntilIdle()

    // The decimal keeps its scale, as it would in the sheet that declared it.
    #expect(answer(sheet, try #require(sheet.sheet.lines.first?.id)) == "150.00")

    workspace.definitionsWindow?.window?.performClose(nil)
    #expect(store.load() == "discount = 0.75")
  }

  @Test
  func isAStandardWindowSeparateFromTheLibrary() throws {
    let store = TextDocumentStore(url: root.appending(path: "Definitions.txt"))
    let workspace = try Workspace(library: try SheetLibrary(root: root), definitions: store)
    defer { close(workspace) }

    try workspace.openDefinitions()
    let window = try #require(workspace.definitionsWindow?.window)

    #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
    #expect(window.title == "Definitions")
    #expect(window.contentViewController is SheetEditorViewController)
    #expect(try workspace.library.index.summaries().isEmpty)
  }

  private func answer(_ editor: SheetEditorViewController, _ id: LineID) -> String? {
    (editor.textView as? SheetTextView)?.answer(id).map(\.text)
  }

  private func close(_ workspace: Workspace) {
    for controller in workspace.windows {
      controller.window?.orderOut(nil)
    }
    workspace.definitionsWindow?.window?.orderOut(nil)
  }
}
