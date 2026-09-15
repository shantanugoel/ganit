public enum UnitTransform: Hashable, Sendable {
  case ratio(scale: NumericValue)
  case affine(scale: NumericValue, offset: NumericValue)
}

public enum UnitPrefixFamily: String, Hashable, Sendable {
  case decimal
  case binary
}

public struct UnitDefinition: Hashable, Sendable {
  public static let maximumIdentifierLength = 128
  public static let maximumSymbolLength = 64

  public let canonicalIdentifier: String
  public let symbol: String
  public let dimension: Dimension
  public let transform: UnitTransform
  public let allowedPrefixFamilies: Set<UnitPrefixFamily>

  public init(
    canonicalIdentifier: String,
    symbol: String,
    dimension: Dimension,
    transform: UnitTransform,
    allowedPrefixFamilies: Set<UnitPrefixFamily> = []
  ) throws {
    guard
      !canonicalIdentifier.isEmpty,
      !symbol.isEmpty,
      canonicalIdentifier.utf8.count <= Self.maximumIdentifierLength,
      symbol.utf8.count <= Self.maximumSymbolLength,
      transform.scale.isStrictlyPositive
    else {
      throw EngineError(code: .invalidUnitDefinition)
    }
    if case .affine = transform {
      guard dimension == .temperature, allowedPrefixFamilies.isEmpty else {
        throw EngineError(code: .invalidUnitDefinition)
      }
    }
    self.canonicalIdentifier = canonicalIdentifier
    self.symbol = symbol
    self.dimension = dimension
    self.transform = transform
    self.allowedPrefixFamilies = allowedPrefixFamilies
  }
}

public struct UnitPrefix: Hashable, Sendable {
  public let canonicalIdentifier: String
  public let symbol: String
  public let scale: NumericValue
  public let family: UnitPrefixFamily

  public init(
    canonicalIdentifier: String,
    symbol: String,
    scale: NumericValue,
    family: UnitPrefixFamily
  ) throws {
    guard
      !canonicalIdentifier.isEmpty,
      !symbol.isEmpty,
      canonicalIdentifier.utf8.count <= UnitDefinition.maximumIdentifierLength,
      symbol.utf8.count <= UnitDefinition.maximumSymbolLength,
      scale.isStrictlyPositive
    else {
      throw EngineError(code: .invalidUnitDefinition)
    }
    self.canonicalIdentifier = canonicalIdentifier
    self.symbol = symbol
    self.scale = scale
    self.family = family
  }
}

public struct UnitFactor: Hashable, Sendable {
  public let unit: UnitDefinition
  public let exponent: Int
}

public struct RatioUnit: Hashable, Sendable {
  public static let maximumFactorCount = 32

  public let factors: [UnitFactor]
  public let dimension: Dimension
  public let scaleToCanonical: NumericValue

  init(
    factors: [UnitFactor],
    dimension: Dimension,
    scaleToCanonical: NumericValue
  ) {
    self.factors = factors
    self.dimension = dimension
    self.scaleToCanonical = scaleToCanonical
  }

  public var symbol: String {
    let numerator = factors.filter { $0.exponent > 0 }
    let denominator = factors.filter { $0.exponent < 0 }
    let numeratorText =
      numerator.isEmpty ? "1" : numerator.map(render).joined(separator: "·")
    guard !denominator.isEmpty else {
      return numeratorText
    }
    let denominatorText = denominator.map {
      render(UnitFactor(unit: $0.unit, exponent: -$0.exponent))
    }.joined(separator: "·")
    return
      numeratorText + "/"
      + (denominator.count == 1 ? denominatorText : "(\(denominatorText))")
  }

  private func render(_ factor: UnitFactor) -> String {
    factor.exponent == 1
      ? factor.unit.symbol
      : "\(factor.unit.symbol)^\(factor.exponent)"
  }
}

public enum UnitExpression: Hashable, Sendable {
  case ratio(RatioUnit)
  case affine(UnitDefinition)

  public var dimension: Dimension {
    switch self {
    case .ratio(let unit):
      return unit.dimension
    case .affine(let unit):
      return unit.dimension
    }
  }

  public var symbol: String {
    switch self {
    case .ratio(let unit):
      return unit.symbol
    case .affine(let unit):
      return unit.symbol
    }
  }
}

public struct QuantityValue: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case relative
    case absolute
  }

  public let magnitude: NumericValue
  public let unit: UnitExpression
  public let kind: Kind

  public init(
    magnitude: NumericValue,
    unit: UnitExpression,
    kind: Kind? = nil
  ) {
    self.magnitude = magnitude
    self.unit = unit
    self.kind =
      kind ?? (unit.dimension == .temperature ? .absolute : .relative)
  }
}

extension UnitTransform {
  fileprivate var scale: NumericValue {
    switch self {
    case .ratio(let scale), .affine(let scale, _):
      return scale
    }
  }
}

extension NumericValue {
  fileprivate var isStrictlyPositive: Bool {
    switch self {
    case .integer(let integer):
      return !integer.isZero && !integer.isNegative
    case .rational(let rational):
      return !rational.numerator.isZero && !rational.numerator.isNegative
    case .decimal(let decimal):
      return
        !decimal.coefficient.isZero && !decimal.coefficient.isNegative
    case .approximate(let approximate):
      return approximate.estimate > 0
    }
  }
}
