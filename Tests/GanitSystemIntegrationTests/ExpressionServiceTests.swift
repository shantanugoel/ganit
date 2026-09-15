import AppKit
import Foundation
import Testing

@testable import GanitSystemIntegration

@MainActor
@Suite
struct ExpressionServiceTests {
  @Test
  func replacesTheSelectedExpressionWithItsAnswer() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitServiceTests-\(UUID())"))
    pasteboard.clearContents()
    pasteboard.setString("20% off 85", forType: .string)

    var error: NSString?
    provider().evaluateExpression(pasteboard, userData: nil, error: &error)

    #expect(error == nil)
    #expect(pasteboard.string(forType: .string) == "68")
  }

  @Test
  func leavesTheSelectionAloneAndExplainsWhatItCannotAnswer() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitServiceTests-\(UUID())"))
    pasteboard.clearContents()
    pasteboard.setString("1 m + 1 s", forType: .string)

    var error: NSString?
    provider().evaluateExpression(pasteboard, userData: nil, error: &error)

    #expect(pasteboard.string(forType: .string) == "1 m + 1 s")
    let message = try #require(error) as String
    #expect(!message.isEmpty)
  }

  @Test
  func reportsAnEmptyPasteboardRatherThanAnEmptyAnswer() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitServiceTests-\(UUID())"))
    pasteboard.clearContents()

    var error: NSString?
    provider().evaluateExpression(pasteboard, userData: nil, error: &error)

    #expect(error as String? == "Select an expression to evaluate.")
  }

  /// The service the bundle registers, answering with the app's defaults.
  private func provider() -> ExpressionServiceProvider {
    ExpressionServiceProvider { ExpressionCalculation() }
  }
}
