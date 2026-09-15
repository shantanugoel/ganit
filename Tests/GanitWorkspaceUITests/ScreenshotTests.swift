import AppKit
import Foundation
import GanitDocuments
import GanitEngine
import GanitFormatting
import GanitQuickUI
import Testing

@testable import GanitEditorUI
@testable import GanitWorkspaceUI

/// Draws the pictures in `docs/images`, so the README shows what this build of
/// Ganit actually looks like rather than what it looked like once.
///
/// Pictures are drawn only when asked for:
/// `GANIT_SCREENSHOTS=1 swift test --filter ScreenshotTests`.
///
/// A window is drawn through `dataWithPDF`, which asks every view to draw
/// itself. Reading the screen instead would need a screen-recording
/// permission, and reading the layers of a window that was never on a screen
/// returns nothing at all.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GANIT_SCREENSHOTS"] == "1"))
struct ScreenshotTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitScreenshots-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func theLibraryWindow() async throws {
    let (workspace, ids) = try makeWorkspace([
      """
      # Party for 20

      drinks = 2,400
      food = 5,600
      cake = 1,200
      subtotal

      // a tenth for the tip
      10% of line 6

      # In the kitchen

      flour = 500 g
      flour * 3
      milk = 1.5 l
      milk in ml
      200 °C in °F
      """
    ])
    let controller = workspace.openWindow(showing: ids[0])
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 820, height: 420))
    try await write(window, of: controller.editor, to: "library.png")
    for open in workspace.windows { open.window?.orderOut(nil) }
  }

  /// The same answers, read as prose: in the lines rather than beside them.
  @Test
  func proseMode() async throws {
    let (workspace, ids) = try makeWorkspace([
      """
      # Saturday

      // three cakes, and each takes 500 g of flour and 1.5 l of milk

      Flour for all three: 500 g * 3
      Milk in millilitres: (1.5 l * 3) in ml
      Half-litre bottles to buy: 4500 ml / 500 ml

      // and the shopping, split three ways

      Flour and milk cost: 240 + 315
      Each of us pays: 555 / 3
      """
    ])
    let controller = workspace.openWindow(showing: ids[0])
    try workspace.write(DisplayOptions(writesAnswersInline: true), on: ids[0])
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 820, height: 320))
    try await write(window, of: controller.editor, to: "prose.png")
    for open in workspace.windows { open.window?.orderOut(nil) }
  }

  /// A line Ganit cannot work out, answered by an assistant, in the colour
  /// that says the answer is not Ganit's arithmetic.
  @Test
  func theAssistant() async throws {
    let editor = SheetEditorViewController(
      text: "// water weighs a kilogram a litre\n10 kg of water in ml\n1,500 ml + 500 ml",
      context: try SheetPreferences.standard.evaluationContext()
    )
    editor.assistantPause = .zero
    editor.askAssistant = { _ in "10,000 ml" }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 140),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.title = "Scratch"
    window.contentViewController = editor
    window.setContentSize(NSSize(width: 620, height: 130))
    try await write(window, of: editor, to: "assistant.png")
  }

  @Test
  func quickGanit() async throws {
    let panel = try QuickPanelController(context: SheetPreferences.standard.evaluationContext())
    panel.editor.textView.string = "22,500 / 12\n15% of 1,875"
    panel.show()
    let window = try #require(panel.window)
    window.setContentSize(NSSize(width: 620, height: 110))
    try await write(window, of: panel.editor, to: "quick.png")
    window.orderOut(nil)
  }

  /// Draws a window, in Light Appearance, once its answers have settled.
  private func write(
    _ window: NSWindow,
    of editor: SheetEditorViewController?,
    to name: String
  ) async throws {
    window.appearance = NSAppearance(named: .aqua)
    // The title bar and toolbar are the system's chrome. Taking them away
    // leaves the window with nothing in it but what Ganit draws, and every
    // part of it laid out against the same edges.
    window.toolbar = nil
    window.styleMask.remove([.titled, .fullSizeContentView])
    window.layoutIfNeeded()
    await editor?.scheduler?.waitUntilIdle()
    // Answers the assistant gives arrive after the sheet has settled.
    try await Task.sleep(for: .milliseconds(200))
    window.layoutIfNeeded()
    editor?.textView.scroll(.zero)
    // The sidebar scrolls to whichever sheet is open; start it at its top.
    scrollToTop(window.contentView)
    let view = try #require(window.contentView)
    // The title bar belongs to the system and is not drawn here, so the
    // picture is of what Ganit draws beneath it.
    let area = window.contentLayoutRect.intersection(view.bounds)
    let page = try #require(NSPDFImageRep(data: view.dataWithPDF(inside: area)))
    try png(of: page).write(to: try images().appending(path: name))
  }

  private func scrollToTop(_ view: NSView?) {
    guard let view else { return }
    if let scroll = view as? NSScrollView {
      scroll.documentView?.scroll(NSPoint(x: 0, y: -scroll.contentInsets.top))
    }
    view.subviews.forEach(scrollToTop)
  }

  /// A retina-sized bitmap of a drawn window, on the window background rather
  /// than on nothing, since a page that is read in the dark still holds ink.
  private func png(of page: NSPDFImageRep, scale: CGFloat = 2) throws -> Data {
    let size = page.bounds.size
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
      page.draw(in: NSRect(origin: .zero, size: size))
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func images() throws -> URL {
    let images = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "docs/images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    return images
  }

  private func makeWorkspace(_ sources: [String]) throws -> (Workspace, [UUID]) {
    let library = try SheetLibrary(root: root)
    let ids = try sources.map { source in
      try library.save(
        source: source,
        metadata: library.create(preferences: SheetPreferences.standard)
      ).id
    }
    return (try Workspace(library: library), ids)
  }
}
