public enum EngineValue: Hashable, Sendable {
  case number(NumericValue)
  case percentage(PercentageValue)
}

public struct PercentageValue: Hashable, Sendable {
  public let points: NumericValue

  public init(points: NumericValue) {
    self.points = points
  }
}

extension EngineValue {
  var kind: EngineValueKind {
    switch self {
    case .number:
      return .number
    case .percentage:
      return .percentage
    }
  }
}
