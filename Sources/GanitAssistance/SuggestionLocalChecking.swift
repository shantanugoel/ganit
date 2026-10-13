import Foundation
import GanitEngine
import GanitSuggestionProtocol

/// Native checks use a frozen copy and never occupy the editor's calculation worker.
package enum SuggestionLocalChecking {
  package static func check(
    _ candidate: SuggestionCandidate, snapshot: AssistanceSnapshot,
    handles: Set<String>, choices: [String: String], assumptions: Set<String>,
    userRevisedInputs: Bool = false
  ) async throws -> AssistanceCheckedCandidate {
    let task = Task.detached(priority: .utility) {
      try AssistanceCandidateChecker.check(
        candidate, against: snapshot,
        permittedHandles: handles, selectedChoices: choices, approvedAssumptions: assumptions,
        userRevisedInputs: userRevisedInputs)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  package static func prepare(
    _ candidate: SuggestionCandidate, snapshot: AssistanceSnapshot,
    handles: Set<String>, choices: [String: String], assumptions: Set<String>,
    userRevisedInputs: Bool = false
  ) async throws -> AssistanceSourceEdit {
    let task = Task.detached(priority: .utility) {
      try AssistanceCandidateChecker.prepareSourceEdit(
        candidate, against: snapshot,
        permittedHandles: handles, selectedChoices: choices, approvedAssumptions: assumptions,
        userRevisedInputs: userRevisedInputs)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
