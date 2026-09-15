import AppKit

/// Responder-chain actions that sheet editors handle, declared so menus and
/// shortcuts can name their selectors. The text view handles result, reference,
/// and formatting commands; the editor controller handles evaluation.
@MainActor
@objc public protocol SheetCommands {
  func copyResult(_ sender: Any?)
  func copyFullPrecision(_ sender: Any?)
  func showInterpretation(_ sender: Any?)
  func insertReference(_ sender: Any?)
  func insertSubtotal(_ sender: Any?)
  func toggleHeading(_ sender: Any?)
  func toggleComment(_ sender: Any?)
  func insertDivider(_ sender: Any?)
  func recalculate(_ sender: Any?)
  func stopCalculation(_ sender: Any?)
  func increaseTextSize(_ sender: Any?)
  func decreaseTextSize(_ sender: Any?)
  func resetTextSize(_ sender: Any?)
}
