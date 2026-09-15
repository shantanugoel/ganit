public struct SheetLineResult: Hashable, Sendable {
  public let id: LineID
  private let source: LineSource
  private let evaluation: LineEvaluation?

  fileprivate init(id: LineID, source: LineSource, evaluation: LineEvaluation?) {
    self.id = id
    self.source = source
    self.evaluation = evaluation
  }

  public var syntax: LineSyntax {
    source.syntax
  }

  /// The expression's result, or `nil` when the line has no expression.
  /// Ranges are relative to the start of the line's text.
  public var result: CalculationResult? {
    evaluation?.result
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.syntax == rhs.syntax && lhs.result == rhs.result
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct SheetEvaluation: Hashable, Sendable {
  public let generation: UInt64
  public let lines: [SheetLineResult]
  /// Lines whose expressions were evaluated in this generation, in sheet
  /// order. Every other line reused its previous result.
  public let evaluatedLineIDs: [LineID]
  /// Lines that were also lexed and parsed, a subset of `evaluatedLineIDs`.
  public let parsedLineIDs: [LineID]
}

/// Evaluates sheets incrementally.
///
/// Lines are evaluated from top to bottom. Declarations are visible to later
/// lines until a divider resets scope, and references read results above.
/// A line's previous result is reused when its text, the visible variables
/// its words could name, and the outcomes its references read are unchanged,
/// so an edit re-evaluates only the lines it affects. A line whose text and
/// variable kinds are unchanged reuses its parsed expression.
public struct SheetCalculator: Sendable {
  public private(set) var generation: UInt64 = 0
  private let engine: CalculationEngine
  private var context: EvaluationContext?
  private var cache: [LineID: (source: LineSource, evaluation: LineEvaluation?)] = [:]

  public init(engine: CalculationEngine = CalculationEngine()) {
    self.engine = engine
  }

  /// Starts a new generation. Throws `CancellationError`, without returning
  /// a partial evaluation, when the current task is cancelled; results
  /// computed before cancellation remain cached.
  public mutating func evaluate(
    _ sheet: SheetSource,
    context: EvaluationContext
  ) throws -> SheetEvaluation {
    generation += 1
    if context != self.context {
      cache.removeAll()
      self.context = context
    }

    var scope = VariableScope()
    var outcomes = LineOutcomes()
    var results: [SheetLineResult] = []
    var evaluated: [LineID] = []
    var parsed: [LineID] = []
    results.reserveCapacity(sheet.lines.count)

    for line in sheet.lines {
      try Task.checkCancellation()
      let cached = cache[line.id]
      let source =
        cached?.source.text == line.text
        ? cached!.source : LineSource(line.text, engine, context)
      var evaluation = cached?.source === source ? cached?.evaluation : nil

      if case .calculation(_, _, let expressionRange?, _) = source.syntax {
        let names = scope.values(named: source.words)
        if evaluation?.isValid(names: names, outcomes: outcomes) != true {
          let reusable = evaluation?.parsing(for: names)
          evaluation = LineEvaluation(
            source: source,
            expressionRange: expressionRange,
            names: names,
            parsing: reusable,
            outcomes: outcomes,
            engine: engine,
            context: context
          )
          evaluated.append(line.id)
          if reusable == nil {
            parsed.append(line.id)
          }
        }
      }
      if cached?.source !== source || cached?.evaluation !== evaluation {
        cache[line.id] = (source, evaluation)
      }

      let result = evaluation?.result
      if let name = source.declaredName, let result {
        scope.declare(name, result: result)
      }
      switch result {
      case nil:
        outcomes.append(.none)
      case .value(let value):
        outcomes.append(.value(value), references: evaluation?.references ?? [])
      case .syntaxFailure, .evaluationFailure:
        outcomes.append(.failure, references: evaluation?.references ?? [])
      }
      switch source.syntax {
      case .blank, .heading:
        outcomes.endBlock()
      case .divider:
        outcomes.endBlock()
        scope = VariableScope()
      case .comment, .calculation:
        break
      }
      results.append(SheetLineResult(id: line.id, source: source, evaluation: evaluation))
    }

    if cache.count > sheet.lines.count {
      let ids = Set(sheet.lines.map(\.id))
      cache = cache.filter { ids.contains($0.key) }
    }
    return SheetEvaluation(
      generation: generation,
      lines: results,
      evaluatedLineIDs: evaluated,
      parsedLineIDs: parsed
    )
  }
}

/// Everything derived from a line's text alone.
private final class LineSource: Sendable {
  let text: String
  let syntax: LineSyntax
  /// Runs of adjacent identifier words, which bound the names a parse can use.
  let words: [[String]]
  /// The normalized declared name, if the line declares a valid one.
  let declaredName: String?
  /// A diagnostic for an invalid declared name.
  let nameFailure: CalculationResult?

  init(_ text: String, _ engine: CalculationEngine, _ context: EvaluationContext) {
    self.text = text
    syntax = LineSyntax(text)
    var runs: [[String]] = [[]]
    for token in Lexer(source: text, configuration: context.lexingConfiguration).lex().tokens {
      if case .identifier(let word) = token.kind {
        runs[runs.count - 1].append(word)
      } else if !runs[runs.count - 1].isEmpty {
        runs.append([])
      }
    }
    words = runs.filter { !$0.isEmpty }

    guard case .calculation(_, let nameRange?, _, _) = syntax else {
      declaredName = nil
      nameFailure = nil
      return
    }
    declaredName = engine.variableName(in: slice(of: nameRange, in: text), context: context)
    nameFailure =
      declaredName == nil
      ? .syntaxFailure([SyntaxDiagnostic(code: .invalidVariableName, range: nameRange)])
      : nil
  }
}

/// A line's parse and evaluation, with the inputs each one read.
private final class LineEvaluation: Sendable {
  let names: [String: EngineValue?]
  let kinds: [String: EngineValueKind]
  let parsing: ParsingResult?
  let references: Set<LineReference>
  let inputs: [LineReference: [LineOutcomes.Outcome]?]
  let result: CalculationResult

  init(
    source: LineSource,
    expressionRange: SourceRange,
    names: [String: EngineValue?],
    parsing reusable: ParsingResult?,
    outcomes: LineOutcomes,
    engine: CalculationEngine,
    context: EvaluationContext
  ) {
    self.names = names
    kinds = names.mapValues { $0?.kind ?? .number }
    if let nameFailure = source.nameFailure {
      parsing = nil
      references = []
      inputs = [:]
      result = nameFailure
      return
    }
    let parsing =
      reusable
      ?? engine.parse(
        slice(of: expressionRange, in: source.text),
        context: context,
        origin: SourceLocation(
          utf8Offset: expressionRange.lowerBound,
          graphemeOffset: expressionRange.graphemeLowerBound
        ),
        variables: kinds
      )
    self.parsing = parsing
    guard let expression = parsing.expression else {
      references = []
      inputs = [:]
      result = .syntaxFailure(parsing.diagnostics)
      return
    }
    references = expression.references
    inputs = Dictionary(
      uniqueKeysWithValues: references.map { ($0, outcomes.inputs(for: $0)) }
    )
    result = engine.evaluate(expression, context: context, variables: names, lines: outcomes)
  }

  func isValid(names: [String: EngineValue?], outcomes: LineOutcomes) -> Bool {
    self.names == names
      && inputs.allSatisfy { outcomes.inputs(for: $0.key) == $0.value }
  }

  /// The parse, when it remains valid for variables with these values.
  func parsing(for names: [String: EngineValue?]) -> ParsingResult? {
    kinds == names.mapValues { $0?.kind ?? .number } ? parsing : nil
  }
}

/// Visible variables with an index of name prefixes for multi-word lookup.
private struct VariableScope: Sendable {
  private var variables: [String: EngineValue?] = [:]
  private var prefixes: Set<String> = []

  mutating func declare(_ name: String, result: CalculationResult) {
    if case .value(let value) = result {
      variables[name] = value
    } else {
      variables[name] = .some(nil)
    }
    var prefix = ""
    for word in name.split(separator: " ").dropLast() {
      prefix = prefix.isEmpty ? String(word) : prefix + " " + word
      prefixes.insert(prefix)
    }
  }

  /// The visible variables named by consecutive words in `runs`. A parse
  /// and evaluation can only read variables in this set.
  func values(named runs: [[String]]) -> [String: EngineValue?] {
    var found: [String: EngineValue?] = [:]
    for words in runs {
      for start in words.indices {
        var name = words[start]
        var end = start
        while true {
          if let value = variables[name] {
            found[name] = value
          }
          end += 1
          guard end < words.count, prefixes.contains(name) else {
            break
          }
          name += " " + words[end]
        }
      }
    }
    return found
  }
}

private func slice(of range: SourceRange, in text: String) -> String {
  let utf8 = text.utf8
  let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
  return String(text[lower..<utf8.index(lower, offsetBy: range.utf8Length)])
}
