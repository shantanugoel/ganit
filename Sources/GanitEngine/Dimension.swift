public enum BaseDimension: String, CaseIterable, Hashable, Sendable {
  case length
  case mass
  case time
  case temperature
  case angle
  case data
}

public struct Dimension: Hashable, Sendable {
  public static let maximumExponentMagnitude = 64

  private let exponents: [BaseDimension: Int]

  private init(knownExponents: [BaseDimension: Int]) {
    exponents = knownExponents
  }

  public init() {
    exponents = [:]
  }

  public init(_ base: BaseDimension) {
    exponents = [base: 1]
  }

  public init(exponents: [BaseDimension: Int]) throws {
    var normalized: [BaseDimension: Int] = [:]
    for (base, exponent) in exponents where exponent != 0 {
      guard exponent.magnitude <= Self.maximumExponentMagnitude else {
        throw EngineError(
          code: .resourceLimitExceeded,
          context: .resourceLimit(.dimensionExponent)
        )
      }
      normalized[base] = exponent
    }
    self.exponents = normalized
  }

  public static let dimensionless = Dimension()

  public subscript(_ base: BaseDimension) -> Int {
    exponents[base, default: 0]
  }

  public func multiplied(by other: Dimension) throws -> Dimension {
    try combining(with: other, sign: 1)
  }

  public func divided(by other: Dimension) throws -> Dimension {
    try combining(with: other, sign: -1)
  }

  public func raised(to exponent: Int) throws -> Dimension {
    var result: [BaseDimension: Int] = [:]
    for (base, value) in exponents {
      let (product, overflow) = value.multipliedReportingOverflow(by: exponent)
      guard
        !overflow,
        product.magnitude <= Self.maximumExponentMagnitude
      else {
        throw EngineError(
          code: .resourceLimitExceeded,
          context: .resourceLimit(.dimensionExponent)
        )
      }
      if product != 0 {
        result[base] = product
      }
    }
    return try Dimension(exponents: result)
  }

  private func combining(
    with other: Dimension,
    sign: Int
  ) throws -> Dimension {
    var result = exponents
    for base in BaseDimension.allCases {
      let (adjustment, multiplicationOverflow) = other[base]
        .multipliedReportingOverflow(by: sign)
      let (sum, additionOverflow) = self[base]
        .addingReportingOverflow(adjustment)
      guard
        !multiplicationOverflow,
        !additionOverflow,
        sum.magnitude <= Self.maximumExponentMagnitude
      else {
        throw EngineError(
          code: .resourceLimitExceeded,
          context: .resourceLimit(.dimensionExponent)
        )
      }
      result[base] = sum == 0 ? nil : sum
    }
    return try Dimension(exponents: result)
  }
}

extension Dimension {
  public static let length = Dimension(.length)
  public static let area = Dimension(knownExponents: [.length: 2])
  public static let volume = Dimension(knownExponents: [.length: 3])
  public static let mass = Dimension(.mass)
  public static let time = Dimension(.time)
  public static let temperature = Dimension(.temperature)
  public static let angle = Dimension(.angle)
  public static let speed = Dimension(
    knownExponents: [.length: 1, .time: -1]
  )
  public static let acceleration = Dimension(
    knownExponents: [.length: 1, .time: -2]
  )
  public static let force = Dimension(
    knownExponents: [.mass: 1, .length: 1, .time: -2]
  )
  public static let pressure = Dimension(
    knownExponents: [.mass: 1, .length: -1, .time: -2]
  )
  public static let energy = Dimension(
    knownExponents: [.mass: 1, .length: 2, .time: -2]
  )
  public static let power = Dimension(
    knownExponents: [.mass: 1, .length: 2, .time: -3]
  )
  public static let data = Dimension(.data)
  public static let dataRate = Dimension(
    knownExponents: [.data: 1, .time: -1]
  )
}
