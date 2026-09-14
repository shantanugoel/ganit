import Foundation

public struct Evaluator: Sendable {
  private let limits: EvaluationLimits

  public init(limits: EvaluationLimits = .default) {
    self.limits = limits
  }

  public func evaluate(_ expression: Expression) throws -> NumericValue {
    var worker = EvaluationWorker(limits: limits)
    return try worker.evaluate(expression)
  }
}

private struct EvaluationWorker {
  let limits: EvaluationLimits
  let operations: NumericOperations
  var visitedOperations = 0

  init(limits: EvaluationLimits) {
    self.limits = limits
    operations = NumericOperations(limits: limits)
  }

  mutating func evaluate(_ expression: Expression) throws -> NumericValue {
    try visit(expression.range)

    do {
      switch expression {
      case .literal(let literal, let range):
        return try evaluate(literal, range: range)

      case .identifier(let name, let range):
        switch name {
        case "π", "pi":
          return .approximate(
            try ApproximateValue(
              estimate: .pi,
              source: .mathematicalConstant,
              precision: .unspecified
            )
          )
        case "e":
          return .approximate(
            try ApproximateValue(
              estimate: Foundation.exp(1),
              source: .mathematicalConstant,
              precision: .unspecified
            )
          )
        default:
          throw EngineError(code: .unknownIdentifier, ranges: [range])
        }

      case .prefix(
        let unaryOperator,
        let operand,
        let operatorRange,
        _
      ):
        let value = try evaluate(operand)
        return try located(at: operatorRange) {
          try operations.applying(unaryOperator, to: value)
        }

      case .infix(
        let left,
        let binaryOperator,
        let right,
        let operatorRange,
        _
      ):
        let lhs = try evaluate(left)
        let rhs = try evaluate(right)
        let errorRange =
          binaryOperator == .divide
          ? right.range
          : operatorRange
        return try located(at: errorRange) {
          try operations.applying(binaryOperator, left: lhs, right: rhs)
        }

      case .call(let name, let nameRange, let arguments, _):
        return try evaluateCall(
          name: name,
          nameRange: nameRange,
          arguments: arguments
        )

      case .grouped(let nested, _):
        return try evaluate(nested)
      }
    } catch let error as EngineError where error.ranges.isEmpty {
      throw error.located(at: expression.range)
    }
  }

  private mutating func evaluate(
    _ literal: NumericLiteral,
    range: SourceRange
  ) throws -> NumericValue {
    switch literal {
    case .integer(let digits, let radix):
      let integer = try IntegerValue(digits, radix: radix)
      try validate(integer, at: range)
      return .integer(integer)

    case .decimal(let digits, let fractionalDigitCount, let exponent):
      let (scale, overflow) = fractionalDigitCount.subtractingReportingOverflow(
        exponent
      )
      guard
        !overflow,
        scale != .min,
        Swift.abs(scale) <= limits.maximumDecimalScaleMagnitude
      else {
        throw limitError(.decimalScale, range: range)
      }
      let coefficient = try IntegerValue(digits)
      try validate(coefficient, at: range)
      return .decimal(
        try DecimalValue(coefficient: coefficient, scale: scale)
      )
    }
  }

  private mutating func evaluateCall(
    name: String,
    nameRange: SourceRange,
    arguments: [Expression]
  ) throws -> NumericValue {
    guard let function = BuiltInFunction(rawValue: name) else {
      throw EngineError(code: .unknownFunction, ranges: [nameRange])
    }
    guard arguments.count <= limits.maximumFunctionArguments else {
      throw limitError(.functionArguments, range: nameRange)
    }
    guard function.argumentRange.contains(arguments.count) else {
      throw EngineError(
        code: .argumentCountMismatch,
        ranges: [nameRange],
        context: .argumentCount(
          function: function,
          expected: function.argumentRange,
          actual: arguments.count
        )
      )
    }

    let values = try arguments.map { try evaluate($0) }
    if function == .squareRoot {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: .integer(IntegerValue(2)),
        degreeRange: nameRange
      )
    }
    if function == .root {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: values[1],
        degreeRange: arguments[1].range
      )
    }

    return try located(at: nameRange) {
      switch function {
      case .absoluteValue:
        return try operations.absoluteValue(values[0])
      case .minimum:
        return try operations.extremum(values, selectMinimum: true)
      case .maximum:
        return try operations.extremum(values, selectMinimum: false)
      case .round:
        return try operations.rounded(values[0], rule: .toNearestOrEven)
      case .floor:
        return try operations.rounded(values[0], rule: .down)
      case .ceiling:
        return try operations.rounded(values[0], rule: .up)
      case .squareRoot:
        return try operations.root(
          values[0],
          degree: .integer(IntegerValue(2))
        )
      case .root:
        return try operations.root(values[0], degree: values[1])
      }
    }
  }

  private func evaluateRoot(
    value: NumericValue,
    valueRange: SourceRange,
    degree: NumericValue,
    degreeRange: SourceRange
  ) throws -> NumericValue {
    do {
      return try operations.root(value, degree: degree)
    } catch let error as EngineError {
      let range: SourceRange
      switch error.context {
      case .rootDegree, .resourceLimit(.rootDegree):
        range = degreeRange
      default:
        range = valueRange
      }
      throw error.ranges.isEmpty ? error.located(at: range) : error
    }
  }

  private mutating func visit(_ range: SourceRange) throws {
    visitedOperations += 1
    guard visitedOperations <= limits.maximumOperations else {
      throw limitError(.operations, range: range)
    }
  }

  private func validate(_ integer: IntegerValue, at range: SourceRange) throws {
    guard integer.storage.bitWidth <= limits.maximumIntegerBits else {
      throw limitError(.integerBits, range: range)
    }
  }

  private func located<T>(
    at range: SourceRange,
    operation: () throws -> T
  ) throws -> T {
    do {
      return try operation()
    } catch let error as EngineError {
      throw error.ranges.isEmpty ? error.located(at: range) : error
    }
  }

  private func limitError(
    _ resource: EvaluationResource,
    range: SourceRange
  ) -> EngineError {
    EngineError(
      code: .resourceLimitExceeded,
      ranges: [range],
      context: .resourceLimit(resource)
    )
  }
}

extension EngineError {
  fileprivate func located(at range: SourceRange) -> EngineError {
    EngineError(
      code: code,
      severity: severity,
      ranges: [range],
      fixIts: fixIts,
      context: context
    )
  }
}
