import AppKit
import Foundation
import Testing

@testable import GanitEditorUI

@MainActor
@Suite
struct VisualStyleTests {
  @Test
  func symbolsExistAndTypeRespectsTheMinimum() {
    for symbol in VisualStyle.Symbol.all {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
    #expect(VisualStyle.Typography.caption.pointSize >= VisualStyle.Typography.minimumSize)
    #expect(
      VisualStyle.Typography.source(scale: SheetTextView.textScales[0]).pointSize
        >= VisualStyle.Typography.minimumSize)
  }

  @Test func assumptionMarksUseTheSemanticTokenInBothAppearances() throws {
    let view = SheetTextView()
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try #require(NSAppearance(named: name))
      appearance.performAsCurrentDrawingAppearance {
        #expect(
          view.badgeAttributes[.foregroundColor] as? NSColor == VisualStyle.Color.aiAssumption)
        #expect(
          view.badgeWidth(for: AnswerCell(text: "1", fullPrecision: "1", isAIAssumption: true)) > 0)
        #expect(
          view.badgeWidth(for: AnswerCell(text: "1", fullPrecision: "1", isAIDerived: true)) > 0)
        #expect(view.badgeWidth(for: AnswerCell(text: "1", fullPrecision: "1")) == 0)
      }
    }
    #expect(SheetTextView.assumptionBadge == "AI")
  }

  /// Interface code uses semantic colors, system fonts, and standard
  /// materials rather than literal values or custom-painted effects.
  @Test
  func interfaceSourcesUseOnlySystemColorsFontsAndMaterials() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources")
    let forbidden = [
      "NSColor(red", "NSColor(calibratedRed", "NSColor(srgbRed", "NSColor(deviceRed",
      "NSColor(white", "NSColor(calibratedWhite", "NSColor(displayP3Red", "NSColor(hue",
      "NSFont(name", "NSGradient", "NSVisualEffectView", "CAGradientLayer",
    ]
    for module in ["GanitEditorUI", "GanitWorkspaceUI", "GanitQuickUI", "GanitApp"] {
      let files = try #require(
        FileManager.default.enumerator(
          at: sources.appending(path: module), includingPropertiesForKeys: nil)?
          .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
      for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for token in forbidden {
          #expect(!source.contains(token), "\(file.lastPathComponent) uses \(token)")
        }
      }
    }
  }
}
