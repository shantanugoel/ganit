import Foundation
import GanitData
import GanitEngine

/// The editor inspector and coordinator use the same app-owned request context.
public enum SuggestionRequestContext {
  /// Prepare the wire body without occupying the editor thread.
  package static func requestBody(
    settings: AssistantSettings, snapshot: AssistanceSnapshot,
    including handles: Set<String> = [], choices: [String: String] = [:],
    userRevisedInputs: Bool = false
  ) async throws -> Data {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let context = try data(
        snapshot: snapshot, including: handles, choices: choices,
        userRevisedInputs: userRevisedInputs)
      try Task.checkCancellation()
      return try SuggestionWireRequest(settings: settings, context: context).body
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

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
