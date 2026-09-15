import GanitDiagnostics
import GanitEngine

/// Serializes incremental evaluation off the main actor and owns its cache.
private actor CalculatorWorker {
  private var calculator = SheetCalculator()

  func evaluate(_ sheet: SheetSource, context: EvaluationContext) throws -> SheetEvaluation {
    try calculator.evaluate(sheet, context: context)
  }
}

/// Starts a generation for each sheet snapshot and delivers only the newest
/// completed evaluation. Starting a generation cancels the previous one.
@MainActor
final class SheetEvaluationScheduler {
  private let worker = CalculatorWorker()
  private let context: EvaluationContext
  private let commit: @MainActor (SheetSource, SheetEvaluation, SignpostedInterval) -> Void
  private var task: Task<Void, Never>?
  private var latestRequest = 0

  /// `commit` receives the evaluated snapshot, its evaluation, and the
  /// edit-to-answer interval started when the snapshot was scheduled.
  init(
    context: EvaluationContext,
    commit: @escaping @MainActor (SheetSource, SheetEvaluation, SignpostedInterval) -> Void
  ) {
    self.context = context
    self.commit = commit
  }

  func schedule(_ sheet: SheetSource) {
    task?.cancel()
    latestRequest += 1
    let request = latestRequest
    let worker = worker
    let context = context
    let editToAnswer = SignpostedInterval.begin("EditToAnswer")
    task = Task {
      let evaluationInterval = SignpostedInterval.begin("Evaluation")
      let evaluation = try? await worker.evaluate(sheet, context: context)
      guard let evaluation, request == latestRequest else {
        evaluationInterval.cancel()
        editToAnswer.cancel()
        return
      }
      evaluationInterval.end()
      commit(sheet, evaluation, editToAnswer)
    }
  }

  /// Cancels the running generation, leaving the last shown evaluation.
  func cancel() {
    task?.cancel()
    latestRequest += 1
  }

  /// Waits for the newest scheduled generation to finish or be superseded.
  func waitUntilIdle() async {
    while let current = task {
      await current.value
      if task == current {
        return
      }
    }
  }
}
