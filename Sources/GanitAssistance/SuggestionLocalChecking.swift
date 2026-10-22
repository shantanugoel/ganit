import Foundation
import GanitEngine
import GanitSuggestionProtocol

/// Native checks use a frozen copy and never occupy the editor's calculation worker.
package enum SuggestionLocalChecking {
  package static func check(
    _ candidate: SuggestionCandidate, snapshot: AssistanceSnapshot,
    handles: Set<String>, choices: [String: String], assumptions: Set<String>,
    userRevisedInputs: Bool = false, omittedLines: Set<Int> = []
  ) async throws -> AssistanceCheckedCandidate {
    let task = Task.detached(priority: .utility) {
      let revised = try AssistanceCandidateChecker.selectingLines(
        candidate, against: snapshot, omitted: omittedLines, choices: choices)
      return try AssistanceCandidateChecker.check(
        revised, against: snapshot,
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
    userRevisedInputs: Bool = false, omittedLines: Set<Int> = []
  ) async throws -> AssistanceSourceEdit {
    let task = Task.detached(priority: .utility) {
      let revised = try AssistanceCandidateChecker.selectingLines(
        candidate, against: snapshot, omitted: omittedLines, choices: choices)
      return try AssistanceCandidateChecker.prepareSourceEdit(
        revised, against: snapshot,
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
