import AppKit
import Foundation
import GanitDocuments
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct WindowFocusTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitWindowFocusTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func makeWorkspace() throws -> (Workspace, UUID) {
    let store = TextDocumentStore(url: root.appending(path: "Definitions.txt"))
    let library = try SheetLibrary(root: root)
    let id = try library.save(source: "1 + 1", metadata: library.create(preferences: .standard)).id
    return (try Workspace(library: library, definitions: store), id)
  }

  private func close(_ workspace: Workspace) {
    for controller in workspace.windows {
      controller.window?.orderOut(nil)
    }
  }

  @Test
  func openingAWindowBringsGanitForward() throws {
    let (workspace, id) = try makeWorkspace()
    defer { close(workspace) }
    var activations = 0
    workspace.activateApplication = { activations += 1 }

    workspace.openWindow(showing: id)

    #expect(activations >= 1)
  }

  @Test
  func showingAnOpenWindowAgainBringsGanitForward() throws {
    let (workspace, id) = try makeWorkspace()
    defer { close(workspace) }
    workspace.openWindow(showing: id)
    var activations = 0
    workspace.activateApplication = { activations += 1 }

    _ = try workspace.showCurrentWindow()

    #expect(activations == 1)
  }

  @Test
  func openingDefinitionsBringsGanitForward() throws {
    let (workspace, _) = try makeWorkspace()
    defer { close(workspace) }
    var activations = 0
    workspace.activateApplication = { activations += 1 }

    try workspace.openDefinitions()

    #expect(activations >= 1)
  }
}
