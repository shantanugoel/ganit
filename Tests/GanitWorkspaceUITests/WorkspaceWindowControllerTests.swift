import AppKit
import Testing
@testable import GanitWorkspaceUI

@Test
@MainActor
func workspaceWindowUsesStandardMacWindowBehavior() throws {
    let controller = WorkspaceWindowController()
    let window = try #require(controller.window)

    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.miniaturizable))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.minSize == NSSize(width: 640, height: 400))
    #expect(window.contentViewController != nil)
}
