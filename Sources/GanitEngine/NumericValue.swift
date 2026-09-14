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
    case .significantDecimalDigits(let digits):
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
