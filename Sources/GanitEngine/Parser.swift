public struct Parser: Sendable {
  private let source: String
  private let configuration: LexingConfiguration
  private let limits: SyntaxLimits
  private let catalog: UnitCatalog
  private let origin: SourceLocation
  private let variables: [String: EngineValueKind]

  /// `variables` maps declared names, whose words are joined by single
  /// spaces, to the kind of value they hold.
  public init(
    source: String,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default,
    catalog: UnitCatalog? = nil,
    origin: SourceLocation = .start,
    variables: [String: EngineValueKind] = [:]
  ) {
    self.source = source
    self.configuration = configuration
    self.limits = limits
    self.catalog = catalog ?? builtInMinimalUnitCatalog
    self.origin = origin
    self.variables = variables
  }

  public func parse() -> ParsingResult {
    let lexingResult = Lexer(
      source: source,
      configuration: configuration,
      limits: limits,
      origin: origin
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
      catalog: catalog,
      variables: variables
    )
    let parsedExpression = tokenParser.parse()
    let diagnostics = lexingResult.diagnostics + tokenParser.diagnostics

    return ParsingResult(
      expression: diagnostics.isEmpty ? parsedExpression : nil,
      diagnostics: diagnostics
    )
  }
}

/// Words with grammatical meaning, which cannot appear in variable names.
let reservedIdentifiers: Set<String> = [
  "in", "to", "as", "into", "of", "off", "on", "is", "what", "after",
  "percentage", "change", "from", "pi", "π", "e", "today", "tomorrow", "yesterday", "now",
  "ago",
]

/// Reference keywords. A longer declared name may start with one.
let referenceKeywords: [String: LineReference] = [
  "previous": .previous,
  "prev": .previous,
  "sum": .aggregate(.sum),
  "total": .aggregate(.sum),
  "subtotal": .aggregate(.subtotal),
  "average": .aggregate(.average),
  "avg": .aggregate(.average),
  "median": .aggregate(.median),
  "count": .aggregate(.count),
]

let monthNames: [String: Int] = [
  "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
  "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9,
  "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12,
  "dec": 12,
]

let weekdayNames: [String: Int] = [
  "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
  "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5, "friday": 6, "fri": 6,
  "saturday": 7, "sat": 7,
]

