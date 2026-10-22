import Foundation
import Testing

@testable import GanitEditorUI

@MainActor
struct AskDisclosureTests {
  @Test func theDisclosureIncludesExactBytesAndCapturedSource() throws {
    let context: [String: Any] = [
      "target": ["source": "f(3)\n\n"],
      "symbols": [
        [
          "name": "f", "source": "f(x) = x * rate",
          "function": [
            "definitions": [
              [
                "source": "f(x) = x * rate", "captures": [["source": "rate = 4"]],
              ]
            ]
          ],
        ]
      ],
    ]
    let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    let body = try JSONSerialization.data(
      withJSONObject: [
        "model": "synthetic",
        "messages": [["content": String(decoding: contextData, as: UTF8.self)]],
      ], options: [.sortedKeys])
    let disclosure = AskBar.contextDisclosure(for: body)
    #expect(disclosure.contains("f(x) = x * rate"))
    #expect(disclosure.contains("rate = 4"))
    #expect(disclosure.contains("Exact request bytes"))
    #expect(disclosure.hasSuffix(String(decoding: body, as: UTF8.self)))
  }
}
