import Foundation
import GanitData
import GanitEngine

/// The editor inspector and coordinator use the same app-owned request context.
public enum SuggestionRequestContext {
  /// Prepare the wire body without occupying the editor thread.
  package static func requestBody(
    settings: AssistantSettings, snapshot: AssistanceSnapshot,
    including handles: Set<String> = [], choices: [String: String] = [:],
    userRevisedInputs: Bool = false, allowsExplanation: Bool = false, allowsAnswer: Bool = false
  ) async throws -> Data {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let context = try data(
        snapshot: snapshot, including: handles, choices: choices,
        userRevisedInputs: userRevisedInputs)
      try Task.checkCancellation()
      return try SuggestionWireRequest(
        settings: settings, context: context, allowsExplanation: allowsExplanation,
        allowsAnswer: allowsAnswer && !allowsExplanation && canAnswer(snapshot, including: handles)
      ).body
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// A read-only answer cannot replace a calculation or a missing numeric input.
  package static func canAnswer(_ snapshot: AssistanceSnapshot, including handles: Set<String>)
    -> Bool
  {
    guard !snapshot.evidence(including: handles).contains(where: { $0.kind == "literal" }),
      !snapshot.inventory.contains(where: { $0.matchesTarget || handles.contains($0.handle) })
    else { return false }
    let targets = Set(snapshot.targetLines.map(\.id))
    return !zip(snapshot.source.lines, snapshot.evaluation.lines).contains { line, result in
      guard targets.contains(line.id) else { return false }
      if case .value = result.result { return true }
      return false
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
