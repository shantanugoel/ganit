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
  func parsesNestedFunctionCalls() throws {
    let expression = try parse("max(1 + 2, sqrt(9))")

    #expect(shape(expression) == "max((1 + 2),sqrt(9))")
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
    case .prefix(let unaryOperator, let operand, _):
      let symbol = unaryOperator == .plus ? "+" : "-"
      return "(\(symbol)\(shape(operand)))"
    case .infix(let left, let binaryOperator, let right, _):
      return "(\(shape(left)) \(symbol(binaryOperator)) \(shape(right)))"
    case .call(let name, let arguments, _):
      return "\(name)(\(arguments.map(shape).joined(separator: ",")))"
    case .grouped(let expression, _):
      return "(\(shape(expression)))"
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
    }
  }
}