let relativeDays = ["yesterday": -1, "today": 0, "tomorrow": 1]

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
  private let variables: [String: EngineValueKind]
  private let maximumNameWords: Int
  private var cursor = 0
  private(set) var diagnostics: [SyntaxDiagnostic] = []

  init(
    tokens: [Token],
    maximumParseDepth: Int,
    catalog: UnitCatalog,
    variables: [String: EngineValueKind]
  ) {
    self.tokens = tokens
    self.maximumParseDepth = maximumParseDepth
    self.catalog = catalog
    self.variables = variables
    maximumNameWords =
      variables.keys.map { $0.split(separator: " ").count }.max() ?? 1
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

    // Each node wrapping `left` deepens the tree without recursing here, so it
    // counts toward the depth limit. This bounds every recursive walk of the
    // tree, including evaluation, for chains such as `1 + 1 + ... + 1`.
    var depth = depth
    while true {
      guard depth <= maximumParseDepth else {
        diagnose(.resourceLimitExceeded, at: current.range)
        return nil
      }
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
        depth += 1
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
        depth += 1
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
        depth += 1
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
        depth += 1
        continue
      }

      if 29 >= minimumBindingPower,
        case .literal(.integer(let digits, .decimal), let range) = left, digits.count <= 2,
        let word = identifier(at: 0), variables[word] == nil,
        let month = monthNames[word.lowercased()]
      {
        let monthRange = advance().range
        left = parseYear(month: month, day: Int(digits)!, range: range.union(monthRange))
        depth += 1
        continue
      }

      if 1 >= minimumBindingPower,
        identifier(at: 0) == "ago" || (identifier(at: 0) == "from" && identifier(at: 1) == "now")
      {
        let isPast = identifier(at: 0) == "ago"
        var end = advance().range
        if !isPast {
          end = advance().range
        }
        left = .relative(offset: left, isPast: isPast, range: left.range.union(end))
        depth += 1
        continue
      }

      if 29 >= minimumBindingPower,
        canAttachUnit(to: left),
        let word = identifier(at: 0),
        variables[word] == nil,
        let unit = CalendarPeriodUnit(word: word)
      {
        left = .period(count: left, unit: unit, range: left.range.union(advance().range))
        depth += 1
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
        depth += 1
        continue
      }

      if 1 >= minimumBindingPower,
        let keyword = identifier(at: 0),
        ["in", "to", "as", "into"].contains(keyword),
        timeZone(at: 1) != nil || inferredKind(of: left) == .instant
      {
        let keywordRange = advance().range
        guard let (zone, tokenCount) = timeZone(at: 0) else {
          if current.isEndOfInput {
            diagnose(.unknownTimeZone, at: keywordRange.union(current.range), severity: .incomplete)
          } else {
            diagnose(.unknownTimeZone, at: advance().range)
          }
          return left
        }
        var end = current.range
        for _ in 0..<tokenCount {
          end = advance().range
        }
        left = .zoneConversion(value: left, zone: zone, range: left.range.union(end))
        depth += 1
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
        depth += 1
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
      depth += 1
    }

    return left
  }

  private mutating func parsePrefix(depth: Int) -> Expression? {
    let token = advance()
    switch token.kind {
    case .number(let literal):
      return .literal(literal, range: token.range)

    case .temporal(
      .dateTime(let year, let month, let day, let hour, let minute, let second, nil)):
      guard let (zone, tokenCount) = timeZone(at: 0) else {
        return .temporal(
          .dateTime(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second,
            zone: nil),
          range: token.range)
      }
      var end = token.range
      for _ in 0..<tokenCount {
        end = advance().range
      }
      return .temporal(
        .dateTime(
          year: year, month: month, day: day, hour: hour, minute: minute, second: second,
          zone: .named(zone)),
        range: token.range.union(end))

    case .temporal(let literal):
      return parseMeridiem(literal, range: token.range)

    case .identifier(let name):
      if variables[name] == nil, let phrase = parseDatePhrase(name, range: token.range) {
        return phrase
      }
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
      return variableName(startingWith: name, range: token.range)

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
      guard startsUnitExpression(at: 1) else {
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

  /// Consumes the longest declared multi-word name starting at `first`.
  private mutating func variableName(
    startingWith first: String,
    range: SourceRange
  ) -> Expression {
    var words = [first]
    while words.count < maximumNameWords, let word = identifier(at: words.count - 1) {
      words.append(word)
    }
    while words.count > 1, variables[words.joined(separator: " ")] == nil {
      words.removeLast()
    }
    if words.count == 1, variables[first] == nil {
      if let reference = referenceKeywords[first] {
        return .reference(reference, range: range)
      }
      if first == "line",
        case .number(.integer(let digits, .decimal)) = current.kind,
        let number = Int(digits)
      {
        return .reference(.line(number), range: range.union(advance().range))
      }
    }
    var end = range
    for _ in 1..<words.count {
      end = advance().range
    }
    return .identifier(words.joined(separator: " "), range: range.union(end))
  }

  /// The IANA identifier named by the tokens at an offset, and how many tokens
  /// name it: `Asia/Tokyo`, `America/Argentina/Buenos_Aires`, `Tokyo`, or
  /// `New York`. The longest name wins.
  private func timeZone(at offset: Int) -> (identifier: String, tokenCount: Int)? {
    guard let first = identifier(at: offset) else {
      return nil
    }
    var path = first
    var pathCount = 1
    while token(at: offset + pathCount).kind == .divide,
      let part = identifier(at: offset + pathCount + 1)
    {
      path += "/" + part
      pathCount += 2
    }
    if pathCount > 1, let zone = TimeZoneNames.identifier(for: path) {
      return (zone, pathCount)
    }
    if let second = identifier(at: offset + 1),
      let zone = TimeZoneNames.identifier(for: first + " " + second)
    {
      return (zone, 2)
    }
    return TimeZoneNames.identifier(for: first).map { ($0, 1) }
  }

  /// `today`, `now`, `next friday`, or a month-name date such as `March 9`.
  private mutating func parseDatePhrase(_ word: String, range: SourceRange) -> Expression? {
    let lowercased = word.lowercased()
    if let days = relativeDays[lowercased] {
      return .temporal(.relativeDay(days), range: range)
    }
    if lowercased == "now" {
      return .temporal(.now, range: range)
    }
    if lowercased == "next" || lowercased == "last",
      let name = identifier(at: 0), let weekday = weekdayNames[name.lowercased()]
    {
      return .temporal(
        .weekday(weekday, isNext: lowercased == "next"), range: range.union(advance().range))
    }
    if let month = monthNames[lowercased],
      case .number(.integer(let digits, .decimal)) = current.kind, digits.count <= 2
    {
      let dayRange = advance().range
      return parseYear(month: month, day: Int(digits)!, range: range.union(dayRange))
    }
    return nil
  }

  /// A date with the year that follows, as in `March 9, 2024` or `9 March
  /// 2024`, or in the current year.
  private mutating func parseYear(month: Int, day: Int, range: SourceRange) -> Expression {
    let comma = current.kind == .argumentSeparator ? 1 : 0
    guard case .number(.integer(let digits, .decimal)) = token(at: comma).kind, digits.count == 4
    else {
      return .temporal(.date(year: nil, month: month, day: day), range: range)
    }
    if comma == 1 {
      advance()
    }
    return .temporal(
      .date(year: Int(digits)!, month: month, day: day), range: range.union(advance().range))
  }

  /// A 12-hour time such as `3:30 pm`.
  private mutating func parseMeridiem(_ literal: TemporalLiteral, range: SourceRange) -> Expression
  {
    guard case .time(let hour, let minute, let second) = literal,
      let word = identifier(at: 0)?.lowercased(), word == "am" || word == "pm"
    else {
      return .temporal(literal, range: range)
    }
    let meridiem = advance()
    guard (1...12).contains(hour) else {
      diagnose(.unexpectedToken, at: meridiem.range)
      return .temporal(literal, range: range)
    }
    let hour24 = hour % 12 + (word == "pm" ? 12 : 0)
    return .temporal(
      .time(hour: hour24, minute: minute, second: second), range: range.union(meridiem.range))
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
    case .identifier(let name, _):
      return variables[name] ?? .number
    case .literal, .call, .reference:
      return .number
    case .quantity, .conversion:
      return .quantity
    case .period:
      return .period
    case .temporal(let literal, _):
      switch literal {
      case .date, .relativeDay, .weekday:
        return .date
      case .time:
        return .time
      case .dateTime, .now:
        return .instant
      }
    case .relative:
      return .date
    case .zoneConversion:
      return .instant
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
      if leftKind == .period || rightKind == .period {
        return .period
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
