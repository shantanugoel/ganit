/// Large payloads are indirect: values are copied at every evaluation step,
/// and a 171-byte multi-payload enum made the 10,000-line chained edit
/// benchmark 45% slower than boxing the rarely copied cases.
public enum EngineValue: Hashable, Sendable {
  case number(NumericValue)
  case percentage(PercentageValue)
  indirect case quantity(QuantityValue)
  indirect case rate(RateValue)
  case date(DateValue)
  case time(LocalTimeValue)
  indirect case instant(InstantValue)
  case period(CalendarPeriodValue)
  indirect case money(MoneyValue)
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
