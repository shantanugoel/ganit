public enum RateAmount: Hashable, Sendable {
  case number(NumericValue)
  case percentage(PercentageValue)
}

public enum CalendarRatePeriod: String, Hashable, Sendable {
  case month
  case quarter
  case year

  var months: Int {
    switch self {
    case .month:
      return 1
    case .quarter:
      return 3
    case .year:
      return 12
    }
  }
}

public enum RateDenominator: Hashable, Sendable {
  case unit(UnitExpression)
  case calendar(CalendarRatePeriod)

  public var dimension: Dimension {
    switch self {
    case .unit(let unit):
      return unit.dimension
    case .calendar:
      return .time
    }
  }

  public var symbol: String {
    switch self {
    case .unit(let unit):
      return unit.symbol
    case .calendar(let period):
      return period.rawValue
    }
  }
}

public struct RateValue: Hashable, Sendable {
  public let amount: RateAmount
  public let denominator: RateDenominator

  public init(
    amount: RateAmount,
    denominator: RateDenominator
  ) throws {
    if case .unit(let unit) = denominator {
      guard case .ratio = unit else {
        throw EngineError(code: .affineUnitInCompound)
      }
    }
    self.amount = amount
    self.denominator = denominator
  }
}
