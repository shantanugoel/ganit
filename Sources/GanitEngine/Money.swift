import Foundation

/// An exact amount of one ISO 4217 currency, or a price per unit of
/// something when `unit` is set: `$0.15/kWh`.
public struct MoneyValue: Hashable, Sendable {
  public let amount: NumericValue
  public let currency: String
  public let unit: UnitExpression?

  public init(amount: NumericValue, currency: String, unit: UnitExpression? = nil) {
    self.amount = amount
    self.currency = currency
    self.unit = unit
  }
}

/// Active ISO 4217 currencies and their minor-unit digits.
///
/// Fund, precious-metal, and testing codes are excluded. Source: ISO 4217
/// list one, as amended through 2025.
public enum CurrencyCatalog {
  public static let minorUnits: [String: Int] = {
    var table: [String: Int] = [:]
    let twoDigits = """
      AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BGN BMD BND BOB BRL BSD BTN BWP BYN BZD \
      CAD CDF CHF CNY COP CRC CUP CVE CZK DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP \
      GMD GTQ GYD HKD HNL HTG HUF IDR ILS INR IRR JMD KES KGS KHR KPW KYD KZT LAK LBP LKR LRD \
      LSL MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD PAB \
      PEN PGK PHP PKR PLN QAR RON RSD RUB SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC \
      SYP SZL THB TJS TMT TOP TRY TTD TWD TZS UAH USD UYU UZS VED VES WST XCD XCG YER ZAR ZMW \
      ZWG
      """
    for code in twoDigits.split(separator: " ") {
      table[String(code)] = 2
    }
    for code in "BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX VND VUV XAF XOF XPF".split(
      separator: " ")
    {
      table[String(code)] = 0
    }
    for code in "BHD IQD JOD KWD LYD OMR TND".split(separator: " ") {
      table[String(code)] = 3
    }
    return table
  }()

  /// Symbols that name exactly one currency.
  public static let symbols: [String: String] = [
    "€": "EUR", "£": "GBP", "₹": "INR", "₩": "KRW", "₪": "ILS", "₺": "TRY", "₽": "RUB",
    "₱": "PHP", "฿": "THB", "₫": "VND", "₴": "UAH", "₦": "NGN", "US$": "USD", "C$": "CAD",
    "CA$": "CAD", "A$": "AUD", "AU$": "AUD", "NZ$": "NZD", "HK$": "HKD", "S$": "SGD",
    "R$": "BRL", "MX$": "MXN",
  ]

  /// Symbols shared by several currencies until a sheet picks one: `$` means
  /// the sheet's dollar currency (USD unless changed), and `¥` means JPY.
  public static let ambiguousSymbols: Set<String> = ["$", "¥"]

  /// English names people write after an amount: `5 dollars`.
  public static let names: [String: String] = [
    "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
    "euro": "EUR", "euros": "EUR",
    "pound": "GBP", "pounds": "GBP",
    "yen": "JPY",
    "rupee": "INR", "rupees": "INR",
    "yuan": "CNY",
    "won": "KRW",
    "peso": "MXN", "pesos": "MXN",
  ]

  /// Currencies a `$` can mean; USD is the default.
  public static let dollarCurrencies = ["USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN"]

  /// The currency a symbol writes, given this sheet's choice for `$`.
  public static func currency(for symbol: String, dollarCurrency: String) -> String? {
    if symbol == "$" {
      return minorUnits[dollarCurrency] != nil ? dollarCurrency : "USD"
    }
    if symbol == "¥" {
      return "JPY"
    }
    return symbols[symbol]
  }
}

/// How a conversion got its exchange rate.
public enum CurrencyRateUse: Hashable, Sendable {
  /// A published euro reference rate.
  case reference
  /// A rate between two non-euro currencies divided from reference rates.
  case crossReference
  /// A rate declared in the sheet.
  case manual
}

/// Euro reference rates for converting between currencies.
public struct CurrencyRates: Hashable, Sendable {
  public static let none = CurrencyRates(units: [:], observationDate: nil, retrievedAt: nil)

  /// Units of each currency per euro.
  let units: [String: NumericValue]
  /// The publication date, `YYYY-MM-DD`, or `nil` without downloaded rates.
  public let observationDate: String?
  public let retrievedAt: Date?

  private init(units: [String: NumericValue], observationDate: String?, retrievedAt: Date?) {
    self.units = units
    self.observationDate = observationDate
    self.retrievedAt = retrievedAt
  }

  /// Rates as published decimal strings of units per euro.
  public init(unitsPerEuro: [String: String], observationDate: String, retrievedAt: Date) throws {
    var units: [String: NumericValue] = [:]
    for (currency, text) in unitsPerEuro {
      let parts = text.split(separator: ".", omittingEmptySubsequences: false)
      guard CurrencyCatalog.minorUnits[currency] != nil, parts.count <= 2 else {
        throw EngineError(code: .invalidCurrencyRate)
      }
      let rate = NumericValue.decimal(
        try DecimalValue(
          coefficient: IntegerValue(parts.joined()),
          scale: parts.count == 2 ? parts[1].utf8.count : 0
        )
      )
      units[currency] = rate
    }
    self.units = units
    self.observationDate = observationDate
    self.retrievedAt = retrievedAt
  }
}

/// A manual exchange rate: one unit of `from` is `rate` units of `to`.
public struct CurrencyPair: Hashable, Sendable {
  public let from: String
  public let to: String

  public init(from: String, to: String) {
    self.from = from
    self.to = to
  }
}

/// Arithmetic and conversion of money. Amounts stay exact; different
/// currencies never combine without an explicit conversion.
struct MoneyArithmetic {
  let operations: NumericOperations
  let rates: CurrencyRates
  let manualRates: [CurrencyPair: NumericValue]

