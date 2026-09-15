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
  /// lines until a divider resets scope. Ranges in results are sheet
  /// coordinates.
  public func evaluate(
    _ sheet: SheetSource,
    context: EvaluationContext
  ) -> [SheetLineResult] {
    var variables: [String: EngineValue?] = [:]
    return sheet.lines.map { line in
      let syntax = LineSyntax(line)
      switch syntax {
      case .divider:
        variables.removeAll()
      case .calculation(_, let nameRange, let expression?, _):
        var name: String?
        if let nameRange {
          name = variableName(in: text(of: nameRange, in: line), context: context)
          guard name != nil else {
            return SheetLineResult(
              id: line.id,
              syntax: syntax,
              result: .syntaxFailure([
                SyntaxDiagnostic(code: .invalidVariableName, range: nameRange)
              ])
            )
          }
        }
        let result = evaluate(
          text(of: expression, in: line),
          context: context,
          origin: SourceLocation(
            utf8Offset: expression.lowerBound,
            graphemeOffset: expression.graphemeLowerBound
          ),
          variables: variables
        )
        if let name {
          if case .value(let value) = result {
            variables[name] = value
          } else {
            variables[name] = .some(nil)
          }
        }
        return SheetLineResult(id: line.id, syntax: syntax, result: result)
      default:
        break
      }
      return SheetLineResult(id: line.id, syntax: syntax, result: nil)
    }
  }

  public func evaluate(
    _ source: String,
    context: EvaluationContext
  ) -> CalculationResult {
    evaluate(source, context: context, origin: .start, variables: [:])
  }

  private func evaluate(
    _ source: String,
    context: EvaluationContext,
    origin: SourceLocation,
    variables: [String: EngineValue?]
  ) -> CalculationResult {
    let parsing = Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog,
      origin: origin,
      variables: variables.mapValues { $0?.kind ?? .number }
    ).parse()
    guard let expression = parsing.expression else {
      return .syntaxFailure(parsing.diagnostics)
    }

    do {
      return .value(
        try Evaluator(
          context: context,
          limits: evaluationLimits,
          variables: variables
        ).evaluate(expression)
      )
    } catch let error as EngineError {
      return .evaluationFailure(error)
    } catch {
      return .evaluationFailure(
        EngineError(code: .internalFailure, ranges: [expression.range])
      )
    }
  }

  /// Returns a declaration's normalized name, or `nil` when it is not a
  /// sequence of words that are not keywords, constants, functions, or units.
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
    return lexing.diagnostics.isEmpty ? words.joined(separator: " ") : nil
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
