import Foundation

/// An uncooperative late reply cannot keep a cancelled job alive.
actor SuggestionDeadline<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, any Error>?
  private var outcome: Result<Value, any Error>?
  private var tasks: [Task<Void, Never>] = []

  private func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
    if let outcome {
      continuation.resume(with: outcome)
      return false
    }
    self.continuation = continuation
    return true
  }

  private func track(_ tasks: [Task<Void, Never>]) {
    if outcome != nil { for task in tasks { task.cancel() } } else { self.tasks = tasks }
  }

  private func resolve(_ result: Result<Value, any Error>) {
    guard outcome == nil else { return }
    outcome = result
    continuation?.resume(with: result)
    continuation = nil
    for task in tasks { task.cancel() }
    tasks = []
  }

  static func run(
    clock: SuggestionClock, deadline: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let race = SuggestionDeadline<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          guard await race.install(continuation) else { return }
          let work = Task {
            do {
              try Task.checkCancellation()
              await race.resolve(.success(try await operation()))
            } catch { await race.resolve(.failure(error)) }
          }
          let timer = Task {
            do {
              try await clock.sleepUntil(deadline)
              await race.resolve(.failure(SuggestionJobFailure.deadline))
            } catch {}
          }
          await race.track([work, timer])
        }
      }
    } onCancel: {
      Task { await race.resolve(.failure(CancellationError())) }
    }
  }
}