  /// The result of a money operation, or `nil` when neither operand is money.
  /// `unitAlgebra` converts a quantity a price per unit applies to.
  func apply(
    _ binaryOperator: BinaryOperator, left: EngineValue, right: EngineValue,
    unitAlgebra: UnitAlgebra
  ) throws -> EngineValue? {
    switch (left, right) {
    case (.money(let lhs), .money(let rhs)):
      guard lhs.currency == rhs.currency else {
        throw EngineError(code: .mixedCurrencies)
      }
      guard lhs.unit == rhs.unit else {
        throw mismatch(.money, .money)
      }
      switch binaryOperator {
      case .add, .subtract:
        return .money(try amount(binaryOperator, lhs, rhs.amount))
      case .divide:
        return .number(
          try operations.applying(.divide, left: lhs.amount, right: rhs.amount))
      case .multiply, .power:
        throw mismatch(.number, .money)
      }
    case (.money(let money), .number(let number)):
      guard binaryOperator == .multiply || binaryOperator == .divide else {
        throw mismatch(.money, .number)
      }
      return .money(try amount(binaryOperator, money, number))
    case (.number(let number), .money(let money)):
      guard binaryOperator == .multiply else {
        throw mismatch(.number, .money)
      }
      return .money(try amount(.multiply, money, number))
    case (.money(let money), .percentage(let percentage)):
      let rate = try operations.applying(
        .divide, left: percentage.points, right: .integer(IntegerValue(100)))
      switch binaryOperator {
      case .add, .subtract:
        let change = try operations.applying(.multiply, left: money.amount, right: rate)
        return .money(try amount(binaryOperator, money, change))
      case .multiply, .divide:
        return .money(try amount(binaryOperator, money, rate))
      case .power:
        throw mismatch(.number, .percentage)
      }
    case (.percentage(let percentage), .money(let money)) where binaryOperator == .multiply:
      let rate = try operations.applying(
        .divide, left: percentage.points, right: .integer(IntegerValue(100)))
      return .money(try amount(.multiply, money, rate))
    // A price per unit: `$30 / 2 kWh` is `$15/kWh`, and `$15/kWh * 3 kWh` is `$45`.
    case (.money(let money), .quantity(let quantity))
    where binaryOperator == .divide && money.unit == nil:
      guard case .ratio = quantity.unit, quantity.kind == .relative else {
        throw mismatch(.money, .quantity)
      }
      return .money(
        MoneyValue(
          amount: try operations.applying(.divide, left: money.amount, right: quantity.magnitude),
          currency: money.currency, unit: quantity.unit))
    case (.money(let money), .quantity(let quantity)) where binaryOperator == .multiply:
      return .money(try priced(money, quantity, unitAlgebra))
    case (.quantity(let quantity), .money(let money)) where binaryOperator == .multiply:
      return .money(try priced(money, quantity, unitAlgebra))
    case (.money, _), (_, .money):
      throw mismatch(.money, left.kind == .money ? right.kind : left.kind)
    default:
      return nil
    }
  }

  /// Converts money with a manual rate when one is declared for the pair,
  /// and otherwise with euro reference rates.
  /// Returns the rate's kind, or `nil` when the currencies are the same.
  func converted(_ money: MoneyValue, to currency: String) throws -> (
    MoneyValue, CurrencyRateUse?
  ) {
    let (rate, use) = try self.rate(from: money.currency, to: currency)
    return (
      MoneyValue(
        amount: try operations.applying(.multiply, left: money.amount, right: rate),
        currency: currency, unit: money.unit
      ), use
    )
  }

  private func rate(from: String, to: String) throws -> (NumericValue, CurrencyRateUse?) {
    let one = NumericValue.integer(IntegerValue(1))
    if from == to {
      return (one, nil)
    }
    if let rate = manualRates[CurrencyPair(from: from, to: to)] {
      return (rate, .manual)
    }
    if let rate = manualRates[CurrencyPair(from: to, to: from)] {
      return (try operations.applying(.divide, left: one, right: rate), .manual)
    }
    guard rates.observationDate != nil else {
      throw EngineError(code: .currencyRatesUnavailable)
    }
    let fromUnits = from == "EUR" ? one : rates.units[from]
    let toUnits = to == "EUR" ? one : rates.units[to]
    guard let fromUnits, let toUnits else {
      throw EngineError(code: .missingCurrencyRate)
    }
    return (
      try operations.applying(.divide, left: toUnits, right: fromUnits),
      from == "EUR" || to == "EUR" ? .reference : .crossReference
    )
  }

  private func amount(_ binaryOperator: BinaryOperator, _ money: MoneyValue, _ number: NumericValue)
    throws -> MoneyValue
  {
    MoneyValue(
      amount: try operations.applying(binaryOperator, left: money.amount, right: number),
      currency: money.currency, unit: money.unit
    )
  }

  /// A price per unit times an amount of that unit, in the price's unit.
  private func priced(_ money: MoneyValue, _ quantity: QuantityValue, _ unitAlgebra: UnitAlgebra)
    throws -> MoneyValue
  {
    guard let unit = money.unit, quantity.kind == .relative else {
      throw mismatch(.money, .quantity)
    }
    let amount = try unitAlgebra.converted(quantity, to: unit).magnitude
    return MoneyValue(
      amount: try operations.applying(.multiply, left: money.amount, right: amount),
      currency: money.currency)
  }

  private func mismatch(_ expected: EngineValueKind, _ actual: EngineValueKind) -> EngineError {
    EngineError(code: .typeMismatch, context: .typeMismatch(expected: expected, actual: actual))
  }
}
