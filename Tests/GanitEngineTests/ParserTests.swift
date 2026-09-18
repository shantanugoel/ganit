import Testing

@testable import GanitEngine

@Suite
struct ParserTests {
  @Test
  func appliesPrecedenceAndRightAssociativePowers() throws {
    let expression = try parse("1 + 2 * 3 ^ 4 ^ 5")

    #expect(shape(expression) == "(1 + (2 * (3 ^ (4 ^ 5))))")
  }

  @Test
  func bindsPowersMoreTightlyThanUnarySigns() throws {
    #expect(shape(try parse("-2^2")) == "(-(2 ^ 2))")
    #expect(shape(try parse("2^-3")) == "(2 ^ (-3))")
  }

  @Test
  func preservesExplicitGrouping() throws {
    let expression = try parse("(1 + 2) * 3")

    #expect(shape(expression) == "(((1 + 2)) * 3)")
    #expect(
      expression.range
        == SourceRange(
          lowerBound: 0,
          upperBound: 11,
          graphemeLowerBound: 0,
          graphemeUpperBound: 11
        )
    )
  }

  @Test
  func acceptsOnlyAdjacentUnambiguousImplicitMultiplication() throws {
    let implicitShape = shape(try parse("2π + 2(3) + (1 + 1)3"))
    #expect(
      implicitShape == "(((2 * π) + (2 * (3))) + (((1 + 1)) * 3))"
    )

    let separatedNumbers = Parser(source: "2 3").parse()
    let separatedIdentifier = Parser(source: "2 π").parse()
    #expect(separatedNumbers.expression == nil)
    #expect(separatedIdentifier.expression == nil)
    #expect(separatedNumbers.diagnostics.first?.code == .unexpectedToken)
    #expect(separatedIdentifier.diagnostics.first?.code == .unexpectedToken)
  }

  @Test
  func parsesNestedFunctionCalls() throws {
    let expression = try parse("max(1 + 2, sqrt(9))")

    #expect(shape(expression) == "max((1 + 2),sqrt(9))")
  }

  @Test
  func keepsAssistantPromptTextUnparsed() throws {
    #expect(
      shape(try parse("ask_assistant(10 kg of water in ml)"))
        == "ask_assistant{10 kg of water in ml}"
    )
    #expect(
      shape(try parse("prompt_assistant(density of water)"))
        == "prompt_assistant{density of water}"
    )
    #expect(
      shape(try parse("ask_assistant(10 kg of water in ml) * 2"))
        == "(ask_assistant{10 kg of water in ml} * 2)"
    )
    #expect(
      try parse("ask_assistant(10 kg of water in ml) * 2").assistantPrompts
        == ["10 kg of water in ml"]
    )
    #expect(
      try parse("prompt_assistant(density of water)").assistantPrompts == ["density of water"])
    #expect(try parse("2 + 2").assistantPrompts.isEmpty)
  }

  @Test
  func parsesPercentagePhrasesAndPrecedence() throws {
    #expect(try shape(parse("20%")) == "20%")
    #expect(try shape(parse("2^3%")) == "(2 ^ 3%)")
    #expect(try shape(parse("(2^3)%")) == "((2 ^ 3))%")
    #expect(try shape(parse("20% of 50 + 2")) == "((20% of 50) + 2)")
    #expect(try shape(parse("(20% of 50) + 2")) == "(((20% of 50)) + 2)")
    #expect(try shape(parse("20% off 50")) == "(20% off 50)")
    #expect(try shape(parse("20% on 50")) == "(20% on 50)")
    #expect(
      try shape(parse("50 is what % of 200"))
        == "(50 is what % of 200)"
    )
    #expect(
      try shape(parse("50 is what % of 200 + 50"))
        == "(50 is what % of (200 + 50))"
    )
    #expect(
      try shape(parse("percentage change from 80 to 100"))
        == "(80 percentage change to 100)"
    )
    #expect(
      try shape(parse("80 after 20% off"))
        == "(80 after % off 20%)"
    )
  }

  @Test
  func marksUnfinishedPercentagePhrasesAsIncomplete() {
    for source in [
      "50 is",
      "50 is what",
      "50 is what %",
      "50 is what % of",
      "20% of",
      "20% off",
      "8% on",
      "percentage change",
      "percentage change from",
      "percentage change from 80",
      "percentage change from 80 to",
      "80 after",
      "80 after 20%",
    ] {
      let result = Parser(source: source).parse()
      #expect(
        result.diagnostics.contains {
          $0.severity == .incomplete
            && $0.code == .expectedPercentagePhrase
        },
        "Expected an incomplete diagnostic for \(source)"
      )
    }
  }

  @Test
  func parsesSemicolonArgumentsWithCommaDecimals() throws {
    let configuration = LexingConfiguration(
      decimalSeparator: ",",
      groupingSeparator: "."
    )
    let result = Parser(
      source: "max(1; 2) + 1,5",
      configuration: configuration
    ).parse()

    #expect(result.diagnostics.isEmpty)
    #expect(
      shape(try #require(result.expression))
        == "(max(1,2) + 15:1e0)"
    )
  }

  @Test
  func preservesUnicodeExpressionRange() throws {
    let source = "π + ٢"
    let expression = try parse(source)

    #expect(
      expression.range
        == SourceRange(
          lowerBound: 0,
          upperBound: 7,
          graphemeLowerBound: 0,
          graphemeUpperBound: 5
        )
    )
    #expect(try #require(expression.range.text(in: source)) == source)
  }

  @Test
  func reportsIncompleteExpressionAtEndOfSource() {
    let result = Parser(source: "2 +").parse()

    #expect(result.expression == nil)
    #expect(result.diagnostics.map(\.code) == [.expectedExpression])
    #expect(result.diagnostics[0].severity == .incomplete)
    #expect(
      result.diagnostics[0].range
        == SourceRange(
          lowerBound: 3,
          upperBound: 3,
          graphemeLowerBound: 3,
          graphemeUpperBound: 3
        )
    )
  }

  @Test
  func distinguishesIncompleteInputFromCompleteSyntaxErrors() {
    let unexpectedClosing = Parser(source: ")").parse()
    let missingOperand = Parser(source: "1 + )").parse()
    let invalidGroupedSeparator = Parser(source: "(1,2)").parse()

    #expect(unexpectedClosing.diagnostics.first?.severity == .error)
    #expect(missingOperand.diagnostics.first?.severity == .error)
    #expect(invalidGroupedSeparator.diagnostics.first?.severity == .error)
    // What is inside is the problem, not a missing `)`.
    #expect(invalidGroupedSeparator.diagnostics.first?.code == .unexpectedToken)
    #expect(Parser(source: "(5 apples)").parse().diagnostics.first?.code == .unexpectedToken)
    #expect(Parser(source: "(1 + 2").parse().diagnostics.first?.code == .expectedClosingParenthesis)
  }

  @Test
  func reportsMissingParenthesesAndArgumentSeparators() {
    let missingParenthesis = Parser(source: "sqrt(9").parse()
    #expect(missingParenthesis.diagnostics.map(\.code) == [.expectedClosingParenthesis])

    let missingSeparator = Parser(source: "max(1 2)").parse()
    #expect(missingSeparator.diagnostics.map(\.code) == [.expectedArgumentSeparator])
  }

  @Test
  func rejectsMultipleLogicalLines() {
    let result = Parser(source: "1\n2").parse()

    #expect(result.expression == nil)
    #expect(result.diagnostics.map(\.code) == [.unexpectedToken])
    #expect(
      result.diagnostics[0].range
        == SourceRange(
          lowerBound: 1,
          upperBound: 2,
          graphemeLowerBound: 1,
          graphemeUpperBound: 2
        )
    )
  }

  @Test
  func doesNotReturnASTWhenLexingFails() {
    let result = Parser(source: "1 + @").parse()

    #expect(result.expression == nil)
    #expect(result.diagnostics.map(\.code) == [.unexpectedCharacter, .expectedExpression])
  }

  @Test
  func enforcesSourceTokenAndParseDepthLimits() {
    let sourceLimited = Parser(
      source: "1 + 2",
      limits: SyntaxLimits(
        maximumSourceUTF8Length: 4,
        maximumTokenCount: 100,
        maximumParseDepth: 100
      )
    ).parse()
    #expect(sourceLimited.diagnostics.map(\.code) == [.resourceLimitExceeded])

    let tokenLimited = Parser(
      source: "1 + 2",
      limits: SyntaxLimits(
        maximumSourceUTF8Length: 100,
        maximumTokenCount: 2,
        maximumParseDepth: 100
      )
    ).parse()
    #expect(tokenLimited.diagnostics.map(\.code) == [.resourceLimitExceeded])

    let depthLimited = Parser(
      source: "((((1))))",
      limits: SyntaxLimits(
        maximumSourceUTF8Length: 100,
        maximumTokenCount: 100,
        maximumParseDepth: 4
      )
    ).parse()
    #expect(depthLimited.diagnostics.map(\.code) == [.resourceLimitExceeded])
  }

  private func parse(_ source: String) throws -> Expression {
    let result = Parser(source: source).parse()
    #expect(result.diagnostics.isEmpty)
    return try #require(result.expression)
  }

  private func shape(_ expression: Expression) -> String {
    switch expression {
    case .literal(let literal, _):
      switch literal {
      case .integer(let digits, _):
        return digits
      case .decimal(let digits, let fractionalDigitCount, let exponent):
        return "\(digits):\(fractionalDigitCount)e\(exponent)"
      }
    case .identifier(let name, _):
      return name
    case .prefix(let unaryOperator, let operand, _, _):
      let symbol = unaryOperator == .plus ? "+" : "-"
      return "(\(symbol)\(shape(operand)))"
    case .infix(let left, let binaryOperator, let right, _, _):
      return "(\(shape(left)) \(symbol(binaryOperator)) \(shape(right)))"
    case .call(let name, _, let arguments, _):
      return "\(name)(\(arguments.map(shape).joined(separator: ",")))"
    case .percentage(let points, _, _):
      return "\(shape(points))%"
    case .percentageOperation(
      let percentageOperator,
      let left,
      let right,
      _,
      _
    ):
      return
        "(\(shape(left)) \(percentageSymbol(percentageOperator)) \(shape(right)))"
    case .quantity(let magnitude, let unit, _):
      return "\(shape(magnitude)) \(unitShape(unit))"
    case .period(let count, let unit, _):
      return "\(shape(count)) \(unit.rawValue)"
    case .temporal(let literal, _):
      return "\(literal)"
    case .money(let amount, let currency, _):
      return "\(shape(amount)) \(currency)"
    case .currencyConversion(let value, let currency, _):
      return "(\(shape(value)) in \(currency))"
    case .zoneConversion(let value, let zone, _):
      return "(\(shape(value)) in \(zone))"
    case .relative(let offset, let isPast, _):
      return "(\(shape(offset)) \(isPast ? "ago" : "from now"))"
    case .conversion(let value, let target, _, _):
      return "(\(shape(value)) -> \(unitShape(target)))"
    case .grouped(let expression, _):
      return "(\(shape(expression)))"
    case .reference(let reference, _):
      return "@\(reference)"
    case .assistantPrompt(let name, let prompt, _, _):
      return "\(name){\(prompt)}"
    }
  }

  private func unitShape(_ unit: UnitSyntax) -> String {
    switch unit {
    case .named(let entry, let prefix, _):
      return (prefix?.prefix.symbol ?? "") + entry.definition.symbol
    case .multiplied(let left, let right, _):
      return "\(unitShape(left))·\(unitShape(right))"
    case .divided(let left, let right, _):
      return "\(unitShape(left))/\(unitShape(right))"
    case .raised(let nested, let exponent, _):
      return "\(unitShape(nested))^\(exponent)"
    case .counted(let count, let nested, _):
      return "\(count) \(unitShape(nested))"
    }
  }

  private func percentageSymbol(
    _ percentageOperator: PercentageOperator
  ) -> String {
    switch percentageOperator {
    case .of: "of"
    case .off: "off"
    case .on: "on"
    case .ratio: "is what % of"
    case .change: "percentage change to"
    case .reverseOff: "after % off"
    case .reverseOn: "after % on"
    }
  }

  private func symbol(_ binaryOperator: BinaryOperator) -> String {
    switch binaryOperator {
    case .add:
      return "+"
    case .subtract:
      return "-"
    case .multiply:
      return "*"
    case .divide:
      return "/"
    case .power:
      return "^"
    case .bitwiseAnd:
      return "&"
    case .bitwiseOr:
      return "|"
    case .shiftLeft:
      return "<<"
    case .shiftRight:
      return ">>"
    }
  }
}
