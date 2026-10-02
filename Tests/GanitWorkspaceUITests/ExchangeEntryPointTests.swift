import AppKit
import Foundation
import GanitDocuments
import Testing

@testable import GanitEditorUI
@testable import GanitWorkspaceUI

/// The app's import, open and export paths keep a table-bearing sheet's
/// exact bytes. `Workspace.importSheet(from:)` is what File ▸ Import… and
/// opening files from Finder call once files are chosen, and
/// `WorkspaceWindowController.export(_:lines:as:to:)` what File ▸ Export…
/// calls once a destination is chosen; the panels themselves are modal.
@MainActor
@Suite
struct ExchangeEntryPointTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitExchangeEntryPoints-\(UUID().uuidString)", directoryHint: .isDirectory)

  /// Every line ending, Unicode separators, NEL, decomposed text, an inner
  /// U+FEFF, tables with bindings and `#REF!` markers, and malformed,
  /// unsupported and unterminated blocks, with no final line ending.
  private static func source() throws -> Data {
    let fixtures = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "GanitEngineTests/Fixtures/TableBlocks", directoryHint: .isDirectory)
    var data = Data("# Groceries\u{2028}still the title\u{0085}\r\n".utf8)
    for name in [
      "line-endings-crlf.txt", "valid-two-tables.txt", "line-endings-cr.txt",
      "malformed-json.txt", "unicode.txt", "unsupported-version.txt",
    ] {
      data += try Data(contentsOf: fixtures.appending(path: name))
    }
    data += Data("cafe\u{301} = 1\rinner\u{FEFF}mark\n".utf8)
    data += try Data(contentsOf: fixtures.appending(path: "unterminated.txt")).dropLast()
    return data
  }

  @Test
  func importOpenSaveAndExportKeepExactBytes() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bytes = try Self.source()
    let file = root.appending(path: "Groceries.txt")
    try bytes.write(to: file)
    let workspace = try Workspace(library: SheetLibrary(root: root.appending(path: "Library")))
    defer {
      for controller in workspace.windows {
        controller.window?.orderOut(nil)
      }
    }
    let stored = { (id: UUID) throws -> Data in
      Data(try workspace.library.store.load(id: id).source.utf8)
    }

    let id = try workspace.importSheet(from: file)

    #expect(try stored(id) == bytes)
    let controller = workspace.openWindow(showing: id)
    let editor = try #require(controller.editor)
    #expect(Data(editor.textView.string.utf8) == bytes)
    #expect(Data(editor.sheet.text.utf8) == bytes)

    // Saving what the editor holds writes the same bytes.
    let sheet = try workspace.sheet(id)
    sheet.autosaver.sourceDidChange()
    sheet.autosaver.saveNow()
    #expect(!sheet.autosaver.hasUnsavedChanges)
    #expect(try stored(id) == bytes)

    // A package carries a Quick Look preview rendered from the editor's
    // lines, and both formats hold the stored bytes.
    let lines = await editor.exportedLines()
    #expect(lines.count == editor.sheet.lines.count)
    let package = root.appending(path: "Groceries.ganit")
    try controller.export(id, lines: lines, as: .ganitSheet, to: package)
    #expect(try Data(contentsOf: package.appending(path: "source.txt")) == bytes)
    let preview = package.appending(path: "QuickLook/Preview.pdf")
    #expect(try Data(contentsOf: preview).starts(with: Data("%PDF".utf8)))
    let thumbnail = try Data(contentsOf: package.appending(path: "QuickLook/Thumbnail.png"))
    #expect(NSBitmapImageRep(data: thumbnail) != nil)
    let text = root.appending(path: "Groceries export.txt")
    try controller.export(id, lines: lines, as: .plainText, to: text)
    #expect(try Data(contentsOf: text) == bytes)
    #expect(Data(editor.textView.string.utf8) == bytes)
    #expect(try stored(id) == bytes)

    // Opening the exports adds sheets with the same bytes.
    let fromPackage = try workspace.importSheet(from: package)
    let fromText = try workspace.importSheet(from: text)
    #expect(Set([id, fromPackage, fromText]).count == 3)
    #expect(try stored(fromPackage) == bytes && stored(fromText) == bytes)
  }

  /// U+FEFF at the start of a sheet's own text stays in the editor, and
  /// saving and plain-text export write it back.
  @Test
  func editorKeepsALeadingFEFF() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("\u{FEFF}".utf8) + (try Self.source())
    let library = try SheetLibrary(root: root.appending(path: "Library"))
    let source = String(decoding: bytes, as: UTF8.self)
    let metadata = try library.save(
      source: source, metadata: library.create(preferences: .standard))
    let workspace = try Workspace(library: library)
    defer {
      for controller in workspace.windows {
        controller.window?.orderOut(nil)
      }
    }

    let controller = workspace.openWindow(showing: metadata.id)

    let editor = try #require(controller.editor)
    #expect(Data(editor.textView.string.utf8) == bytes)
    let sheet = try workspace.sheet(metadata.id)
    sheet.autosaver.sourceDidChange()
    sheet.autosaver.saveNow()
    #expect(!sheet.autosaver.hasUnsavedChanges)
    #expect(Data(try library.store.load(id: metadata.id).source.utf8) == bytes)
    let text = root.appending(path: "Leading.txt")
    try controller.export(
      metadata.id, lines: await editor.exportedLines(), as: .plainText, to: text)
    #expect(try Data(contentsOf: text) == bytes)
  }
}
