public struct Parser: Sendable {
  private let source: String
  private let configuration: LexingConfiguration
  private let limits: SyntaxLimits
  private let catalog: UnitCatalog
  private let origin: SourceLocation
  private let variables: [String: EngineValueKind]
  private let dollarCurrency: String

  /// `variables` maps declared names, whose words are joined by single
  /// spaces, to the kind of value they hold.
  public init(
    source: String,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default,
    catalog: UnitCatalog? = nil,
    origin: SourceLocation = .start,
    variables: [String: EngineValueKind] = [:],
    dollarCurrency: String = "USD"
  ) {
    self.source = source
    self.configuration = configuration
    self.limits = limits
    self.catalog = catalog ?? builtInMinimalUnitCatalog
    self.origin = origin
    self.variables = variables
    self.dollarCurrency = dollarCurrency
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

    let tokenParser = TokenParser(
      source: source,
      origin: origin,
      tokens: lexingResult.tokens,
      maximumParseDepth: limits.maximumParseDepth,
      catalog: catalog,
      variables: variables,
      dollarCurrency: dollarCurrency
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

/// Words that raise the unit after them: `sq ft`, `cubic m`.
let unitPowerWords: [String: Int] = ["sq": 2, "square": 2, "cu": 3, "cubic": 3]

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

/// A class so recursive descent does not copy the token list onto every
/// stack frame; debug builds overflow that way on nested parentheses.
private final class TokenParser {
  private static let prefixBindingPower = 25

  private let source: String
  private let origin: SourceLocation
  private let tokens: [Token]
  private let maximumParseDepth: Int
  private let catalog: UnitCatalog
  private let variables: [String: EngineValueKind]
  private let dollarCurrency: String
  private let maximumNameWords: Int
  private var cursor = 0
  private(set) var diagnostics: [SyntaxDiagnostic] = []

  init(
    source: String,
    origin: SourceLocation,
    tokens: [Token],
    maximumParseDepth: Int,
    catalog: UnitCatalog,
    variables: [String: EngineValueKind],
    dollarCurrency: String
  ) {
    self.source = source
    self.origin = origin
    self.tokens = tokens
    self.maximumParseDepth = maximumParseDepth
    self.catalog = catalog
    self.variables = variables
    self.dollarCurrency = dollarCurrency
    maximumNameWords =
      variables.keys.map { $0.split(separator: " ").count }.max() ?? 1
  }

  func parse() -> Expression? {
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
  private func advance() -> Token {
    let token = current
    if cursor < tokens.count - 1 {
      cursor += 1
    }
    return token
  }

  private func parseExpression(
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

      if let word = identifier(at: 0),
        ["percent", "percents", "pct"].contains(word.lowercased())
      {
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
        canAttachUnit(to: left),
        let word = identifier(at: 0),
        variables[word] == nil,
        catalog.resolveUnit(matching: word) == nil,
        let digits = ScaleWord.digits[word]
      {
        let token = advance()
        left = .grouped(
          .infix(
            left: left,
            operator: .multiply,
            right: .literal(.integer(digits: digits, radix: .decimal), range: token.range),
            operatorRange: token.range,
            range: left.range.union(token.range)
          ),
          range: left.range.union(token.range)
        )
        depth += 1
        continue
      }

      if 29 >= minimumBindingPower, canAttachUnit(to: left),
        case .currencySymbol(let symbol) = current.kind
      {
        let token = advance()
        guard let code = CurrencyCatalog.currency(for: symbol, dollarCurrency: dollarCurrency)
        else {
          diagnose(.ambiguousCurrencySymbol, at: token.range, severity: .ambiguity)
          return left
        }
        left = .money(amount: left, currency: code, range: left.range.union(token.range))
        depth += 1
        continue
      }

      if let money = parseMoneySuffix(of: left, minimumBindingPower: minimumBindingPower) {
        left = money
        depth += 1
        continue
      }

      if 29 >= minimumBindingPower, let mixed = parseMixedUnits(after: left, depth: depth) {
        left = mixed
        depth += 1
        continue
      }

      if 29 >= minimumBindingPower, let price = parseUnitPrice(of: left, depth: depth) {
        left = price
        depth += 1
        continue
      }

      let diagnosticCount = diagnostics.count
      if let suffixed = parseTemporalSuffix(of: left, minimumBindingPower: minimumBindingPower) {
        guard diagnostics.count == diagnosticCount else {
          return left
        }
        left = suffixed
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
        startsUnitExpression(at: 0),
        !convertsToPercentage(at: 0), !convertsToCurrency(at: 0)
      {
        guard let quantity = parseQuantity(magnitude: left, depth: depth)
        else {
          return left
        }
        left = quantity
        depth += 1
        continue
      }

      // `0.25 as %` is the percentage a ratio is: `25%`.
      if 1 >= minimumBindingPower, convertsToPercentage(at: 0) {
        let keywordToken = advance()
        let percent = advance()
        let hundred = Expression.literal(
          .integer(digits: "100", radix: .decimal), range: keywordToken.range)
        left = .percentage(
          points: .infix(
            left: left, operator: .multiply, right: hundred, operatorRange: keywordToken.range,
            range: left.range.union(keywordToken.range)),
          percentRange: percent.range,
          range: left.range.union(percent.range)
        )
        depth += 2
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

  private func parsePrefix(depth: Int) -> Expression? {
    let token = advance()
    switch token.kind {
    case .number(let literal):
      return .literal(literal, range: token.range)

    case .temporal(let literal):
      return parseTemporal(literal, range: token.range)

    case .currencySymbol(let symbol):
      return parseCurrencySymbol(symbol, range: token.range, depth: depth)

    case .identifier(let name):
      if variables[name] == nil, let phrase = parseDatePhrase(name, range: token.range) {
        return phrase
      }
      if current.kind == .leftParenthesis {
        if AssistantFunction(rawValue: name) != nil {
          return parseAssistantCall(name: name, identifierRange: token.range)
        }
        return parseCall(
          name: name,
          identifierRange: token.range,
          depth: depth
        )
      }
      if variables[name] == nil, startsMoneyAmount {
        if CurrencyCatalog.minorUnits[name] != nil {
          return parsePrefixedCurrency(name, range: token.range, depth: depth)
        }
        if let code = CurrencyCatalog.names[name.lowercased()] {
          return parsePrefixedCurrency(code, range: token.range, depth: depth)
        }
        if let period = CalendarPeriodUnit(word: name) {
          return parsePrefixedPeriod(period, range: token.range, depth: depth)
        }
        if ScaleWord.digits[name] != nil {
          return parsePrefixedScale(name, range: token.range, depth: depth)
        }
      }
      if let unit = parseUnitAfterDivide(name, range: token.range, depth: depth) {
        return unit
      }
      if variables[name] == nil, catalog.resolveUnit(matching: name) != nil,
        hasAmountAfterPrefixedUnit
      {
        return parsePrefixedQuantity(alias: name, range: token.range, depth: depth)
      }
      if name == "percentage", identifier(at: 0) == "change" {
        return parsePercentageChange(
          startRange: token.range,
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
        // Something other than `)` inside is the problem, not a missing `)`.
        if current.isEndOfInput {
          diagnose(.expectedClosingParenthesis, at: current.range, severity: .incomplete)
        } else {
          diagnose(.unexpectedToken, at: current.range)
        }
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

  private func parsePercentageChange(
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

  /// The text between the parentheses is the prompt, including spaces and
  /// words that are not expressions.
  private func parseAssistantCall(
    name: String,
    identifierRange: SourceRange
  ) -> Expression {
    advance()
    let promptStart = current.range.lowerBound
    var depth = 1
    while current.kind != .endOfFile, current.kind != .newline {
      if current.kind == .leftParenthesis {
        depth += 1
      } else if current.kind == .rightParenthesis {
        depth -= 1
        if depth == 0 {
          let prompt = slice(from: promptStart, to: current.range.lowerBound)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          let closing = advance()
          return .assistantPrompt(
            name: name,
            prompt: prompt,
            nameRange: identifierRange,
            range: identifierRange.union(closing.range)
          )
        }
      }
      advance()
    }
    diagnose(
      .expectedClosingParenthesis,
      at: current.range,
      severity: .incomplete
    )
    return .assistantPrompt(
      name: name,
      prompt: slice(from: promptStart, to: current.range.lowerBound)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      nameRange: identifierRange,
      range: identifierRange.union(current.range)
    )
  }

  private func slice(from lowerBound: Int, to upperBound: Int) -> String {
    let start = lowerBound - origin.utf8Offset
    let length = upperBound - lowerBound
    let utf8 = source.utf8
    guard start >= 0, length >= 0, start + length <= utf8.count else {
      return ""
    }
    let lower = utf8.index(utf8.startIndex, offsetBy: start)
    let upper = utf8.index(lower, offsetBy: length)
    return String(source[lower..<upper])
  }

  private func parseCall(
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
  private func parseRatioPhrase(
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

  private func parseReversePhrase(
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

  private func parsePercentageOf(
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

  private func parseQuantity(
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

  private func parseConversion(
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
    guard var target = parseUnitExpression(depth: depth + 1) else {
      return nil
    }
    // `in L/100 km`: a target unit per a count of another unit.
    if current.kind == .divide, case .number(.integer(let digits, .decimal)) = token(at: 1).kind,
      let count = Int(digits), count > 0, startsUnitExpression(at: 2)
    {
      advance()
      let number = advance()
      guard let unit = parseUnitFactor(depth: depth + 1) else {
        return nil
      }
      let counted = UnitSyntax.counted(count, unit, range: number.range.union(unit.range))
      target = .divided(target, counted, range: target.range.union(counted.range))
    }
    return .conversion(
      value: value,
      target: target,
      keywordRange: keywordToken.range,
      range: value.range.union(target.range)
    )
  }

  private func parseUnitExpression(depth: Int) -> UnitSyntax? {
    guard depth <= maximumParseDepth else {
      diagnose(.resourceLimitExceeded, at: current.range)
      return nil
    }
    guard let left = parseUnitFactor(depth: depth) else {
      return nil
    }
    return parseUnitProduct(starting: left, depth: depth)
  }

  /// Continues `km/s` after the first factor has been read.
  private func parseUnitProduct(starting left: UnitSyntax, depth: Int) -> UnitSyntax {
    var left = left
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

  private func parseUnitFactor(depth: Int) -> UnitSyntax? {
    let start = current
    var unit: UnitSyntax
    if let powered = parsePoweredUnitWord() {
      unit = powered
    } else if case .identifier(let alias) = start.kind,
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

    return applyOptionalUnitPower(to: unit)
  }

  /// `sq ft` and `cubic m`: a power written as a word before its unit.
  @inline(never)
  private func parsePoweredUnitWord() -> UnitSyntax? {
    guard let word = identifier(at: 0), variables[word] == nil,
      let exponent = unitPowerWords[word], let alias = identifier(at: 1),
      let resolved = catalog.resolveUnit(matching: alias)
    else {
      return nil
    }
    let wordToken = advance()
    let unitToken = advance()
    return .raised(
      .named(resolved.entry, prefix: resolved.prefix, range: unitToken.range),
      exponent: exponent,
      range: wordToken.range.union(unitToken.range))
  }

  private func applyOptionalUnitPower(to unit: UnitSyntax) -> UnitSyntax {
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

  private func diagnoseRepeatedUnitPower() {
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
    case .counted(let count, let unit, _):
      return .counted(count, unit, range: range)
    }
  }

  private func diagnose(
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

  /// `in EUR`, where `in` would otherwise be inches: `$10 in EUR`.
  private func convertsToCurrency(at offset: Int) -> Bool {
    guard let keyword = identifier(at: offset), let code = identifier(at: offset + 1) else {
      return false
    }
    return ["in", "to", "as", "into"].contains(keyword) && CurrencyCatalog.minorUnits[code] != nil
  }

  /// `as %`, where `as` would otherwise be attoseconds and `in` inches.
  private func convertsToPercentage(at offset: Int) -> Bool {
    guard let keyword = identifier(at: offset) else {
      return false
    }
    return ["in", "to", "as", "into"].contains(keyword) && token(at: offset + 1).kind == .percent
  }

  private func identifier(at offset: Int) -> String? {
    guard case .identifier(let name) = token(at: offset).kind else {
      return nil
    }
    return name
  }

  /// Consumes the longest declared multi-word name starting at `first`.
  private func variableName(
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
  @inline(never)
  private func parseDatePhrase(_ word: String, range: SourceRange) -> Expression? {
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
  private func parseYear(month: Int, day: Int, range: SourceRange) -> Expression {
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

  // Money and temporal parsing live in non-inlined methods so the recursive
  // `parseExpression` and `parsePrefix` frames stay small.

  /// A currency code after a number, `12.50 EUR`, a currency name,
  /// `5 dollars`, or a conversion to one, `100 USD in INR`.
  @inline(never)
  private func parseMoneySuffix(
    of left: Expression,
    minimumBindingPower: Int
  ) -> Expression? {
    if 29 >= minimumBindingPower, canAttachUnit(to: left),
      let word = identifier(at: 0), variables[word] == nil
    {
      if CurrencyCatalog.minorUnits[word] != nil {
        return .money(amount: left, currency: word, range: left.range.union(advance().range))
      }
      if let code = CurrencyCatalog.names[word.lowercased()] {
        return .money(amount: left, currency: code, range: left.range.union(advance().range))
      }
    }
    guard 1 >= minimumBindingPower, let keyword = identifier(at: 0),
      ["in", "to", "as", "into"].contains(keyword),
      let code = identifier(at: 1), CurrencyCatalog.minorUnits[code] != nil
    else {
      return nil
    }
    advance()
    return .currencyConversion(
      value: left, currency: code, range: left.range.union(advance().range))
  }

  /// An amount after a currency symbol, `$1.50` or `€12.50`. `$` means the
  /// sheet's dollar currency; `¥` means yen.
  @inline(never)
  private func parseCurrencySymbol(_ symbol: String, range: SourceRange, depth: Int)
    -> Expression?
  {
    guard let code = CurrencyCatalog.currency(for: symbol, dollarCurrency: dollarCurrency) else {
      diagnose(.ambiguousCurrencySymbol, at: range, severity: .ambiguity)
      return nil
    }
    guard
      let amount = parseExpression(minimumBindingPower: Self.prefixBindingPower, depth: depth + 1)
    else {
      return nil
    }
    return .money(amount: amount, currency: code, range: range.union(amount.range))
  }

  /// An amount after a currency code, `USD 1.5`.
  @inline(never)
  private func parsePrefixedCurrency(_ code: String, range: SourceRange, depth: Int)
    -> Expression?
  {
    guard let amount = parsePrefixedAmount(depth: depth) else {
      return nil
    }
    return .money(amount: amount, currency: code, range: range.union(amount.range))
  }

  /// `5 ft 10 in` and `2 h 30 min`: a number with a unit right after another
  /// adds to it, as people write mixed units.
  @inline(never)
  private func parseMixedUnits(after left: Expression, depth: Int) -> Expression? {
    guard case .quantity(.literal, _, _) = left,
      case .number(let literal) = current.kind, startsUnitExpression(at: 1)
    else {
      return nil
    }
    let number = advance()
    guard let unit = parseUnitExpression(depth: depth + 1) else {
      return nil
    }
    let right = Expression.quantity(
      magnitude: .literal(literal, range: number.range), unit: unit,
      range: number.range.union(unit.range))
    return .infix(
      left: left, operator: .add, right: right, operatorRange: number.range,
      range: left.range.union(right.range))
  }

  /// `0.15 USD/kWh` is one price, binding as tightly as a unit does, so
  /// `45 kWh * 0.15 USD/kWh` prices the energy. Kept out of the recursive
  /// loop so its frame stays small.
  @inline(never)
  private func parseUnitPrice(of left: Expression, depth: Int) -> Expression? {
    guard case .money = left, current.kind == .divide,
      let word = identifier(at: 1), variables[word] == nil,
      catalog.resolveUnit(matching: word) != nil
    else {
      return nil
    }
    let divide = advance()
    guard let unit = parsePrefix(depth: depth + 1) else {
      return nil
    }
    return .infix(
      left: left, operator: .divide, right: unit, operatorRange: divide.range,
      range: left.range.union(unit.range))
  }

  /// `$0.15/kWh`: a unit alone after `/` is one of it, so a price can be per
  /// unit.
  @inline(never)
  private func parseUnitAfterDivide(_ name: String, range: SourceRange, depth: Int)
    -> Expression?
  {
    guard variables[name] == nil, cursor >= 2, tokens[cursor - 2].kind == .divide,
      let resolved = catalog.resolveUnit(matching: name)
    else {
      return nil
    }
    let unit = parseUnitProduct(
      starting: applyOptionalUnitPower(
        to: .named(resolved.entry, prefix: resolved.prefix, range: range)),
      depth: depth + 1
    )
    return .quantity(
      magnitude: .literal(.integer(digits: "1", radix: .decimal), range: range),
      unit: unit, range: unit.range)
  }

  /// A quantity after a unit, `kg 5` or `km/h 60`.
  @inline(never)
  private func parsePrefixedQuantity(alias: String, range: SourceRange, depth: Int)
    -> Expression?
  {
    guard let resolved = catalog.resolveUnit(matching: alias) else {
      return nil
    }
    let unit = parseUnitProduct(
      starting: applyOptionalUnitPower(
        to: .named(resolved.entry, prefix: resolved.prefix, range: range)),
      depth: depth + 1
    )
    guard let amount = parsePrefixedAmount(depth: depth) else {
      return nil
    }
    return .quantity(magnitude: amount, unit: unit, range: range.union(amount.range))
  }

  /// A calendar period after its unit, `days 3`.
  @inline(never)
  private func parsePrefixedPeriod(
    _ unit: CalendarPeriodUnit,
    range: SourceRange,
    depth: Int
  ) -> Expression? {
    guard let count = parsePrefixedAmount(depth: depth) else {
      return nil
    }
    return .period(count: count, unit: unit, range: range.union(count.range))
  }

  /// A scale word before an amount, `million 11.5`.
  @inline(never)
  private func parsePrefixedScale(_ word: String, range: SourceRange, depth: Int)
    -> Expression?
  {
    guard let digits = ScaleWord.digits[word], let amount = parsePrefixedAmount(depth: depth)
    else {
      return nil
    }
    let scale = Expression.literal(.integer(digits: digits, radix: .decimal), range: range)
    let product = Expression.infix(
      left: scale,
      operator: .multiply,
      right: amount,
      operatorRange: range,
      range: range.union(amount.range)
    )
    return .grouped(product, range: product.range)
  }

  private func parsePrefixedAmount(depth: Int) -> Expression? {
    parseExpression(minimumBindingPower: Self.prefixBindingPower, depth: depth + 1)
  }

  private var startsMoneyAmount: Bool {
    switch current.kind {
    case .number, .leftParenthesis, .plus, .minus:
      return true
    default:
      return false
    }
  }

  /// Whether `km 12` or `km/h 60` still has an amount after the unit.
  private var hasAmountAfterPrefixedUnit: Bool {
    var index = skipUnitPower(at: 0)
    while token(at: index).kind == .multiply || token(at: index).kind == .divide {
      guard startsKnownUnit(at: index + 1) else {
        break
      }
      index = skipUnitPower(at: index + 2)
    }
    switch token(at: index).kind {
    case .number:
      return true
    default:
      return false
    }
  }

  private func skipUnitPower(at index: Int) -> Int {
    if case .superscript = token(at: index).kind {
      return index + 1
    }
    guard token(at: index).kind == .power else {
      return index
    }
    var next = index + 1
    if token(at: next).kind == .plus || token(at: next).kind == .minus {
      next += 1
    }
    if case .number = token(at: next).kind {
      return next + 1
    }
    return index
  }

  /// A date phrase or zone that follows `left`: `9 March`, `3 days ago`,
  /// `2 h from now`, or `now in Asia/Tokyo`. Reports an unknown zone after an
  /// instant.
  @inline(never)
  private func parseTemporalSuffix(
    of left: Expression,
    minimumBindingPower: Int
  ) -> Expression? {
    if 29 >= minimumBindingPower,
      case .literal(.integer(let digits, .decimal), let range) = left, digits.count <= 2,
      let word = identifier(at: 0), variables[word] == nil,
      let month = monthNames[word.lowercased()]
    {
      let monthRange = advance().range
      return parseYear(month: month, day: Int(digits)!, range: range.union(monthRange))
    }
    guard 1 >= minimumBindingPower, let keyword = identifier(at: 0) else {
      return nil
    }
    if keyword == "ago" || (keyword == "from" && identifier(at: 1) == "now") {
      var end = advance().range
      if keyword == "from" {
        end = advance().range
      }
      return .relative(offset: left, isPast: keyword == "ago", range: left.range.union(end))
    }
    guard ["in", "to", "as", "into"].contains(keyword),
      timeZone(at: 1) != nil || inferredKind(of: left) == .instant
    else {
      return nil
    }
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
    return .zoneConversion(value: left, zone: zone, range: left.range.union(end))
  }

  /// A temporal token with the zone or `am`/`pm` that follows it.
  @inline(never)
  private func parseTemporal(_ literal: TemporalLiteral, range: SourceRange) -> Expression {
    if case .dateTime(var dateTime) = literal {
      var range = range
      if let (zone, tokenCount) = timeZone(at: 0) {
        dateTime.zone = zone
        for _ in 0..<tokenCount {
          range = range.union(advance().range)
        }
      }
      return .temporal(.dateTime(dateTime), range: range)
    }
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
    if unitPowerWords[alias] != nil, variables[alias] == nil {
      return startsKnownUnit(at: offset + 1)
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
    case .literal, .call, .reference, .assistantPrompt:
      return .number
    case .quantity, .conversion:
      return .quantity
    case .money, .currencyConversion:
      return .money
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
      if leftKind == .money || rightKind == .money {
        return .money
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
    case .literal, .grouped, .call, .assistantPrompt:
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
