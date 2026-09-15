public struct UnitAlgebra: Sendable {
  private let operations: NumericOperations

  public init(
    context: EvaluationContext,
    limits: EvaluationLimits = .default
  ) {
    operations = NumericOperations(context: context, limits: limits)
  }

  public func unit(_ definition: UnitDefinition) throws -> UnitExpression {
    switch definition.transform {
    case .ratio(let scale):
      return .ratio(
        RatioUnit(
          factors: [UnitFactor(unit: definition, exponent: 1)],
          dimension: definition.dimension,
          scaleToCanonical: scale
        )
      )
    case .affine:
      return .affine(definition)
    }
  }

  public func applying(
    _ prefix: UnitPrefix,
    to definition: UnitDefinition
  ) throws -> UnitDefinition {
    guard definition.allowedPrefixFamilies.contains(prefix.family) else {
      throw EngineError(code: .invalidUnitDefinition)
    }
    guard case .ratio(let scale) = definition.transform else {
      throw EngineError(code: .affineUnitInCompound)
    }
    return try UnitDefinition(
      canonicalIdentifier:
        prefix.canonicalIdentifier + definition.canonicalIdentifier,
      symbol: prefix.symbol + definition.symbol,
      dimension: definition.dimension,
      transform: .ratio(
        scale: try operations.applying(
          .multiply,
          left: prefix.scale,
          right: scale
        )
      ),
      allowedPrefixFamilies: []
    )
  }

  public func multiplied(
    _ left: UnitExpression,
    by right: UnitExpression
  ) throws -> UnitExpression {
    let lhs = try requireRatio(left)
    let rhs = try requireRatio(right)
    return .ratio(
      RatioUnit(
        factors: try merge(lhs.factors, rhs.factors, sign: 1),
        dimension: try lhs.dimension.multiplied(by: rhs.dimension),
        scaleToCanonical: try operations.applying(
          .multiply,
          left: lhs.scaleToCanonical,
          right: rhs.scaleToCanonical
        )
      )
    )
  }

  public func divided(
    _ left: UnitExpression,
    by right: UnitExpression
  ) throws -> UnitExpression {
    let lhs = try requireRatio(left)
    let rhs = try requireRatio(right)
    return .ratio(
      RatioUnit(
        factors: try merge(lhs.factors, rhs.factors, sign: -1),
        dimension: try lhs.dimension.divided(by: rhs.dimension),
        scaleToCanonical: try operations.applying(
          .divide,
          left: lhs.scaleToCanonical,
          right: rhs.scaleToCanonical
        )
      )
    )
  }

  public func raised(
    _ unit: UnitExpression,
    to exponent: Int
  ) throws -> UnitExpression {
    let ratio = try requireRatio(unit)
    let dimension = try ratio.dimension.raised(to: exponent)
    let factors = try ratio.factors.compactMap { factor -> UnitFactor? in
      let (value, overflow) = factor.exponent.multipliedReportingOverflow(
        by: exponent
      )
      guard
        !overflow,
        value.magnitude <= Dimension.maximumExponentMagnitude
      else {
        throw EngineError(
          code: .resourceLimitExceeded,
          context: .resourceLimit(.dimensionExponent)
        )
      }
      return value == 0 ? nil : UnitFactor(unit: factor.unit, exponent: value)
    }
    return .ratio(
      RatioUnit(
        factors: factors,
        dimension: dimension,
        scaleToCanonical: try operations.applying(
          .power,
          left: ratio.scaleToCanonical,
          right: .integer(IntegerValue(exponent))
        )
      )
    )
  }

  public func converted(
    _ quantity: QuantityValue,
    to target: UnitExpression
  ) throws -> QuantityValue {
    guard quantity.unit.dimension == target.dimension else {
      throw EngineError(
        code: .incompatibleDimensions,
        context: .dimensionMismatch(
          expected: target.dimension,
          actual: quantity.unit.dimension
        )
      )
    }
    let canonical = try toCanonical(
      quantity.magnitude,
      from: quantity.unit,
      kind: quantity.kind
    )
    return QuantityValue(
      magnitude: try fromCanonical(
        canonical,
        to: target,
        kind: quantity.kind
      ),
      unit: target,
      kind: quantity.kind
    )
  }

  public func converted(
    _ rate: RateValue,
    to denominator: RateDenominator
  ) throws -> RateValue {
    guard rate.denominator.dimension == denominator.dimension else {
      throw EngineError(
        code: .incompatibleDimensions,
        context: .dimensionMismatch(
          expected: denominator.dimension,
          actual: rate.denominator.dimension
        )
      )
    }
    let factor: NumericValue
    switch (rate.denominator, denominator) {
    case (.unit(let source), .unit(let target)):
      let sourceScale = try requireRatio(source).scaleToCanonical
      let targetScale = try requireRatio(target).scaleToCanonical
      factor = try operations.applying(
        .divide,
        left: targetScale,
        right: sourceScale
      )
    case (.calendar(let source), .calendar(let target)):
      factor = try operations.applying(
        .divide,
        left: .integer(IntegerValue(target.months)),
        right: .integer(IntegerValue(source.months))
      )
    default:
      throw EngineError(code: .incompatibleRatePeriods)
    }
    return try RateValue(
      amount: try scaling(rate.amount, by: factor),
      denominator: denominator
    )
  }

  public func applying(
    _ rate: RateValue,
    to denominatorQuantity: QuantityValue
  ) throws -> RateAmount {
    guard denominatorQuantity.kind == .relative else {
      throw EngineError(code: .invalidAbsoluteQuantityOperation)
    }
    guard case .unit(let denominator) = rate.denominator else {
      throw EngineError(code: .incompatibleRatePeriods)
    }
    let convertedDenominator = try converted(
      denominatorQuantity,
      to: denominator
    )
    return try scaling(rate.amount, by: convertedDenominator.magnitude)
  }

  public func applying(
    _ rate: RateValue,
    toPeriodCount count: NumericValue
  ) throws -> RateAmount {
    guard case .calendar = rate.denominator else {
      throw EngineError(code: .incompatibleRatePeriods)
    }
    return try scaling(rate.amount, by: count)
  }

  public func adding(
    _ left: QuantityValue,
    _ right: QuantityValue
  ) throws -> QuantityValue {
    try combining(left, right, with: .add)
  }

  public func subtracting(
    _ left: QuantityValue,
    _ right: QuantityValue
  ) throws -> QuantityValue {
    try combining(left, right, with: .subtract)
  }

  public func multiplying(
    _ left: QuantityValue,
    _ right: QuantityValue
  ) throws -> QuantityValue {
    guard left.kind == .relative, right.kind == .relative else {
      throw EngineError(code: .invalidAbsoluteQuantityOperation)
    }
    let unit = try multiplied(left.unit, by: right.unit)
    return QuantityValue(
      magnitude: try operations.applying(
        .multiply,
        left: left.magnitude,
        right: right.magnitude
      ),
      unit: unit,
      kind: .relative
    )
  }

  public func dividing(
    _ left: QuantityValue,
    _ right: QuantityValue
  ) throws -> QuantityValue {
    guard left.kind == .relative, right.kind == .relative else {
      throw EngineError(code: .invalidAbsoluteQuantityOperation)
    }
    let unit = try divided(left.unit, by: right.unit)
    return QuantityValue(
      magnitude: try operations.applying(
        .divide,
        left: left.magnitude,
        right: right.magnitude
      ),
      unit: unit,
      kind: .relative
    )
  }

  private func combining(
    _ left: QuantityValue,
    _ right: QuantityValue,
    with binaryOperator: BinaryOperator
  ) throws -> QuantityValue {
    guard left.unit.dimension == right.unit.dimension else {
      throw EngineError(
        code: .incompatibleDimensions,
        context: .dimensionMismatch(
          expected: left.unit.dimension,
          actual: right.unit.dimension
        )
      )
    }
    guard
      left.kind == .relative,
      right.kind == .relative
    else {
      throw EngineError(code: .invalidAbsoluteQuantityOperation)
    }
    let convertedRight = try converted(right, to: left.unit)
    return QuantityValue(
      magnitude: try operations.applying(
        binaryOperator,
        left: left.magnitude,
        right: convertedRight.magnitude
      ),
      unit: left.unit,
      kind: .relative
    )
  }

  private func toCanonical(
    _ value: NumericValue,
    from unit: UnitExpression,
    kind: QuantityValue.Kind
  ) throws -> NumericValue {
    switch unit {
    case .ratio(let ratio):
      return try operations.applying(
        .multiply,
        left: value,
        right: ratio.scaleToCanonical
      )
    case .affine(let definition):
      guard case .affine(let scale, let offset) = definition.transform else {
        throw EngineError(code: .invalidUnitDefinition)
      }
      let scaled = try operations.applying(
        .multiply,
        left: value,
        right: scale
      )
      guard kind == .absolute else {
        return scaled
      }
      return try operations.applying(.add, left: scaled, right: offset)
    }
  }

  private func fromCanonical(
    _ value: NumericValue,
    to unit: UnitExpression,
    kind: QuantityValue.Kind
  ) throws -> NumericValue {
    switch unit {
    case .ratio(let ratio):
      return try operations.applying(
        .divide,
        left: value,
        right: ratio.scaleToCanonical
      )
    case .affine(let definition):
      guard case .affine(let scale, let offset) = definition.transform else {
        throw EngineError(code: .invalidUnitDefinition)
      }
      let translated =
        kind == .absolute
        ? try operations.applying(.subtract, left: value, right: offset)
        : value
      return try operations.applying(
        .divide,
        left: translated,
        right: scale
      )
    }
  }

  private func requireRatio(_ unit: UnitExpression) throws -> RatioUnit {
    guard case .ratio(let ratio) = unit else {
      throw EngineError(code: .affineUnitInCompound)
    }
    return ratio
  }

  private func scaling(
    _ amount: RateAmount,
    by factor: NumericValue
  ) throws -> RateAmount {
    switch amount {
    case .number(let number):
      return .number(
        try operations.applying(.multiply, left: number, right: factor)
      )
    case .percentage(let percentage):
      return .percentage(
        PercentageValue(
          points: try operations.applying(
            .multiply,
            left: percentage.points,
            right: factor
          )
        )
      )
    }
  }

  private func merge(
    _ left: [UnitFactor],
    _ right: [UnitFactor],
    sign: Int
  ) throws -> [UnitFactor] {
    var factors = Dictionary(
      uniqueKeysWithValues: left.map {
        ($0.unit.canonicalIdentifier, $0)
      }
    )
    for factor in right {
      let identifier = factor.unit.canonicalIdentifier
      if let existing = factors[identifier] {
        guard existing.unit == factor.unit else {
          throw EngineError(code: .invalidUnitDefinition)
        }
        let (adjustment, multiplicationOverflow) = factor.exponent
          .multipliedReportingOverflow(by: sign)
        let (exponent, additionOverflow) = existing.exponent
          .addingReportingOverflow(adjustment)
        guard
          !multiplicationOverflow,
          !additionOverflow,
          exponent.magnitude <= Dimension.maximumExponentMagnitude
        else {
          throw EngineError(
            code: .resourceLimitExceeded,
            context: .resourceLimit(.dimensionExponent)
          )
        }
        factors[identifier] =
          exponent == 0
          ? nil
          : UnitFactor(unit: factor.unit, exponent: exponent)
      } else {
        let exponent = factor.exponent * sign
        factors[identifier] = UnitFactor(
          unit: factor.unit,
          exponent: exponent
        )
      }
    }
    let result = factors.values.sorted {
      $0.unit.canonicalIdentifier < $1.unit.canonicalIdentifier
    }
    guard result.count <= RatioUnit.maximumFactorCount else {
      throw EngineError(
        code: .resourceLimitExceeded,
        context: .resourceLimit(.unitFactors)
      )
    }
    return result
  }
}
