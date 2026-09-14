public enum EvaluationResource: String, Hashable, Sendable {
  case operations
  case integerBits
  case decimalScale
  case powerExponent
  case rootDegree
  case functionArguments
}

public struct EvaluationLimits: Hashable, Sendable {
  public let maximumOperations: Int
  public let maximumIntegerBits: Int
  public let maximumDecimalScaleMagnitude: Int
  public let maximumPowerExponent: Int
  public let maximumRootDegree: Int
  public let maximumFunctionArguments: Int

  public init(
    maximumOperations: Int = 100_000,
    maximumIntegerBits: Int = 1_000_000,
    maximumDecimalScaleMagnitude: Int = 100_000,
    maximumPowerExponent: Int = 100_000,
    maximumRootDegree: Int = 10_000,
    maximumFunctionArguments: Int = 10_000
  ) {
    precondition(maximumOperations > 0)
    precondition(maximumIntegerBits > 0)
    precondition(maximumDecimalScaleMagnitude >= 0)
    precondition(maximumPowerExponent >= 0)
    precondition(maximumRootDegree > 0)
    precondition(maximumFunctionArguments > 0)
    self.maximumOperations = maximumOperations
    self.maximumIntegerBits = maximumIntegerBits
    self.maximumDecimalScaleMagnitude = maximumDecimalScaleMagnitude
    self.maximumPowerExponent = maximumPowerExponent
    self.maximumRootDegree = maximumRootDegree
    self.maximumFunctionArguments = maximumFunctionArguments
  }

  public static let `default` = EvaluationLimits()
}

public enum BuiltInFunction: String, Hashable, Sendable {
  case absoluteValue = "abs"
  case minimum = "min"
  case maximum = "max"
  case round
  case floor
  case ceiling = "ceil"
  case squareRoot = "sqrt"
  case root
  case sine = "sin"
  case cosine = "cos"
  case tangent = "tan"
  case arcSine = "asin"
  case arcCosine = "acos"
  case arcTangent = "atan"
  case naturalLogarithm = "ln"
  case commonLogarithm = "log"
  case commonLogarithmExplicit = "log10"
  case exponential = "exp"

  var argumentRange: ClosedRange<Int> {
    switch self {
    case .minimum, .maximum:
      return 2...Int.max
    case .root:
      return 2...2
    default:
      return 1...1
    }
  }
}
