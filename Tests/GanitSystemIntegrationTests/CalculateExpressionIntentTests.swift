import AppIntents
import Foundation
import Testing

@testable import GanitSystemIntegration

@Suite
struct CalculateExpressionIntentTests {
  @Test
  func answersOneExpressionWithoutOpeningTheApp() async throws {
    #expect(CalculateExpressionIntent.openAppWhenRun == false)

    let result = try await CalculateExpressionIntent(expression: "20% off 85 + 2").perform()

    #expect(result.value == "70")
  }

  @Test
  func failsWithTheEnginesExplanationRatherThanGuessing() async throws {
    await #expect(throws: UnevaluableExpression.self) {
      try await CalculateExpressionIntent(expression: "1 m + 1 s").perform()
    }
  }
}
