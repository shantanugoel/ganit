public struct Parser: Sendable {
  private let source: String
  private let configuration: LexingConfiguration
  private let limits: SyntaxLimits
  private let catalog: UnitCatalog

  public init(
    source: String,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default,
    catalog: UnitCatalog? = nil
  ) {
    self.source = source
    self.configuration = configuration
    self.limits = limits
    self.catalog = catalog ?? builtInMinimalUnitCatalog
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
      maximumParseDepth: limits.maximumParseDepth,
      catalog: catalog
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
  private let catalog: UnitCatalog
  private var cursor = 0
  private(set) var diagnostics: [SyntaxDiagnostic] = []

  init(
    tokens: [Token],
    maximumParseDepth: Int,
    catalog: UnitCatalog
  ) {
    self.tokens = tokens
    self.maximumParseDepth = maximumParseDepth
    self.catalog = catalog
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
      if current.kind == .percent {
        guard 40 >= minimumBindingPower else {
          break
        }
        let percent = advance()
        guard !isPercentage(left) else {
          diagnose(.unexpectedToken, at: percent.range)
          break
        }
        left = .percentage(
          points: left,
          percentRange: percent.range,
          range: left.range.union(percent.range)
        )
        continue
      }

      if identifier(at: 0) == "is",
        identifier(at: 1) == "what",
        token(at: 2).kind == .percent,
        identifier(at: 3) == "of"
      {
        guard 5 >= minimumBindingPower else {
          break
        }
        guard let ratio = parseRatioPhrase(of: left, depth: depth) else {
          return left
        }
        left = ratio
        continue
      }

      if identifier(at: 0) == "is", isIncompleteRatioPhrase {
        diagnose(
          .expectedPercentagePhrase,
          at: current.range.union(tokens.last!.range),
          severity: .incomplete
        )
        while current.kind != .endOfFile {
          advance()
        }
        break
      }

      if identifier(at: 0) == "after" {
        guard 5 >= minimumBindingPower else {
          break
        }
        guard let reverse = parseReversePhrase(of: left, depth: depth) else {
          return left
        }
        left = reverse
        continue
      }

      if isPercentage(left),
        let keyword = identifier(at: 0),
        keyword == "of" || keyword == "off" || keyword == "on"
      {
        guard 20 >= minimumBindingPower else {
          break
        }
        guard let operation = parsePercentageOf(left, depth: depth) else {
          return left
        }
        left = operation
        continue
      }

      // Exponents are dimensionless, so a unit never attaches inside one.
      if 29 >= minimumBindingPower,
        canAttachUnit(to: left),
        startsUnitExpression(at: 0)
      {
        guard let quantity = parseQuantity(magnitude: left, depth: depth)
        else {
          return left
        }
        left = quantity
        continue
      }

      if 1 >= minimumBindingPower,
        let keyword = identifier(at: 0),
        ["in", "to", "as", "into"].contains(keyword),
        startsUnitExpression(at: 1) || inferredKind(of: left) == .quantity
      {
        guard let conversion = parseConversion(of: left, depth: depth) else {
          return left
        }
        left = conversion
        continue
      }

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
      if name == "percentage", identifier(at: 0) == "change" {
        return parsePercentageChange(
          startRange: token.range,
          depth: depth
        )
      }
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

  private mutating func parsePercentageChange(
    startRange: SourceRange,
    depth: Int
  ) -> Expression? {
    let change = advance()
    guard identifier(at: 0) == "from" else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: current.isEndOfInput ? .incomplete : .error
      )
      return nil
    }
    advance()
    guard !current.isEndOfInput else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: .incomplete
      )
      return nil
    }
    guard
      let oldValue = parseExpression(
        minimumBindingPower: 0,
        depth: depth + 1
      )
    else {
      return nil
    }
    guard identifier(at: 0) == "to" else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: current.isEndOfInput ? .incomplete : .error
      )
      return nil
    }
    let to = advance()
    guard !current.isEndOfInput else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: .incomplete
      )
      return nil
    }
    guard
      let newValue = parseExpression(
        minimumBindingPower: 0,
        depth: depth + 1
      )
    else {
      return nil
    }
    return .percentageOperation(
      operator: .change,
      left: oldValue,
      right: newValue,
      operatorRange: startRange.union(change.range).union(to.range),
      range: startRange.union(newValue.range)
    )
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

  // Phrase branches live outside parseExpression to keep its recursive stack
  // frame small in debug builds.
  private mutating func parseRatioPhrase(
    of value: Expression,
    depth: Int
  ) -> Expression? {
    let start = advance()
    advance()
    advance()
    let end = advance()
    guard !current.isEndOfInput else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: .incomplete
      )
      return nil
    }
    guard
      let right = parseExpression(
        minimumBindingPower: 6,
        depth: depth + 1
      )
    else {
      return nil
    }
    return .percentageOperation(
      operator: .ratio,
      left: value,
      right: right,
      operatorRange: start.range.union(end.range),
      range: value.range.union(right.range)
    )
  }

  private mutating func parseReversePhrase(
    of value: Expression,
    depth: Int
  ) -> Expression? {
    let after = advance()
    guard !current.isEndOfInput else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: .incomplete
      )
      return nil
    }
    guard
      let percentage = parseExpression(
        minimumBindingPower: 21,
        depth: depth + 1
      )
    else {
      return nil
    }
    guard
      isPercentage(percentage),
      let direction = identifier(at: 0),
      direction == "off" || direction == "on"
    else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: current.isEndOfInput ? .incomplete : .error
      )
      return nil
    }
    let directionToken = advance()
    return .percentageOperation(
      operator: direction == "off" ? .reverseOff : .reverseOn,
      left: value,
      right: percentage,
      operatorRange: after.range.union(directionToken.range),
      range: value.range.union(directionToken.range)
    )
  }

  private mutating func parsePercentageOf(
    _ percentage: Expression,
    depth: Int
  ) -> Expression? {
    let keywordToken = advance()
    guard !current.isEndOfInput else {
      diagnose(
        .expectedPercentagePhrase,
        at: current.range,
        severity: .incomplete
      )
      return nil
    }
    guard
      let right = parseExpression(
        minimumBindingPower: 21,
        depth: depth + 1
      )
    else {
      return nil
    }
    let percentageOperator: PercentageOperator =
      switch keywordToken.kind {
      case .identifier("of"): .of
      case .identifier("off"): .off
      default: .on
      }
    return .percentageOperation(
      operator: percentageOperator,
      left: percentage,
      right: right,
      operatorRange: keywordToken.range,
      range: percentage.range.union(right.range)
    )
  }

  private mutating func parseQuantity(
    magnitude: Expression,
    depth: Int
  ) -> Expression? {
    guard let unit = parseUnitExpression(depth: depth + 1) else {
      return nil
    }
    return .quantity(
      magnitude: magnitude,
      unit: unit,
      range: magnitude.range.union(unit.range)
    )
  }

  private mutating func parseConversion(
    of value: Expression,
    depth: Int
  ) -> Expression? {
    let keywordToken = advance()
    guard startsUnitExpression(at: 0) else {
      if current.isEndOfInput {
        diagnose(
          .expectedConversionUnit,
          at: keywordToken.range.union(current.range),
          severity: .incomplete
        )
      } else if case .identifier = current.kind {
        diagnose(.unknownUnit, at: advance().range)
      } else {
        diagnose(.expectedConversionUnit, at: current.range)
      }
      return nil
    }
    guard let target = parseUnitExpression(depth: depth + 1) else {
      return nil
    }
    return .conversion(
      value: value,
      target: target,
      keywordRange: keywordToken.range,
      range: value.range.union(target.range)
    )
  }

  private mutating func parseUnitExpression(depth: Int) -> UnitSyntax? {
    guard depth <= maximumParseDepth else {
      diagnose(.resourceLimitExceeded, at: current.range)
      return nil
    }
    guard var left = parseUnitFactor(depth: depth) else {
      return nil
    }
    var factorCount = 1
    while current.kind == .multiply || current.kind == .divide {
      guard startsKnownUnit(at: 1) || token(at: 1).kind == .leftParenthesis else {
        break
      }
      guard factorCount < RatioUnit.maximumFactorCount else {
        diagnose(.resourceLimitExceeded, at: current.range)
        return left
      }
      let operation = advance()
      guard let right = parseUnitFactor(depth: depth + 1) else {
        return left
      }
      factorCount += 1
      let range = left.range.union(right.range)
      left =
        operation.kind == .multiply
        ? .multiplied(left, right, range: range)
        : .divided(left, right, range: range)
    }
    return left
  }

  private mutating func parseUnitFactor(depth: Int) -> UnitSyntax? {
    let start = current
    var unit: UnitSyntax
    if case .identifier(let alias) = start.kind,
      let resolved = catalog.resolveUnit(matching: alias)
    {
      advance()
      unit = .named(
        resolved.entry,
        prefix: resolved.prefix,
        range: start.range
      )
    } else if start.kind == .leftParenthesis {
      advance()
      guard let nested = parseUnitExpression(depth: depth + 1) else {
        return nil
      }
      guard current.kind == .rightParenthesis else {
        diagnose(
          .expectedUnitClosingParenthesis,
          at: current.range,
          severity: current.isEndOfInput ? .incomplete : .error
        )
        return nested
      }
      let closing = advance()
      unit = nestedWithRange(nested, range: start.range.union(closing.range))
    } else {
      diagnose(
        start.isEndOfInput ? .expectedConversionUnit : .unknownUnit,
        at: start.range,
        severity: start.isEndOfInput ? .incomplete : .error
      )
      return nil
    }

    if case .superscript(let exponent) = current.kind {
      let exponentToken = advance()
      let raised = UnitSyntax.raised(
        unit,
        exponent: exponent,
        range: unit.range.union(exponentToken.range)
      )
      diagnoseRepeatedUnitPower()
      return raised
    }
    guard current.kind == .power else {
      return unit
    }
    advance()
    var sign = 1
    if current.kind == .plus {
      advance()
    } else if current.kind == .minus {
      sign = -1
      advance()
    }
    let exponentToken = current
    guard
      case .number(.integer(let digits, let radix)) = exponentToken.kind,
      radix == .decimal,
      let magnitude = Int(digits),
      magnitude <= Dimension.maximumExponentMagnitude
    else {
      diagnose(
        .invalidUnitExponent,
        at: exponentToken.range,
        severity: exponentToken.isEndOfInput ? .incomplete : .error
      )
      return unit
    }
    advance()
    let raised = UnitSyntax.raised(
      unit,
      exponent: sign * magnitude,
      range: unit.range.union(exponentToken.range)
    )
    diagnoseRepeatedUnitPower()
    return raised
  }

  private mutating func diagnoseRepeatedUnitPower() {
    switch current.kind {
    case .power, .superscript:
      diagnose(.invalidUnitExponent, at: current.range)
    default:
      break
    }
  }

  private func nestedWithRange(
    _ syntax: UnitSyntax,
    range: SourceRange
  ) -> UnitSyntax {
    switch syntax {
    case .named(let entry, let prefix, _):
      return .named(entry, prefix: prefix, range: range)
    case .multiplied(let left, let right, _):
      return .multiplied(left, right, range: range)
    case .divided(let left, let right, _):
      return .divided(left, right, range: range)
    case .raised(let unit, let exponent, _):
      return .raised(unit, exponent: exponent, range: range)
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

  private func token(at offset: Int) -> Token {
    tokens[min(cursor + offset, tokens.count - 1)]
  }

  private func identifier(at offset: Int) -> String? {
    guard case .identifier(let name) = token(at: offset).kind else {
      return nil
    }
    return name
  }

  private func startsKnownUnit(at offset: Int) -> Bool {
    guard let alias = identifier(at: offset) else {
      return false
    }
    return catalog.resolveUnit(matching: alias) != nil
  }

  private func startsUnitExpression(at offset: Int) -> Bool {
    if startsKnownUnit(at: offset) {
      return true
    }
    var index = offset
    while token(at: index).kind == .leftParenthesis {
      index += 1
      guard index - offset <= maximumParseDepth else {
        return false
      }
    }
    return startsKnownUnit(at: index)
  }

  private func canAttachUnit(to expression: Expression) -> Bool {
    switch expression {
    case .literal, .prefix, .grouped:
      return inferredKind(of: expression) == .number
    default:
      return false
    }
  }

  private func isPercentage(_ expression: Expression) -> Bool {
    inferredKind(of: expression) == .percentage
  }

  private func inferredKind(of expression: Expression) -> EngineValueKind? {
    switch expression {
    case .literal, .identifier, .call:
      return .number
    case .quantity, .conversion:
      return .quantity
    case .percentage:
      return .percentage
    case .prefix(_, let operand, _, _):
      return inferredKind(of: operand)
    case .grouped(let nested, _):
      return inferredKind(of: nested)
    case .infix(let left, let binaryOperator, let right, _, _):
      let leftKind = inferredKind(of: left)
      let rightKind = inferredKind(of: right)
      if leftKind == .quantity || rightKind == .quantity {
        return .quantity
      }
      switch binaryOperator {
      case .add, .subtract:
        return leftKind == .percentage && rightKind == .percentage
          ? .percentage
          : .number
      case .multiply, .power:
        return .number
      case .divide:
        return leftKind == .percentage && rightKind == .number
          ? .percentage
          : .number
      }
    case .percentageOperation(let percentageOperator, _, _, _, _):
      return percentageOperator == .ratio || percentageOperator == .change
        ? .percentage
        : .number
    }
  }

  private var isIncompleteRatioPhrase: Bool {
    var offset = 0
    while token(at: offset).kind != .endOfFile {
      let matches: Bool =
        switch offset {
        case 0: identifier(at: offset) == "is"
        case 1: identifier(at: offset) == "what"
        case 2: token(at: offset).kind == .percent
        case 3: identifier(at: offset) == "of"
        default: false
        }
      guard matches else {
        return false
      }
      offset += 1
    }
    return offset > 0 && offset < 4
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
