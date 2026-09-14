public struct Parser: Sendable {
  private let source: String
  private let configuration: LexingConfiguration
  private let limits: SyntaxLimits

  public init(
    source: String,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default
  ) {
    self.source = source
    self.configuration = configuration
    self.limits = limits
  }

  public func parse() -> ParsingResult {
    let lexingResult = Lexer(
      source: source,
      configuration: configuration,
      limits: limits
    ).lex()
    if lexingResult.diagnostics.contains(where: {
      $0.code == .resourceLimitExceeded
    }) {
      return ParsingResult(
        expression: nil,
        diagnostics: lexingResult.diagnostics
      )
    }

    var tokenParser = TokenParser(
      tokens: lexingResult.tokens,
      maximumParseDepth: limits.maximumParseDepth
    )
    let parsedExpression = tokenParser.parse()
    let diagnostics = lexingResult.diagnostics + tokenParser.diagnostics

    return ParsingResult(
      expression: diagnostics.isEmpty ? parsedExpression : nil,
      diagnostics: diagnostics
    )
  }
}

extension Token {
  fileprivate var isEndOfInput: Bool {
    kind == .endOfFile || kind == .newline
  }
}

private struct TokenParser {
  private static let prefixBindingPower = 25

  private let tokens: [Token]
  private let maximumParseDepth: Int
  private var cursor = 0
  private(set) var diagnostics: [SyntaxDiagnostic] = []

  init(tokens: [Token], maximumParseDepth: Int) {
    self.tokens = tokens
    self.maximumParseDepth = maximumParseDepth
  }

  mutating func parse() -> Expression? {
    let expression = parseExpression(minimumBindingPower: 0, depth: 1)
    if current.kind != .endOfFile, diagnostics.isEmpty {
      diagnose(.unexpectedToken, at: current.range)
    }
    return expression
  }

  private var current: Token {
    tokens[min(cursor, tokens.count - 1)]
  }

  @discardableResult
  private mutating func advance() -> Token {
    let token = current
    if cursor < tokens.count - 1 {
      cursor += 1
    }
    return token
  }

  private mutating func parseExpression(
    minimumBindingPower: Int,
    depth: Int
  ) -> Expression? {
    guard depth <= maximumParseDepth else {
      diagnose(.resourceLimitExceeded, at: current.range)
      return nil
    }

    guard var left = parsePrefix(depth: depth) else {
      return nil
    }

    while true {
      let selectedOperator: BinaryOperator
      let operatorRange: SourceRange
      let binding: (left: Int, right: Int)
      if let explicitBinding = infixBindingPower(for: current.kind) {
        guard explicitBinding.left >= minimumBindingPower else {
          break
        }
        binding = explicitBinding
        let operatorToken = advance()
        selectedOperator = binaryOperator(for: operatorToken.kind)
        operatorRange = operatorToken.range
      } else if isImplicitMultiplication(after: left, before: current) {
        binding = (20, 21)
        guard binding.left >= minimumBindingPower else {
          break
        }
        selectedOperator = .multiply
        operatorRange = SourceRange(
          lowerBound: current.range.lowerBound,
          upperBound: current.range.lowerBound,
          graphemeLowerBound: current.range.graphemeLowerBound,
          graphemeUpperBound: current.range.graphemeLowerBound
        )
      } else {
        break
      }

      guard
        let right = parseExpression(
          minimumBindingPower: binding.right,
          depth: depth + 1
        )
      else {
        return left
      }

      left = .infix(
        left: left,
        operator: selectedOperator,
        right: right,
        operatorRange: operatorRange,
        range: left.range.union(right.range)
      )
    }

    return left
  }

