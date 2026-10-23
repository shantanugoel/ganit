import GanitEngine

/// A failed Ask has no proposal to apply.
public enum AskFailure: Sendable {
  case notGanitSource
  /// The model answered or explained in words that contained numbers, which only
  /// Ganit's own engine may produce.
  case modelSuppliedNumbers
  /// The model answered in words on a line whose answer is a calculation Ganit
  /// can check itself.
  case answerNotApplicable
  /// The model explained a line the reader had not asked it to explain.
  case explanationNotRequested
  case rejectedByEngine(AssistanceValidationFailure)
  case unreachable
  case noUsefulAnswer
}
