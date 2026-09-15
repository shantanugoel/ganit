import Foundation
import Testing

@testable import GanitEngine

@Suite
struct StackSafetyTests {
  /// Expressions at exactly the default depth limit, one per way the tree can
  /// deepen: grouping, prefixes, calls, right-recursive and left-chained
  /// operators, and conversion chains.
  private static let deepestSources = [
    String(repeating: "(", count: 127) + "1" + String(repeating: ")", count: 127),
    String(repeating: "-", count: 127) + "1",
    String(repeating: "abs(", count: 127) + "1" + String(repeating: ")", count: 127),
    String(repeating: "1^", count: 127) + "1",
    Array(repeating: "1", count: 128).joined(separator: " + "),
    "1 m" + String(repeating: " in cm", count: 126),
  ]

  @Test
  func defaultDepthLimitFitsASecondaryThreadStack() async throws {
    let context = try sheetContext()
    let failures = await withCheckedContinuation { continuation in
      let thread = Thread {
        let engine = CalculationEngine()
        var failures: [String] = []
        for source in Self.deepestSources {
          if !engine.parse(source, context: context).diagnostics.isEmpty {
            failures.append("rejected at the limit: \(source.prefix(12))")
          }
          if engine.parse("(" + source + ")", context: context).diagnostics.first?.code
            != .resourceLimitExceeded
          {
            failures.append("accepted past the limit: \(source.prefix(12))")
          }
          _ = engine.evaluate(source, context: context)
          var calculator = SheetCalculator(engine: engine)
          _ = try? calculator.evaluate(SheetSource(source), context: context)
        }
        continuation.resume(returning: failures)
      }
      // Release builds must fit the 512 KiB stack of secondary threads.
      // Unoptimized and sanitized frames are several times larger.
      #if DEBUG
        thread.stackSize = 16 << 20
      #else
        thread.stackSize = 512 << 10
      #endif
      thread.start()
    }
    #expect(failures.isEmpty, "\(failures)")
  }
}
