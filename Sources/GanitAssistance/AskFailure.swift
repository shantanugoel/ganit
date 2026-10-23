import GanitEngine

/// A failed Ask has no proposal to apply.
public enum AskFailure: Sendable {
  case notGanitSource
  /// The model answered or explained in words that contained numbers, which only
  /// Ganit's own engine may produce.
  case modelSuppliedNumbers
  case rejectedByEngine(AssistanceValidationFailure)
  case unreachable
  case noUsefulAnswer
}
