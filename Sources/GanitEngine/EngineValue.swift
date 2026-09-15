public enum EngineValue: Hashable, Sendable {
  case number(NumericValue)
  case percentage(PercentageValue)
  case quantity(QuantityValue)
  case rate(RateValue)
  case date(DateValue)
  case time(LocalTimeValue)
  case instant(InstantValue)
  case period(CalendarPeriodValue)
  case money(MoneyValue)
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
    case .quantity:
      return .quantity
    case .rate:
      return .rate
    case .date:
      return .date
    case .time:
      return .time
    case .instant:
      return .instant
    case .period:
      return .period
    case .money:
      return .money
    }
  }
}
