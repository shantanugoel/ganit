import Foundation
import GanitDiagnostics
import GanitEngine

/// Serializes incremental evaluation off the main actor and owns its cache.
private actor CalculatorWorker {
  private var calculator = SheetCalculator()

  func evaluate(_ sheet: SheetSource, context: EvaluationContext) throws -> SheetEvaluation {
    try calculator.evaluate(sheet, context: context)
  }

  /// Starts over with new definitions, which every line may read.
  func setDefinitions(_ definitions: SheetDefinitions) {
    calculator = SheetCalculator(definitions: definitions)
  }
}

/// Starts a generation for each sheet snapshot and delivers only the newest
/// completed evaluation. Starting a generation cancels the previous one.
///
/// Each generation evaluates at the current time. When a result read the
/// clock, one recalculation waits for the earliest moment it can change, such
/// as the next midnight for `today`; sheets that do not read the clock never
/// wake.
@MainActor
final class SheetEvaluationScheduler {
  private let worker = CalculatorWorker()
  /// The context each generation evaluates in, at the current time.
  var context: EvaluationContext
  /// The definitions generations evaluate with, for comparing new ones.
  private(set) var definitions: SheetDefinitions = .none
  private let commit: @MainActor (SheetSource, SheetEvaluation, SignpostedInterval) -> Void
  private var task: Task<Void, Never>?
  private(set) var recalculation: Task<Void, Never>?
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

  /// Evaluates with new definitions from the next generation on, discarding
  /// the cache because any line's answer may change.
  func setDefinitions(_ definitions: SheetDefinitions, of sheet: SheetSource) {
    self.definitions = definitions
    task?.cancel()
    recalculation?.cancel()
    recalculation = nil
    latestRequest += 1
    let request = latestRequest
    let worker = worker
    task = Task {
      await worker.setDefinitions(definitions)
      guard request == latestRequest else {
        return
      }
      schedule(sheet)
    }
  }

  func schedule(_ sheet: SheetSource) {
    task?.cancel()
    recalculation?.cancel()
    recalculation = nil
    latestRequest += 1
    let request = latestRequest
    let worker = worker
    let context = context.at(Date())
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
      if let next = evaluation.nextRecalculation {
        recalculate(sheet, at: next)
      }
    }
  }

  /// Evaluates the sheet again at a moment. The continuous clock keeps
  /// counting while the Mac sleeps, so a boundary passed during sleep fires on
  /// wake.
  private func recalculate(_ sheet: SheetSource, at date: Date) {
    recalculation = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)), clock: .continuous)
      guard !Task.isCancelled else {
        return
      }
      self?.schedule(sheet)
    }
  }

  /// Cancels the running generation, leaving the last shown evaluation.
  func cancel() {
    task?.cancel()
    recalculation?.cancel()
    recalculation = nil
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