  private mutating func parsePrefix(depth: Int) -> Expression? {
    let token = advance()
    switch token.kind {
    case .number(let literal):
      return .literal(literal, range: token.range)

    case .identifier(let name):
      if current.kind == .leftParenthesis {
        return parseCall(
          name: name,
          identifierRange: token.range,
          depth: depth
        )
      }
      return .identifier(name, range: token.range)

    case .plus, .minus:
      guard
        let operand = parseExpression(
          minimumBindingPower: Self.prefixBindingPower,
          depth: depth + 1
        )
      else {
        return nil
      }
      let unaryOperator: UnaryOperator = token.kind == .plus ? .plus : .minus
      return .prefix(
        unaryOperator,
        operand: operand,
        operatorRange: token.range,
        range: token.range.union(operand.range)
      )

    case .leftParenthesis:
      guard
        let expression = parseExpression(
          minimumBindingPower: 0,
          depth: depth + 1
        )
      else {
        return nil
      }
      guard current.kind == .rightParenthesis else {
        diagnose(
          .expectedClosingParenthesis,
          at: current.range,
          severity: current.isEndOfInput ? .incomplete : .error
        )
        return .grouped(
          expression,
          range: token.range.union(expression.range)
        )
      }
      let closingParenthesis = advance()
      return .grouped(
        expression,
        range: token.range.union(closingParenthesis.range)
      )

    default:
      diagnose(
        .expectedExpression,
        at: token.range,
        severity: token.isEndOfInput ? .incomplete : .error
      )
      return nil
    }
  }

  private mutating func parseCall(
    name: String,
    identifierRange: SourceRange,
    depth: Int
  ) -> Expression {
    advance()
    var arguments: [Expression] = []

    if current.kind == .rightParenthesis {
      let closingParenthesis = advance()
      return .call(
        name: name,
        nameRange: identifierRange,
        arguments: arguments,
        range: identifierRange.union(closingParenthesis.range)
      )
    }

    while true {
      guard
        let argument = parseExpression(
          minimumBindingPower: 0,
          depth: depth + 1
        )
      else {
        return .call(
          name: name,
          nameRange: identifierRange,
          arguments: arguments,
          range: identifierRange.union(current.range)
        )
      }
      arguments.append(argument)

      if current.kind == .rightParenthesis {
        let closingParenthesis = advance()
        return .call(
          name: name,
          nameRange: identifierRange,
          arguments: arguments,
          range: identifierRange.union(closingParenthesis.range)
        )
      }

      if current.kind == .endOfFile || current.kind == .newline {
        diagnose(
          .expectedClosingParenthesis,
          at: current.range,
          severity: .incomplete
        )
        return .call(
          name: name,
          nameRange: identifierRange,
          arguments: arguments,
          range: identifierRange.union(argument.range)
        )
      }

      guard current.kind == .argumentSeparator else {
        diagnose(.expectedArgumentSeparator, at: current.range)
        return .call(
          name: name,
          nameRange: identifierRange,
          arguments: arguments,
          range: identifierRange.union(argument.range)
        )
      }
      advance()
    }
  }

  private mutating func diagnose(
    _ code: SyntaxDiagnostic.Code,
    at range: SourceRange,
    severity: DiagnosticSeverity = .error
  ) {
    diagnostics.append(
      SyntaxDiagnostic(code: code, severity: severity, range: range)
    )
  }

  private func infixBindingPower(
    for kind: TokenKind
  ) -> (left: Int, right: Int)? {
    switch kind {
    case .plus, .minus:
      return (10, 11)
    case .multiply, .divide:
      return (20, 21)
    case .power:
      return (30, 30)
    default:
      return nil
    }
  }

  private func isImplicitMultiplication(
    after expression: Expression,
    before token: Token
  ) -> Bool {
    guard
      expression.range.upperBound == token.range.lowerBound,
      expression.range.graphemeUpperBound == token.range.graphemeLowerBound
    else {
      return false
    }

    let leftAllowsMultiplication: Bool
    switch expression {
    case .literal, .grouped, .call:
      leftAllowsMultiplication = true
    default:
      leftAllowsMultiplication = false
    }
    guard leftAllowsMultiplication else {
      return false
    }

    switch token.kind {
    case .identifier, .leftParenthesis:
      return true
    case .number:
      if case .literal = expression {
        return false
      }
      return true
    default:
      return false
    }
  }

  private func binaryOperator(for kind: TokenKind) -> BinaryOperator {
    switch kind {
    case .plus:
      return .add
    case .minus:
      return .subtract
    case .multiply:
      return .multiply
    case .divide:
      return .divide
    case .power:
      return .power
    default:
      preconditionFailure("Token is not a binary operator")
    }
  }
}
