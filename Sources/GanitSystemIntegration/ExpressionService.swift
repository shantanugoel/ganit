import AppKit
import Foundation

/// Serves Evaluate Expression, the macOS service that answers text selected
/// in another app.
///
/// The service reads and writes only the pasteboard the system hands it, and
/// evaluation stays local, so selected text never leaves the Mac.
@MainActor
public final class ExpressionServiceProvider: NSObject {
  /// Supplies a calculation per request so the answer uses the exchange
  /// rates and preferences current at that moment.
  private let calculation: @MainActor () -> ExpressionCalculation

  public init(calculation: @MainActor @escaping () -> ExpressionCalculation) {
    self.calculation = calculation
    super.init()
  }

  /// Replaces the pasteboard's expression with its answer. A failure returns
  /// its message, which the system shows, and leaves the text unchanged.
  @objc public func evaluateExpression(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let source = pasteboard.string(forType: .string) else {
      errorMessage.pointee =
        localized("service.noExpression", "Select an expression to evaluate.") as NSString
      return
    }
    do {
      let answer = try calculation().answer(for: source)
      pasteboard.clearContents()
      pasteboard.setString(answer, forType: .string)
    } catch {
      errorMessage.pointee = error.localizedDescription as NSString
    }
  }
}

func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
