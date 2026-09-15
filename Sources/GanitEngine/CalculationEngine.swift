public enum CalculationResult: Hashable, Sendable {
  case value(EngineValue)
  case syntaxFailure([SyntaxDiagnostic])
  case evaluationFailure(EngineError)
}

public struct SheetLineResult: Hashable, Sendable {
  public let id: LineID
  public let syntax: LineSyntax
  /// The expression's result, or `nil` when the line has no expression.
  public let result: CalculationResult?
}

public struct CalculationEngine: Sendable {
  private let syntaxLimits: SyntaxLimits
  private let evaluationLimits: EvaluationLimits
  private let unitCatalog: UnitCatalog

  public init(
    syntaxLimits: SyntaxLimits = .default,
    evaluationLimits: EvaluationLimits = .default,
    unitCatalog: UnitCatalog? = nil
  ) {
    self.syntaxLimits = syntaxLimits
    self.evaluationLimits = evaluationLimits
    self.unitCatalog = unitCatalog ?? builtInMinimalUnitCatalog
  }

  /// Evaluates a sheet from top to bottom. Declarations are visible to later
  /// lines until a divider resets scope, and references read results above.
  /// Ranges in results are sheet coordinates.
  public func evaluate(
    _ sheet: SheetSource,
    context: EvaluationContext
  ) -> [SheetLineResult] {
    var variables: [String: EngineValue?] = [:]
    var outcomes = LineOutcomes()
    return sheet.lines.map { line in
      let syntax = LineSyntax(line)
      var result: CalculationResult?
      var expression: Expression?
      switch syntax {
      case .calculation(_, let nameRange, let expressionRange?, _):
        let name = nameRange.flatMap {
          variableName(in: text(of: $0, in: line), context: context)
        }
        if let nameRange, name == nil {
          result = .syntaxFailure([
            SyntaxDiagnostic(code: .invalidVariableName, range: nameRange)
          ])
          break
        }
        (result, expression) = evaluate(
          text(of: expressionRange, in: line),
          context: context,
          origin: SourceLocation(
            utf8Offset: expressionRange.lowerBound,
            graphemeOffset: expressionRange.graphemeLowerBound
          ),
          variables: variables,
          lines: outcomes
        )
        if let name {
          if case .value(let value) = result {
            variables[name] = value
          } else {
            variables[name] = .some(nil)
          }
        }
      case .divider:
        variables.removeAll()
      case .blank, .heading, .comment, .calculation:
        break
      }

      switch result {
      case nil:
        outcomes.append(.none)
      case .value(let value):
        outcomes.append(.value(value), expression: expression)
      case .syntaxFailure, .evaluationFailure:
        outcomes.append(.failure, expression: expression)
      }
      switch syntax {
      case .blank, .heading, .divider:
        outcomes.endBlock()
      case .comment, .calculation:
        break
      }
      return SheetLineResult(id: line.id, syntax: syntax, result: result)
    }
  }

  public func evaluate(
    _ source: String,
    context: EvaluationContext
  ) -> CalculationResult {
    evaluate(
      source,
      context: context,
      origin: .start,
      variables: [:],
      lines: LineOutcomes()
    ).result
  }

  private func evaluate(
    _ source: String,
    context: EvaluationContext,
    origin: SourceLocation,
    variables: [String: EngineValue?],
    lines: LineOutcomes
  ) -> (result: CalculationResult, expression: Expression?) {
    let parsing = Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog,
      origin: origin,
      variables: variables.mapValues { $0?.kind ?? .number }
    ).parse()
    guard let expression = parsing.expression else {
      return (.syntaxFailure(parsing.diagnostics), nil)
    }

    do {
      let value = try Evaluator(
        context: context,
        limits: evaluationLimits,
        variables: variables,
        lines: lines
      ).evaluate(expression)
      return (.value(value), expression)
    } catch let error as EngineError {
      return (.evaluationFailure(error), expression)
    } catch {
      return (
        .evaluationFailure(
          EngineError(code: .internalFailure, ranges: [expression.range])
        ),
        expression
      )
    }
  }

  /// Returns a declaration's normalized name, or `nil` when it is not a
  /// sequence of words that are not keywords, constants, functions, or units.
  /// A single-word name also cannot be a reference keyword.
  private func variableName(
    in source: String,
    context: EvaluationContext
  ) -> String? {
    let lexing = Lexer(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits
    ).lex()
    var words: [String] = []
    for token in lexing.tokens.dropLast() {
      guard case .identifier(let word) = token.kind,
        !reservedIdentifiers.contains(word),
        BuiltInFunction(rawValue: word) == nil,
        unitCatalog.resolveUnit(matching: word) == nil
      else {
        return nil
      }
      words.append(word)
    }
    guard lexing.diagnostics.isEmpty, !words.isEmpty,
      words.count > 1 || (referenceKeywords[words[0]] == nil && words[0] != "line")
    else {
      return nil
    }
    return words.joined(separator: " ")
  }

  public func parse(
    _ source: String,
    context: EvaluationContext
  ) -> ParsingResult {
    Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog
    ).parse()
  }
}

private func text(of range: SourceRange, in line: SheetLine) -> String {
  let utf8 = line.text.utf8
  let lower = utf8.index(
    utf8.startIndex,
    offsetBy: range.lowerBound - line.range.lowerBound
  )
  return String(line.text[lower..<utf8.index(lower, offsetBy: range.utf8Length)])
}
