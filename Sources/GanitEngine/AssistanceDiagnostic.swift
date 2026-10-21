import Foundation

/// Native diagnostic data from the same evaluation generation as the target.
public struct AssistanceDiagnostic: Encodable, Sendable {
  public let code: String
  public let severity: String
  public let spans: [Span]
  public let expected: String?
  public let fixes: [Fix]

  public struct Span: Encodable, Sendable {
    public let utf8Start: Int
    public let utf8End: Int
    public let graphemeStart: Int
    public let graphemeEnd: Int
    init(_ range: SourceRange) {
      utf8Start = range.lowerBound
      utf8End = range.upperBound
      graphemeStart = range.graphemeLowerBound
      graphemeEnd = range.graphemeUpperBound
    }
  }
  public struct Fix: Encodable, Sendable {
    public let span: Span
    public let replacement: String
  }

  static func records(_ result: CalculationResult?, origin: SourceLocation = .start)
    -> [AssistanceDiagnostic]
  {
    switch result {
    case .syntaxFailure(let diagnostics):
      return diagnostics.map {
        AssistanceDiagnostic(
          code: $0.messageKey, severity: $0.severity.rawValue,
          spans: [Span($0.range.shifted(by: origin))], expected: nil, fixes: [])
      }
    case .evaluationFailure(let error):
      let expected: String?
      switch error.context {
      case .typeMismatch(let kind, _): expected = String(describing: kind)
      case .dimensionMismatch(let dimension, _): expected = dimension.canonicalDescription
      default: expected = nil
      }
      return [
        AssistanceDiagnostic(
          code: error.code.rawValue, severity: error.severity.rawValue,
          spans: error.ranges.map { Span($0.shifted(by: origin)) }, expected: expected,
          fixes: error.fixIts.map {
            Fix(span: Span($0.range.shifted(by: origin)), replacement: $0.replacement)
          })
      ]
    default: return []
    }
  }
}
