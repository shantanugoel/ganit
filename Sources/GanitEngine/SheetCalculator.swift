import Foundation

public struct SheetLineResult: Hashable, Sendable {
  public let id: LineID
  private let source: LineSource
  fileprivate let evaluation: LineEvaluation?

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
  /// The earliest moment a result that read the clock can change, or `nil`
  /// when no result depends on the time.
  public let nextRecalculation: Date?
}

/// Evaluates sheets incrementally.
///
/// Lines are evaluated from top to bottom. Declarations are visible to later
/// lines until a divider resets scope, and references read results above.
/// A line's previous result is reused when its text, the visible variables
/// its words could name, and the outcomes its references read are unchanged,
/// so an edit re-evaluates only the lines it affects. A line whose text and
/// variable kinds are unchanged reuses its parsed expression. A line that
/// read the clock is also reused until the next midnight or second it
/// depends on; a context that differs only in `now` keeps the cache.
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
    if context.at(self.context?.now ?? context.now) != self.context {
      cache.removeAll()
    }
    self.context = context

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
        let rates = scope.rates(naming: source.words)
        if evaluation?.isValid(names: names, rates: rates, outcomes: outcomes, now: context.now)
          != true
        {
          let reusable = evaluation?.parsing(for: names)
          evaluation = LineEvaluation(
            source: source,
            expressionRange: expressionRange,
            names: names,
            rates: rates,
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
      if let from = source.rateCurrency, case .value(.money(let money)) = result {
        scope.rates[CurrencyPair(from: from, to: money.currency)] = money.amount
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
      parsedLineIDs: parsed,
      nextRecalculation: results.compactMap { $0.evaluation?.clockInterval?.end }.min()
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
  /// The currency of a manual rate declaration such as `1 USD = 83.25 INR`.
  let rateCurrency: String?
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
      rateCurrency = nil
      nameFailure = nil
      return
    }
    let name = slice(of: nameRange, in: text)
    let nameWords = name.split(whereSeparator: \.isWhitespace)
    rateCurrency =
      nameWords.count == 2 && nameWords[0] == "1"
        && CurrencyCatalog.minorUnits[String(nameWords[1])] != nil
      ? String(nameWords[1]) : nil
    declaredName =
      rateCurrency == nil ? engine.variableName(in: name, context: context) : nil
    nameFailure =
      declaredName == nil && rateCurrency == nil
      ? .syntaxFailure([SyntaxDiagnostic(code: .invalidVariableName, range: nameRange)])
      : nil
  }
}

/// A line's parse and evaluation, with the inputs each one read.
private final class LineEvaluation: Sendable {
  let names: [String: EngineValue?]
  let rates: [CurrencyPair: NumericValue]
  let kinds: [String: EngineValueKind]
  let parsing: ParsingResult?
  let references: Set<LineReference>
  let inputs: [LineReference: [LineOutcomes.Outcome]?]
  let result: CalculationResult
  /// For a result that read the clock, the moments it stays correct for.
  let clockInterval: DateInterval?

  init(
    source: LineSource,
    expressionRange: SourceRange,
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    parsing reusable: ParsingResult?,
    outcomes: LineOutcomes,
    engine: CalculationEngine,
    context: EvaluationContext
  ) {
    self.names = names
    self.rates = rates
    kinds = names.mapValues { $0?.kind ?? .number }
    if let nameFailure = source.nameFailure {
      parsing = nil
      references = []
      inputs = [:]
      result = nameFailure
      clockInterval = nil
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
      clockInterval = nil
      return
    }
    references = expression.references
    inputs = Dictionary(
      uniqueKeysWithValues: references.map { ($0, outcomes.inputs(for: $0)) }
    )
    let (evaluated, clock) = engine.evaluate(
      expression, context: context, variables: names, lines: outcomes, manualRates: rates)
    result =
      source.rateCurrency.map {
        Self.checkedRate(evaluated, from: $0, range: expressionRange)
      } ?? evaluated
    clockInterval = clock.map { resolution in
      switch resolution {
      case .day:
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        return calendar.dateInterval(of: .day, for: context.now)!
      case .second:
        let start = context.now.timeIntervalSinceReferenceDate.rounded(.down)
        return DateInterval(start: Date(timeIntervalSinceReferenceDate: start), duration: 1)
      }
    }
  }

  /// A manual rate must be a positive amount of another currency.
  private static func checkedRate(_ result: CalculationResult, from: String, range: SourceRange)
    -> CalculationResult
  {
    guard case .value(let value) = result else {
      return result
    }
    guard case .money(let money) = value, money.currency != from, !money.amount.isZero,
      !money.amount.isNegative
    else {
      return .evaluationFailure(EngineError(code: .invalidCurrencyRate, ranges: [range]))
    }
    return result
  }

  func isValid(
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    outcomes: LineOutcomes,
    now: Date
  ) -> Bool {
    self.names == names && self.rates == rates
      && clockInterval.map { $0.start <= now && now < $0.end } != false
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
  /// Manual exchange rates declared above.
  var rates: [CurrencyPair: NumericValue] = [:]

  /// The manual rates for currencies named in `runs`. A conversion names its
  /// target currency, so it can only use these rates.
  func rates(naming runs: [[String]]) -> [CurrencyPair: NumericValue] {
    guard !rates.isEmpty else {
      return [:]
    }
    let words = Set(runs.joined())
    return rates.filter { words.contains($0.key.from) || words.contains($0.key.to) }
  }

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
