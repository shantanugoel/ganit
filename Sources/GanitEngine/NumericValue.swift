import BigInt

public enum NumericValue: Hashable, Sendable {
  case integer(IntegerValue)
  case rational(RationalValue)
  case decimal(DecimalValue)
  case approximate(ApproximateValue)
}

public struct IntegerValue: Hashable, Sendable {
  public static let maximumTextDigits = 10_000

  let storage: BigInt

  public init(_ value: Int) {
    storage = BigInt(value)
  }

  public init(
    _ digits: String,
    radix: NumericRadix = .decimal
  ) throws {
    let digitCount =
      digits.first == "-" || digits.first == "+"
      ? digits.utf8.count - 1
      : digits.utf8.count
    guard digitCount <= Self.maximumTextDigits else {
      throw EngineError(
        code: .integerLiteralTooLong,
        context: .maximumIntegerDigits(Self.maximumTextDigits)
      )
    }
    guard let value = BigInt(digits, radix: radix.rawValue) else {
      throw EngineError(code: .invalidIntegerLiteral)
    }
    storage = value
  }

  init(storage: BigInt) {
    self.storage = storage
  }

  public var isZero: Bool {
    storage == 0
  }

  public var isNegative: Bool {
    storage < 0
  }

  public var canonicalDigits: String {
    String(storage)
  }

  /// The magnitude's digits in a base, for a sheet that writes hexadecimal or
  /// binary; the sign is written separately.
  public func magnitudeDigits(radix: NumericRadix) -> String {
    String(storage.magnitude, radix: radix.rawValue)
  }

  public var magnitudeBitWidth: Int {
    storage.magnitude.bitWidth
  }
}

public struct RationalValue: Hashable, Sendable {
  public let numerator: IntegerValue
  public let denominator: IntegerValue

  public init(
    numerator: IntegerValue,
    denominator: IntegerValue
  ) throws {
    guard !denominator.isZero else {
      throw EngineError(code: .zeroDenominator)
    }

    var normalizedNumerator = numerator.storage
    var normalizedDenominator = denominator.storage
    if normalizedDenominator < 0 {
      normalizedNumerator = -normalizedNumerator
      normalizedDenominator = -normalizedDenominator
    }

    let divisor = normalizedNumerator.greatestCommonDivisor(
      with: normalizedDenominator
    )
    self.numerator = IntegerValue(storage: normalizedNumerator / divisor)
    self.denominator = IntegerValue(storage: normalizedDenominator / divisor)
  }

  /// The decimal closest to this fraction with at most `significantDigits`
  /// significant digits and no trailing zeroes.
  ///
  /// The fraction remains the exact value. A reader needs `7.456454306848`
  /// rather than `31250/4191`, so display rounds while the value does not.
  public func decimal(
    significantDigits: Int,
    rule: RoundingRule = .toNearestOrEven
  ) throws -> DecimalValue {
    guard significantDigits > 0 else {
      throw EngineError(
        code: .invalidApproximationPrecision,
        context: .significantDecimalDigits(significantDigits)
      )
    }
    guard !numerator.isZero else {
      return try DecimalValue(coefficient: IntegerValue(0), scale: 0)
    }

    // With `a` digits of magnitude over `b` of denominator, the value lies
    // between 10^(a - b - 1) and 10^(a - b + 1), leaving two candidates for
    // its base-10 exponent.
    let magnitude = BigInt(numerator.storage.magnitude)
    let denominator = self.denominator.storage
    let candidate = magnitude.decimalDigitCount - denominator.decimalDigitCount
    let exponent =
      isAtLeastPowerOfTen(magnitude, over: denominator, exponent: candidate)
      ? candidate
      : candidate - 1
    var scale = significantDigits - exponent - 1

    var coefficient = try roundedQuotient(
      scale >= 0 ? numerator.storage * powerOfTen(scale) : numerator.storage,
      scale >= 0 ? denominator : denominator * powerOfTen(-scale),
      rule: rule.floatingPointRule
    )
    // Rounding 9.99 to two digits carries into 10.0, one digit too many.
    // Trimming the trailing zeroes a carry leaves also restores the count.
    while scale > 0, !coefficient.isZero, coefficient % 10 == 0 {
      coefficient /= 10
      scale -= 1
    }
    return try DecimalValue(
      coefficient: IntegerValue(storage: coefficient),
      scale: scale
    )
  }
}

/// The integer closest to `numerator / denominator` under `rule`, for a
/// positive `denominator`.
func roundedQuotient(
  _ numerator: BigInt,
  _ denominator: BigInt,
  rule: FloatingPointRoundingRule
) throws -> BigInt {
  let quotient = numerator / denominator
  let remainder = numerator % denominator
  guard !remainder.isZero else {
    return quotient
  }
  let awayFromZero = quotient + (numerator < 0 ? -1 : 1)

  switch rule {
  case .down:
    return numerator < 0 ? awayFromZero : quotient
  case .up:
    return numerator < 0 ? quotient : awayFromZero
  case .towardZero:
    return quotient
  case .awayFromZero:
    return awayFromZero
  case .toNearestOrEven:
    let doubledRemainder = remainder.magnitude * 2
    if doubledRemainder < denominator.magnitude {
      return quotient
    }
    if doubledRemainder > denominator.magnitude {
      return awayFromZero
    }
    return quotient % 2 == 0 ? quotient : awayFromZero
  case .toNearestOrAwayFromZero:
    return remainder.magnitude * 2 < denominator.magnitude
      ? quotient
      : awayFromZero
  default:
    throw EngineError(code: .invalidDomain)
  }
}

