import Foundation
import GanitEngine

/// The editor inspector and coordinator use the same app-owned request context.
public enum SuggestionRequestContext {
  public static func data(
    snapshot: AssistanceSnapshot, including handles: Set<String> = [],
    choices: [String: String] = [:], userRevisedInputs: Bool = false
  ) throws -> Data {
    let data = try snapshot.permittedContext(including: handles)
    guard !choices.isEmpty || userRevisedInputs else { return data }
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if !choices.isEmpty { root["selectedChoices"] = choices }
    if userRevisedInputs { root["userRevisedInputs"] = true }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }
}
