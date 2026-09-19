public enum EvaluationResource: String, Hashable, Sendable {
  case operations
  case integerBits
  case decimalScale
  case powerExponent
  case rootDegree
  case functionArguments
  case dimensionExponent
  case unitFactors
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

public enum BuiltInFunction: String, CaseIterable, Hashable, Sendable {
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
  case binaryLogarithm = "log2"
  case exponential = "exp"
  case cubeRoot = "cbrt"
  case truncate = "trunc"
  case sign
  case arcTangent2 = "atan2"
  case hypot
  case clamp
  case factorial = "fact"
  case remainder = "mod"
  case greatestCommonDivisor = "gcd"
  case leastCommonMultiple = "lcm"
  case combinations = "ncr"
  case permutations = "npr"
  case standardDeviation = "stdev"
  case populationStandardDeviation = "stdevp"
  case netPresentValue = "npv"
  case bitwiseExclusiveOr = "xor"

  var argumentRange: ClosedRange<Int> {
    switch self {
    case .minimum, .maximum:
      return 2...Int.max
    case .root, .arcTangent2, .hypot, .remainder, .greatestCommonDivisor, .leastCommonMultiple,
      .combinations, .permutations, .bitwiseExclusiveOr:
      return 2...2
    case .standardDeviation, .populationStandardDeviation, .netPresentValue:
      return 2...Int.max
    case .clamp:
      return 3...3
    case .round:
      return 1...2
    default:
      return 1...1
    }
  }
}

/// The call whose argument is the prompt sent to a configured assistant,
/// not an expression. `{…}` inside it holds an expression whose value is
/// written into the prompt.
public let assistantFunctionName = "ask_assistant"
