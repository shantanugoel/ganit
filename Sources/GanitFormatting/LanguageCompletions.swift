import Foundation
import GanitEngine

/// Names a person can complete while typing: functions, constants, and keywords.
public enum LanguageCompletions {
  public static let items: [String] = {
    let calls =
      (BuiltInFunction.allCases.map(\.rawValue) + FinanceFunction.allCases.map(\.rawValue)
      + AssistantFunction.allCases.map(\.rawValue))
      .map { "\($0)(" }
    let words = [
      "pi", "π", "e", "previous", "prev", "sum", "total", "subtotal", "average", "avg", "median",
      "count",
    ]
    return (calls + words).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }()

  public static func matching(_ prefix: String) -> [String] {
    let needle = prefix.lowercased()
    guard !needle.isEmpty else {
      return []
    }
    return items.filter { $0.lowercased().hasPrefix(needle) }
  }
}
