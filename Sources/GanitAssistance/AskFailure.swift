import GanitEngine

/// A failed Ask has no proposal to apply.
public enum AskFailure: Sendable {
  case notGanitSource
  case rejectedByEngine(AssistanceValidationFailure)
  case unreachable
  case noUsefulAnswer
}
