import Foundation

/// An exact engine value for the permitted context. Display rounding does not apply.
public struct AssistanceValue: Encodable, Sendable {
  public let value: EngineValue

  public init(_ value: EngineValue) {
    self.value = value
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: Key.self)
    try fields.encode(String(describing: value.kind), forKey: .kind)
    switch value {
    case .number(let number):
      try fields.encode(AssistanceNumber(number), forKey: .amount)
    case .percentage(let percent):
      try fields.encode(AssistanceNumber(percent.points), forKey: .points)
    case .quantity(let quantity):
      try fields.encode(AssistanceNumber(quantity.magnitude), forKey: .magnitude)
      try fields.encode(AssistanceUnit(quantity.unit), forKey: .unit)
      try fields.encode(quantity.kind == .absolute ? "absolute" : "relative", forKey: .quantityKind)
    case .money(let money):
      try fields.encode(AssistanceNumber(money.amount), forKey: .amount)
      try fields.encode(money.currency, forKey: .currency)
      try fields.encodeIfPresent(money.unit.map(AssistanceUnit.init), forKey: .unit)
    case .rate(let rate):
      switch rate.amount {
      case .number(let amount):
        try fields.encode(AssistanceNumber(amount), forKey: .amount)
        try fields.encode("number", forKey: .amountKind)
      case .percentage(let percent):
        try fields.encode(AssistanceNumber(percent.points), forKey: .points)
        try fields.encode("percentage", forKey: .amountKind)
      }
      switch rate.denominator {
      case .unit(let unit):
        try fields.encode(AssistanceUnit(unit), forKey: .unit)
      case .calendar(let period):
        try fields.encode(period.rawValue, forKey: .calendarPeriod)
      }
    case .date(let date):
      try fields.encode(date.year, forKey: .year)
      try fields.encode(date.month, forKey: .month)
      try fields.encode(date.day, forKey: .day)
    case .time(let time):
      try fields.encode(time.secondsSinceMidnight, forKey: .secondsSinceMidnight)
    case .instant(let instant):
      try fields.encode(instant.date.timeIntervalSince1970, forKey: .secondsSince1970)
      try fields.encode(instant.timeZoneIdentifier, forKey: .timeZone)
    case .period(let period):
      try fields.encode(period.months, forKey: .months)
      try fields.encode(period.days, forKey: .days)
    }
  }

  private enum Key: String, CodingKey {
    case kind, amount, points, magnitude, unit, quantityKind, currency, amountKind
    case calendarPeriod, year, month, day, secondsSinceMidnight, secondsSince1970, timeZone
    case months, days
  }
}

public struct AssistanceNumber: Encodable, Sendable {
  public let value: NumericValue

  public init(_ value: NumericValue) {
    self.value = value
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: Key.self)
    switch value {
    case .integer(let integer):
      try fields.encode("integer", forKey: .kind)
      try fields.encode(integer.canonicalDigits, forKey: .digits)
    case .rational(let rational):
      try fields.encode("rational", forKey: .kind)
      try fields.encode(rational.numerator.canonicalDigits, forKey: .numerator)
      try fields.encode(rational.denominator.canonicalDigits, forKey: .denominator)
    case .decimal(let decimal):
      try fields.encode("decimal", forKey: .kind)
      try fields.encode(decimal.coefficient.canonicalDigits, forKey: .coefficient)
      try fields.encode(decimal.scale, forKey: .scale)
    case .approximate(let approximate):
      try fields.encode("approximate", forKey: .kind)
      try fields.encode(approximate.estimate, forKey: .estimate)
      try fields.encode(approximate.source.rawValue, forKey: .source)
      switch approximate.precision {
      case .significantDecimalDigits(let digits):
        try fields.encode("significantDecimalDigits", forKey: .precision)
        try fields.encode(digits, forKey: .digits)
      case .requestedSignificantDecimalDigits(let digits):
        try fields.encode("requestedSignificantDecimalDigits", forKey: .precision)
        try fields.encode(digits, forKey: .digits)
      case .absoluteErrorBound(let error):
        try fields.encode("absoluteErrorBound", forKey: .precision)
        try fields.encode(AssistanceNumber(.decimal(error)), forKey: .errorBound)
      case .unspecified:
        try fields.encode("unspecified", forKey: .precision)
      }
    }
  }

  private enum Key: String, CodingKey {
    case kind, digits, numerator, denominator, coefficient, scale, estimate, source, precision
    case errorBound
  }
}

/// Unit identity, dimensions and scale remain separate from the displayed symbol.
struct AssistanceUnit: Encodable, Sendable {
  let value: UnitExpression

  init(_ value: UnitExpression) { self.value = value }

  struct Factor: Encodable {
    let identifier: String
    let exponent: Int
  }

  func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: Key.self)
    try fields.encode(value.symbol, forKey: .symbol)
    try fields.encode(
      Dictionary(
        uniqueKeysWithValues: BaseDimension.allCases.compactMap { base in
          value.dimension[base] == 0 ? nil : (base.rawValue, value.dimension[base])
        }), forKey: .dimension)
    switch value {
    case .ratio(let unit):
      try fields.encode("ratio", forKey: .kind)
      try fields.encode(AssistanceNumber(unit.scaleToCanonical), forKey: .scale)
      try fields.encode(
        unit.factors.map {
          Factor(identifier: $0.unit.canonicalIdentifier, exponent: $0.exponent)
        }, forKey: .factors)
    case .affine(let unit):
      try fields.encode("affine", forKey: .kind)
      try fields.encode(unit.canonicalIdentifier, forKey: .identifier)
      switch unit.transform {
      case .ratio(let scale):
        try fields.encode(AssistanceNumber(scale), forKey: .scale)
      case .affine(let scale, let offset):
        try fields.encode(AssistanceNumber(scale), forKey: .scale)
        try fields.encode(AssistanceNumber(offset), forKey: .offset)
      }
    }
  }

  private enum Key: String, CodingKey {
    case symbol, dimension, kind, scale, factors, identifier, offset
  }
}
