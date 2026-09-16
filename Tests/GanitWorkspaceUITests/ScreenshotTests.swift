import AppKit
import CoreGraphics
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
/// A window is drawn from an on-screen capture of that window when the
/// window server will give one, so the title bar and traffic lights match
/// the running app. Otherwise the content is framed with a drawn title bar.
@MainActor
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["GANIT_SCREENSHOTS"] == "1")
)
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
    window.setContentSize(NSSize(width: 900, height: 480))
    try await write(window, of: controller.editor, to: "library-dark.png")
    for open in workspace.windows { open.window?.orderOut(nil) }
  }

  /// A Calca-style article: sentences with arithmetic, answers after `=>`.
  @Test
  func markdownMode() async throws {
    let (workspace, ids) = try makeWorkspace([
      """
      # Saturday baking

      We need flour and milk for three cakes.

      Flour for all three is 500 g * 3 =>
      Milk for all three is (1.5 l * 3) in ml =>
      Half-litre bottles to buy: 4500 ml / 500 ml =>

      Flour and milk together cost 240 + 315 =>
      Each of us pays 555 / 3 =>
      """
    ])
    let controller = workspace.openWindow(showing: ids[0])
    try workspace.write(DisplayOptions(writesAnswersInline: true), on: ids[0])
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 900, height: 420))
    try await write(window, of: controller.editor, to: "markdown-dark.png")
    for open in workspace.windows { open.window?.orderOut(nil) }
  }

  /// A line Ganit cannot work out, answered by an assistant, in the colour
  /// that says the answer is not Ganit's arithmetic.
  @Test
  func theAssistant() async throws {
    let (workspace, ids) = try makeWorkspace([
      """
      # Density

      // water weighs a kilogram a litre
      10 kg of water in ml
      1,500 ml + 500 ml
      """
    ])
    workspace.askAssistant = { _ in "10,000 ml" }
    let controller = workspace.openWindow(showing: ids[0])
    controller.editor?.assistantPause = .zero
    controller.editor?.askAssistant = workspace.askAssistant
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 900, height: 280))
    try await write(window, of: controller.editor, to: "assistant-dark.png")
    for open in workspace.windows { open.window?.orderOut(nil) }
  }

  @Test
  func quickGanit() async throws {
    let panel = try QuickPanelController(context: SheetPreferences.standard.evaluationContext())
    panel.editor.textView.string = "22,500 / 12\n15% of 1,875"
    panel.show()
    let window = try #require(panel.window)
    window.setContentSize(NSSize(width: 640, height: 140))
    try await write(window, of: panel.editor, to: "quick-dark.png")
    window.orderOut(nil)
  }

  /// Draws a window, in Dark Appearance, once its answers have settled,
  /// including the title bar and toolbar so the README shows the app as it
  /// appears on a Mac.
  private func write(
    _ window: NSWindow,
    of editor: SheetEditorViewController?,
    to name: String
  ) async throws {
    let appearance = NSAppearance(named: .darkAqua)
    NSApp.appearance = appearance
    window.appearance = appearance
    window.tabbingMode = .disallowed
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    await editor?.scheduler?.waitUntilIdle()
    // Answers the assistant gives arrive after the sheet has settled.
    try await Task.sleep(for: .milliseconds(200))
    window.layoutIfNeeded()
    window.displayIfNeeded()
    editor?.textView.scroll(.zero)
    // The sidebar scrolls to whichever sheet is open; start it at its top.
    scrollToTop(window.contentView)
    // The window server needs a turn to composite the title bar; without
    // this, a screen capture of a just-ordered window is empty.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(250))
    let image = try #require(
      windowImage(window) ?? framedContent(of: window),
      "Could not draw \(name)"
    )
    try png(of: image).write(to: try images().appending(path: name))
  }

  /// The on-screen window, chrome and all, at the display's native scale.
  private func windowImage(_ window: NSWindow) -> NSImage? {
    let id = CGWindowID(window.windowNumber)
    guard id != 0,
      let cgImage = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        id,
        [.bestResolution]
      ),
      cgImage.width > 32,
      cgImage.height > 32
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: window.frame.size)
  }

  /// Content plus a drawn title bar, used when the screen capture of the
  /// window is empty (no window-server picture of an off-screen test window).
  private func framedContent(of window: NSWindow) -> NSImage? {
    let titlebar: CGFloat = 52
    let radius: CGFloat = 10
    let pad: CGFloat = 28
    let page: NSPDFImageRep
    let drawsTitlebar: Bool
    if window.titlebarAppearsTransparent || !window.styleMask.contains(.titled) {
      guard let content = window.contentView else {
        return nil
      }
      let area = content.bounds
      guard let pdf = NSPDFImageRep(data: content.dataWithPDF(inside: area)) else {
        return nil
      }
      page = pdf
      drawsTitlebar = true
    } else if let chrome = themeFrame(of: window),
      let pdf = NSPDFImageRep(data: chrome.dataWithPDF(inside: chrome.bounds))
    {
      page = pdf
      drawsTitlebar = false
    } else {
      return nil
    }
    let inner = NSSize(
      width: page.bounds.width,
      height: page.bounds.height + (drawsTitlebar ? titlebar : 0)
    )
    let canvas = NSSize(width: inner.width + pad * 2, height: inner.height + pad * 2)
    let image = NSImage(size: canvas)
    image.lockFocus()
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
      let ctx = NSGraphicsContext.current!.cgContext
      let frame = NSRect(x: pad, y: pad, width: inner.width, height: inner.height)
      ctx.setShadow(
        offset: CGSize(width: 0, height: -8),
        blur: 18,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
      )
      let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
      NSColor.windowBackgroundColor.setFill()
      path.fill()
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
      ctx.saveGState()
      path.addClip()
      if drawsTitlebar {
        let titlebarRect = NSRect(
          x: frame.minX, y: frame.maxY - titlebar, width: frame.width, height: titlebar)
        NSColor.windowBackgroundColor.setFill()
        titlebarRect.fill()
        drawTrafficLights(in: titlebarRect)
        drawTitle(window.title, in: titlebarRect)
        page.draw(
          in: NSRect(
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - titlebar))
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: frame.minX, y: frame.maxY - titlebar))
        divider.line(to: NSPoint(x: frame.maxX, y: frame.maxY - titlebar))
        divider.lineWidth = 1
        divider.stroke()
      } else {
        page.draw(in: frame)
        let titlebarRect = NSRect(
          x: frame.minX, y: frame.maxY - titlebar, width: frame.width, height: titlebar)
        drawTrafficLights(in: titlebarRect)
      }
      ctx.restoreGState()
    }
    image.unlockFocus()
    return image
  }

  /// The window's frame view, which draws the title bar and toolbar around
  /// the content.
  private func themeFrame(of window: NSWindow) -> NSView? {
    var view = window.contentView
    while let superview = view?.superview {
      view = superview
    }
    return view
  }

  private func drawTrafficLights(in titlebar: NSRect) {
    let colors: [NSColor] = [
      NSColor(calibratedRed: 1, green: 0.373, blue: 0.341, alpha: 1),
      NSColor(calibratedRed: 1, green: 0.737, blue: 0.180, alpha: 1),
      NSColor(calibratedRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),
    ]
    let diameter: CGFloat = 12
    let y = titlebar.midY - diameter / 2
    for (index, color) in colors.enumerated() {
      let x = titlebar.minX + 16 + CGFloat(index) * 20
      let dot = NSRect(x: x, y: y, width: diameter, height: diameter)
      color.setFill()
      NSBezierPath(ovalIn: dot).fill()
    }
  }

  private func drawTitle(_ title: String, in titlebar: NSRect) {
    guard !title.isEmpty else {
      return
    }
    let text = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    let size = text.size()
    let origin = NSPoint(
      x: titlebar.midX - size.width / 2,
      y: titlebar.midY - size.height / 2
    )
    text.draw(at: origin)
  }

  private func scrollToTop(_ view: NSView?) {
    guard let view else { return }
    if let scroll = view as? NSScrollView {
      scroll.documentView?.scroll(NSPoint(x: 0, y: -scroll.contentInsets.top))
    }
    view.subviews.forEach(scrollToTop)
  }

  /// A retina-sized PNG of a window picture. Transparent padding is left as
  /// it is, so a captured window shadow sits on the README page.
  private func png(of image: NSImage, scale: CGFloat = 2) throws -> Data {
    let size = image.size
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
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
      image.draw(in: NSRect(origin: .zero, size: size))
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
