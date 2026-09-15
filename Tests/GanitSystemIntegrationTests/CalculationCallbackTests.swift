import Foundation
import Testing

@testable import GanitSystemIntegration

@Suite
struct CalculationCallbackTests {
  @Test
  func answersToTheSuccessCallback() throws {
    let callback = try CalculationCallback(
      url: url(
        "expression=20%25%20off%2085&x-success=shortcuts://callback?id=7&x-error=shortcuts://error")
    )
    #expect(callback.expression == "20% off 85")

    let response = try #require(callback.response(using: ExpressionCalculation()))
    #expect(response.absoluteString == "shortcuts://callback?id=7&result=68")
  }

  @Test
  func explainsFailuresToTheErrorCallback() throws {
    let callback = try CalculationCallback(
      url: url("expression=1%20m%20%2B%201%20s&x-success=app://ok&x-error=app://error"))
    let response = try #require(callback.response(using: ExpressionCalculation()))
    let items = URLComponents(url: response, resolvingAgainstBaseURL: false)?.queryItems
    #expect(response.host() == "error")
    #expect(items?.first?.name == "errorMessage")
    #expect(items?.first?.value == "These quantities have incompatible dimensions.")
    // Without callbacks there is nothing to open.
    #expect(try CalculationCallback(url: url("expression=2")).response(using: .init()) == nil)
  }

  @Test
  func rejectsRequestsOutsideTheOneBoundedAction() throws {
    let cases: [(String, CalculationCallbackError)] = [
      ("ganit://x-callback-url/new-sheet?expression=2", .unsupportedAction),
      ("ganit://other/calculate?expression=2", .unsupportedAction),
      ("ganit://x-callback-url/calculate", .invalidParameters),
      ("ganit://x-callback-url/calculate?expression=1&expression=2", .invalidParameters),
      ("ganit://x-callback-url/calculate?expression=1&path=/etc", .invalidParameters),
      (
        "ganit://x-callback-url/calculate?expression=1&x-success=file:///tmp/a", .disallowedCallback
      ),
      ("ganit://x-callback-url/calculate?expression=1&x-success=ganit://x", .disallowedCallback),
      ("ganit://x-callback-url/calculate?expression=1&x-error=notaurl", .disallowedCallback),
      (
        "ganit://x-callback-url/calculate?expression=1&x-success=app://"
          + String(repeating: "a", count: 2_100), .disallowedCallback
      ),
      (
        "ganit://x-callback-url/calculate?expression=" + String(repeating: "1", count: 8_200),
        .tooLong
      ),
    ]
    for (text, error) in cases {
      #expect(throws: error, "\(text.prefix(80))") {
        try CalculationCallback(url: try #require(URL(string: text)))
      }
    }
    // The expression keeps the headless 4 KB limit.
    let long = try CalculationCallback(
      url: url("expression=" + String(repeating: "1", count: 5_000) + "&x-error=app://error"))
    #expect(long.response(using: ExpressionCalculation())?.host() == "error")
  }

  private func url(_ query: String) throws -> URL {
    try #require(URL(string: "ganit://x-callback-url/calculate?" + query))
  }
}