private func powerOfTen(_ exponent: Int) -> BigInt {
  BigInt(10).power(exponent)
}

/// Whether `magnitude / denominator` is at least `10^exponent`, comparing
/// exactly rather than through a logarithm.
private func isAtLeastPowerOfTen(
  _ magnitude: BigInt,
  over denominator: BigInt,
  exponent: Int
) -> Bool {
  exponent >= 0
    ? magnitude >= denominator * powerOfTen(exponent)
    : magnitude * powerOfTen(-exponent) >= denominator
}

extension BigInt {
  fileprivate var decimalDigitCount: Int {
    String(magnitude).count
  }
}

public struct DecimalValue: Hashable, Sendable {
  public let coefficient: IntegerValue
  public let scale: Int

  public init(coefficient: IntegerValue, scale: Int) throws {
    guard scale != .min else {
      throw EngineError(code: .invalidDecimalScale)
    }
    self.coefficient = coefficient
    self.scale = scale
  }

  /// This value with at most `significantDigits` significant digits and no
  /// trailing zeroes, as a fraction is shown: `125.00` reads `125`.
  public func decimal(
    significantDigits: Int,
    rule: RoundingRule = .toNearestOrEven
  ) throws -> DecimalValue {
    try RationalValue(
      numerator: IntegerValue(
        storage: scale >= 0 ? coefficient.storage : coefficient.storage * powerOfTen(-scale)),
      denominator: IntegerValue(storage: scale >= 0 ? powerOfTen(scale) : 1)
    ).decimal(significantDigits: significantDigits, rule: rule)
  }
}

public enum ApproximationSource: String, Hashable, Sendable {
  case mathematicalConstant
  case transcendentalFunction
  case iterativeMethod
  case explicitRounding
  case binaryFloatingPointConversion
  case derivedArithmetic
}

public enum ApproximationPrecision: Hashable, Sendable {
  case significantDecimalDigits(Int)
  case requestedSignificantDecimalDigits(Int)
  case absoluteErrorBound(DecimalValue)
  case unspecified
}

public struct ApproximateValue: Hashable, Sendable {
  public static let maximumSignificantDecimalDigits = 17

  public let estimate: Double
  public let source: ApproximationSource
  public let precision: ApproximationPrecision

  public init(
    estimate: Double,
    source: ApproximationSource,
    precision: ApproximationPrecision
  ) throws {
    guard estimate.isFinite else {
      throw EngineError(code: .nonFiniteApproximation)
    }

    switch precision {
    case .significantDecimalDigits(let digits),
      .requestedSignificantDecimalDigits(let digits):
      guard digits > 0, digits <= Self.maximumSignificantDecimalDigits else {
        throw EngineError(
          code: .invalidApproximationPrecision,
          context: .significantDecimalDigits(digits)
        )
      }
    case .absoluteErrorBound(let error):
      guard !error.coefficient.isNegative else {
        throw EngineError(code: .negativeApproximationErrorBound)
      }
    case .unspecified:
      break
    }

    self.estimate = estimate == 0 ? 0 : estimate
    self.source = source
    self.precision = precision
  }
}

extension NumericValue {
  /// This value rounded to `fractionDigits` digits after the decimal point,
  /// and whether rounding changed it.
  ///
  /// Money displays at its currency's minor units. A monthly payment is an
  /// exact fraction with hundreds of digits, so the rounding runs on the
  /// value itself rather than on a binary or fixed-width copy of it.
  public func rounded(
    fractionDigits: Int,
    rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
  ) throws -> (value: DecimalValue, isRounded: Bool) {
    guard fractionDigits >= 0 else {
      throw EngineError(code: .invalidDecimalScale)
    }
    let numerator: BigInt
    let denominator: BigInt
    switch self {
    case .integer(let integer):
      (numerator, denominator) = (integer.storage, 1)
    case .rational(let rational):
      (numerator, denominator) = (
        rational.numerator.storage, rational.denominator.storage
      )
    case .decimal(let decimal):
      (numerator, denominator) =
        decimal.scale >= 0
        ? (decimal.coefficient.storage, powerOfTen(decimal.scale))
        : (decimal.coefficient.storage * powerOfTen(-decimal.scale), 1)
    case .approximate:
      throw EngineError(code: .invalidDomain)
    }

    let scaled = numerator * powerOfTen(fractionDigits)
    let coefficient = try roundedQuotient(scaled, denominator, rule: rule)
    return (
      try DecimalValue(
        coefficient: IntegerValue(storage: coefficient),
        scale: fractionDigits
      ),
      coefficient * denominator != scaled
    )
  }

  public var isNegative: Bool {
    switch self {
    case .integer(let integer):
      return integer.isNegative
    case .rational(let rational):
      return rational.numerator.isNegative
    case .decimal(let decimal):
      return decimal.coefficient.isNegative
    case .approximate(let approximate):
      return approximate.estimate < 0
    }
  }

  public var isZero: Bool {
    switch self {
    case .integer(let integer):
      return integer.isZero
    case .rational(let rational):
      return rational.numerator.isZero
    case .decimal(let decimal):
      return decimal.coefficient.isZero
    case .approximate(let approximate):
      return approximate.estimate == 0
    }
  }
}
