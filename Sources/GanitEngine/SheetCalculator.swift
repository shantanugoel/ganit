import Foundation

public struct SheetLineResult: Hashable, Sendable {
  public let id: LineID
  private let source: LineSource
  fileprivate let evaluation: LineEvaluation?
  /// The result, with diagnostic ranges relative to this line's text.
  public let result: CalculationResult?
  /// Original failing lines, including all branches of a blocked expression.
  public let failureOriginLineNumbers: [Int]
  /// Original failing table cells, for a failure that comes from a table:
  /// a failed cell or range member this line or a line it depends on read,
  /// or a table that could not be calculated. Empty otherwise.
  public let failureOriginTableCells: [TableCellFailureOrigin]

  fileprivate init(
    id: LineID, source: LineSource, evaluation: LineEvaluation?,
    result: CalculationResult?, failureOrigins: [Int],
    tableFailureOrigins: [TableCellFailureOrigin] = []
  ) {
    self.id = id
    self.source = source
    self.evaluation = evaluation
    self.result = result
    failureOriginLineNumbers = failureOrigins
    failureOriginTableCells = tableFailureOrigins
  }

  public var syntax: LineSyntax {
    source.syntax
  }

  /// The normalized variable this line declares, including a failed value.
  /// Unit, rate, and function definitions do not declare a variable.
  public var declaredVariableName: String? {
    source.declaredName
  }

  /// The kinds of exchange rate the result used, for provenance.
  public var rateUses: Set<CurrencyRateUse> {
    evaluation?.rateUses ?? []
  }
  /// The finance functions this line's answer used, whose assumptions it is
  /// shown with.
  public var financeUses: Set<FinanceFunction> {
    evaluation?.financeUses ?? []
  }
  /// The `ask_assistant` prompts the line needs answered, with their
  /// placeholders filled in.
  public var assistantPrompts: [AssistantPrompt] {
    evaluation?.assistantPrompts ?? []
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.syntax == rhs.syntax && lhs.result == rhs.result
      && lhs.failureOriginLineNumbers == rhs.failureOriginLineNumbers
      && lhs.failureOriginTableCells == rhs.failureOriginTableCells
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct SheetEvaluation: Hashable, Sendable {
  public let generation: UInt64
  public let lines: [SheetLineResult]
  /// What this sheet's own lines define: the variables it declares and the
  /// units it defines. The definitions sheet exports these to every sheet.
  public let definitions: SheetDefinitions
  /// Lines whose expressions were evaluated in this generation, in sheet
  /// order. Every other line reused its previous result.
  public let evaluatedLineIDs: [LineID]
  /// Lines that were also lexed and parsed, a subset of `evaluatedLineIDs`.
  public let parsedLineIDs: [LineID]
  /// The earliest moment a result that read the clock can change, or `nil`
  /// when no result depends on the time.
  public let nextRecalculation: Date?
  /// Block diagnostics remain separate from scalar physical-line answers.
  public let tableDiagnostics: [TableSourceDiagnostic]
  /// The table segmentation work this generation did.
  let tableWork: TableSourceDocument.Work
  /// Every table block of this generation's source, in order. A block with
  /// any diagnostic has no projection; a previous generation's table is
  /// never substituted for it.
  let tables: [TableBlockResult]
  /// Tables whose calculation ran in this generation, in sheet order. Every
  /// other table reused its previous snapshot unchanged.
  let calculatedTables: [TableID]

  /// The block of the table with this identity.
  func table(_ id: TableID) -> TableBlockResult? {
    tables.first { $0.projection?.id == id }
  }
}

/// One table block's outcome in a sheet evaluation.
struct TableBlockResult: Hashable, Sendable {
  /// Zero-based physical source lines, opener and closer included.
  let physicalLines: Range<Int>
  /// The block in sheet UTF-8 offsets, including the closer's terminator.
  let utf8Range: Range<Int>
  /// The validated table, or `nil` whenever `diagnostics` is not empty.
  let projection: TableModel?
  let diagnostics: [TableSourceDiagnostic]
  /// This generation's calculation of a valid table, with the clock, rates
  /// and inherited scope every line of the generation used. `nil` for a
  /// quarantined block and when `calculationFailure` is set.
  let calculation: TableCalculationSnapshot?
  /// Why a valid table has no calculation, such as `resourceLimitExceeded`.
  /// Lines that read it fail explicitly.
  let calculationFailure: EngineError?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.physicalLines == rhs.physicalLines && lhs.utf8Range == rhs.utf8Range
      && lhs.projection == rhs.projection
      && lhs.diagnostics == rhs.diagnostics && lhs.calculationFailure == rhs.calculationFailure
      && lhs.calculation?.table == rhs.calculation?.table
      && lhs.calculation?.outcomes == rhs.calculation?.outcomes
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(physicalLines)
    hasher.combine(projection)
  }
}

/// Where a sheet is evaluated, which decides whether its table blocks are
/// calculated. A table is a workspace feature: elsewhere every block is kept
/// byte for byte and quarantined as in a sheet, but never calculated, and its
/// opener says why, so lines reading it fail with that explanation.
public enum SheetSurface: Hashable, Sendable {
  /// A library sheet, and a sheet the command line answers.
  case workspace
  /// The definitions sheet, which declares names for every sheet. A table
  /// there would share its values globally, so none is calculated.
  case definitions
  /// Quick Ganit's buffer, whose way to a table is Keep as Sheet.
  case quickGanit

  /// Why tables are not calculated here, or `nil` in the workspace.
  var tableProblem: TableReferenceProblem? {
    switch self {
    case .workspace: return nil
    case .definitions: return .definitions
    case .quickGanit: return .quickGanit
    }
  }
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
///
/// Table blocks are visited in the same pass. A table captures the scope an
/// ordinary line at its opener would see, and earlier visible tables, and is
/// calculated as a whole; its source lines have no answers and separate the
/// aggregate blocks around them. Lines below read it only through qualified
/// operands. A table whose model, captured scope and earlier tables are
/// unchanged reuses its previous snapshot without calculating.
public struct SheetCalculator: Sendable {
  public private(set) var generation: UInt64 = 0
  private let engine: CalculationEngine
  private let definitions: SheetDefinitions
  private let surface: SheetSurface
  private var context: EvaluationContext?
  private var cache: [LineID: (source: LineSource, evaluation: LineEvaluation?)] = [:]
  private var tableBlocks: [TableSourceBlock] = []
  /// Retained across generations, since previous snapshots are reusable
  /// only by the calculator (or a copy) that made them.
  private let tableCalculator: TableCalculator
  private var tableEntries: [TableID: TableFoldEntry] = [:]

  /// A calculator for sheets evaluated with these definitions. Definitions
  /// are fixed for a calculator's life, so changing them means a new one.
  public init(
    engine: CalculationEngine = CalculationEngine(),
    definitions: SheetDefinitions = .none,
    surface: SheetSurface = .workspace
  ) {
    self.init(
      engine: engine, definitions: definitions, surface: surface, tableOptions: .production)
  }

  init(
    engine: CalculationEngine = CalculationEngine(), definitions: SheetDefinitions = .none,
    surface: SheetSurface = .workspace, tableOptions: TableCalculationOptions
  ) {
    self.engine = engine.resolving(definitions.units)
    self.definitions = definitions
    self.surface = surface
    tableCalculator = TableCalculator(engine: engine, options: tableOptions)
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
      tableEntries.removeAll()
    }
    self.context = context

    let inherited = VariableScope(definitions.variables, functions: definitions.functions)
    var scope = inherited
    // The units the lines below may measure with, which grow as lines define
    // them, and the engine that resolves them.
    var units = definitions.units
    var engine = engine
    var outcomes = LineOutcomes()
    var results: [SheetLineResult] = []
    var evaluated: [LineID] = []
    var parsed: [LineID] = []
    var declared = SheetDefinitions()
    results.reserveCapacity(sheet.lines.count)

    // Table-free sheets only scan line starts; a block reparses only when
    // its bytes change.
    let tableSource = TableSourceDocument(sheet, reusing: tableBlocks)
    tableBlocks = tableSource.blocks
    // Everything below is table work that a table-free sheet never does.
    var tables = TableFold(tableSource.blocks)
    var block = 0
    for (lineIndex, line) in sheet.lines.enumerated() {
      try Task.checkCancellation()
      while block < tableSource.blocks.count,
        tableSource.blocks[block].physicalLines.upperBound <= lineIndex
      {
        block += 1
      }
      if block < tableSource.blocks.count,
        tableSource.blocks[block].physicalLines.contains(lineIndex)
      {
        try quarantine(
          line, at: lineIndex, in: tableSource.blocks[block], block: block, tables: &tables,
          scope: scope, outcomes: &outcomes, units: units, engine: engine, context: context,
          results: &results)
        continue
      }
      let cached = cache[line.id]
      // Markdown classification considers table operands only beside tables.
      let tableOperands = tables.isActive && context.isMarkdownMode
      let source =
        cached?.source.text == line.text && cached?.source.units == units
          && cached?.source.isTableSource == false
          && cached?.source.tableOperands == tableOperands
        ? cached!.source
        : LineSource(line.text, units, engine, context, tableOperands: tableOperands)
      var evaluation = cached?.source === source ? cached?.evaluation : nil

      if case .calculation(_, _, let expressionRange?, _) = source.syntax {
        let names = scope.values(named: source.words)
        let rates = scope.rates(naming: source.words)
        let functions = scope.functions(named: source.words)
        // Only a line that may name a table operand reads the visible tables.
        let visibleTables = tables.isActive && source.mayReadTables ? tables.visible : nil
        if evaluation?.isValid(
          names: names, rates: rates, functions: functions, outcomes: outcomes, now: context.now,
          tables: visibleTables)
          != true
        {
          let reusable = evaluation?.parsing(for: names)
          evaluation =
            visibleTables.map {
              LineEvaluation.readingTables(
                $0, source: source, expressionRange: expressionRange, names: names, rates: rates,
                functions: functions, parsing: reusable, outcomes: outcomes, engine: engine,
                context: context)
            }
            ?? LineEvaluation(
              source: source,
              expressionRange: expressionRange,
              names: names,
              rates: rates,
              functions: functions,
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

      var result = evaluation?.result ?? nil
      if tables.isActive {
        result = tables.track(
          result, of: evaluation, declaring: source.declaredName, line: outcomes.nextLine,
          outcomes: outcomes)
      }
      var failureOrigins: [Int] = []
      if case .syntaxFailure = result {
        failureOrigins = [outcomes.nextLine]
      } else if case .evaluationFailure(let error) = result {
        if error.code == .unavailableReference || error.code == .brokenReference {
          var roots = outcomes.failures(for: evaluation?.references ?? [])
          if evaluation?.references.contains(where: {
            if case .broken = $0 { return true }
            return false
          }) == true {
            roots.insert(outcomes.nextLine)
          }
          for name in evaluation?.parsing?.expression?.identifiers ?? [] {
            roots.formUnion(scope.failureOrigins[name] ?? [])
          }
          if case .failedVariable(let name) = error.context {
            roots.formUnion(scope.failureOrigins[name.lowercased()] ?? [])
          }
          if roots.isEmpty {
            if case .failedLine(let line) = error.context { roots.insert(line) }
            if case .failedLines(let lines) = error.context { roots.formUnion(lines) }
          }
          failureOrigins = roots.sorted()
          if !failureOrigins.isEmpty, error.code == .unavailableReference {
            result = .evaluationFailure(
              EngineError(
                code: error.code, severity: error.severity, ranges: error.ranges,
                fixIts: error.fixIts, context: LineOutcomes.failureContext(failureOrigins)))
          }
        }
        if failureOrigins.isEmpty { failureOrigins = [outcomes.nextLine] }
      }
      let tableFailures =
        tables.isActive && !failureOrigins.isEmpty
        ? tables.failures(evaluation?.tableFailures, lines: failureOrigins, at: outcomes.nextLine)
        : []
      if let function = evaluation?.function {
        scope.functions[function.name] = function
        declared.functions[function.name] = function
      }
      if let name = source.declaredName, let result {
        scope.declare(name, result: result, failureOrigins: failureOrigins)
        if case .value(let value) = result {
          declared.variables[name] = value
        }
      }
      if let unit = evaluation?.unit {
        declared.units.append(unit)
        units.append(unit)
        engine = self.engine.resolving(units)
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
        outcomes.append(
          .failure(lines: failureOrigins), references: evaluation?.references ?? [])
      }
      switch source.syntax {
      case .blank, .heading:
        outcomes.endBlock()
      case .divider:
        outcomes.endBlock()
        scope = inherited
        tables.divide()
      case .comment, .calculation, .markdown:
        break
      }
      results.append(
        SheetLineResult(
          id: line.id, source: source, evaluation: evaluation,
          result: result, failureOrigins: failureOrigins, tableFailureOrigins: tableFailures))
    }

    if cache.count > sheet.lines.count {
      let ids = Set(sheet.lines.map(\.id))
      cache = cache.filter { ids.contains($0.key) }
    }
    return finish(
      results, declared: declared, evaluated: evaluated, parsed: parsed, tables: tables,
      source: tableSource)
  }

  /// The generation's evaluation, with each table block's calculation. Kept
  /// out of `evaluate`'s frame, which stays on the stack under every parse.
  @inline(never)
  private mutating func finish(
    _ results: [SheetLineResult], declared: SheetDefinitions, evaluated: [LineID],
    parsed: [LineID], tables: TableFold, source tableSource: TableSourceDocument
  ) -> SheetEvaluation {
    if tableEntries.count > tables.results.count {
      let ids = Set(tables.results.values.map(\.model.id))
      tableEntries = tableEntries.filter { ids.contains($0.key) }
    }
    let lineRecalculation = results.compactMap { $0.evaluation?.clockInterval?.end }.min()
    let tableRecalculation = tables.results.values.compactMap { $0.snapshot?.nextRecalculation }
      .min()
    return SheetEvaluation(
      generation: generation,
      lines: results,
      definitions: declared,
      evaluatedLineIDs: evaluated,
      parsedLineIDs: parsed,
      nextRecalculation: [lineRecalculation, tableRecalculation].compactMap { $0 }.min(),
      tableDiagnostics: tableSource.diagnostics,
      tableWork: tableSource.work,
      tables: tableSource.blocks.enumerated().map { index, block in
        let target = tables.results[index]
        return TableBlockResult(
          physicalLines: block.physicalLines, utf8Range: block.utf8Range, projection: block.table,
          diagnostics: block.diagnostics, calculation: target?.snapshot,
          calculationFailure: target.flatMap { tableEntries[$0.model.id]?.failure }
            ?? (block.table == nil ? nil : surface.tableProblem.map { Self.surfaceError($0) }))
      },
      calculatedTables: tables.calculated
    )
  }

  /// A table block's physical line. Every block line, valid or not, has no
  /// answer, declares nothing, asks no assistant and separates the aggregate
  /// blocks around it. At a valid block's opener the table is calculated
  /// with the scope an ordinary line there would see. Kept out of
  /// `evaluate`'s frame, which stays on the stack under every line's parse.
  @inline(never)
  private mutating func quarantine(
    _ line: SheetLine, at lineIndex: Int, in opened: TableSourceBlock, block: Int,
    tables: inout TableFold, scope: VariableScope, outcomes: inout LineOutcomes,
    units: [CustomUnit], engine: CalculationEngine, context: EvaluationContext,
    results: inout [SheetLineResult]
  ) throws {
    // Off the workspace, the opener of every block, valid or not, says why
    // it is not calculated; it still has no value and separates aggregates.
    var notice: CalculationResult?
    if lineIndex == opened.physicalLines.lowerBound {
      tables.lines.insert(integersIn: opened.physicalLines)
      if let problem = surface.tableProblem {
        notice = .evaluationFailure(Self.surfaceError(problem, line: line.text))
        if let model = opened.table {
          let target = TableProseTarget(
            model: model, snapshot: nil, revision: 0, unavailable: problem)
          tables.results[block] = target
          tables.visible.append(target)
        }
      } else if let model = opened.table {
        try open(
          model, at: block, in: &tables, scope: scope, outcomes: outcomes, units: units,
          context: context)
      }
    }
    let cached = cache[line.id]?.source
    let source =
      cached?.isTableSource == true && cached?.text.utf8.elementsEqual(line.text.utf8) == true
      ? cached! : LineSource(line.text, units, engine, context, isTableSource: true)
    cache[line.id] = (source, nil)
    outcomes.endBlock()
    outcomes.append(.none)
    outcomes.endBlock()
    results.append(
      SheetLineResult(
        id: line.id, source: source, evaluation: nil, result: notice, failureOrigins: []))
  }

  /// Why a table on this surface has no values, spanning the opener's text
  /// when it is a line's diagnostic.
  private static func surfaceError(_ problem: TableReferenceProblem, line: String = "")
    -> EngineError
  {
    EngineError(
      code: .tableReference,
      ranges: line.isEmpty
        ? []
        : [
          SourceRange(
            lowerBound: 0, upperBound: line.utf8.count, graphemeLowerBound: 0,
            graphemeUpperBound: line.count)
        ],
      context: .tableReference(problem))
  }

  private mutating func open(
    _ model: TableModel, at block: Int, in tables: inout TableFold, scope: VariableScope,
    outcomes: LineOutcomes, units: [CustomUnit], context: EvaluationContext
  ) throws {
    let captured = TableFormulaScope(
      current: nil, visible: tables.visible.map(\.model), inherited: scope.all,
      functions: scope.functions, lines: outcomes, rates: scope.rates,
      units: .resolving(units), tableLines: tables.lines,
      variableProvenance: tables.variableProvenance, lineProvenance: tables.lineProvenance,
      functionProvenance: tables.functionProvenance)
    let target = try calculateTable(
      model, scope: captured, visible: tables.visible, population: tables.population,
      context: context, calculated: &tables.calculated)
    tables.results[block] = target
    tables.visible.append(target)
  }

  /// This generation's calculation of `model`, or its previous snapshot when
  /// nothing it depends on changed: its model, the captured inherited scope
  /// (the fingerprint of everything above it), the earlier tables it can read,
  /// the sheet's population and, for clock or rate readers, the context.
  private mutating func calculateTable(
    _ model: TableModel, scope: TableFormulaScope, visible: [TableProseTarget], population: Int,
    context: EvaluationContext, calculated: inout [TableID]
  ) throws -> TableProseTarget {
    let earlierKeys = visible.map(\.key)
    let entry = tableEntries[model.id]
    if let entry, entry.model == model, entry.population == population,
      entry.earlier == earlierKeys, entry.scope.visible == scope.visible,
      entry.isCurrent(in: context), sameScalarScope(entry.scope, scope)
    {
      return TableProseTarget(model: model, snapshot: entry.snapshot, revision: entry.revision)
    }
    calculated.append(model.id)
    let earlier = Dictionary(
      visible.compactMap { target in target.snapshot.map { (target.model.id, $0) } },
      uniquingKeysWith: { first, _ in first })
    let outcome: Result<TableCalculationSnapshot, EngineError>
    do {
      outcome = .success(
        try tableCalculator.calculate(
          model, scope: scope, context: context, earlier: earlier, previous: entry?.snapshot,
          sheetPopulatedCells: population, cancelled: { Task.isCancelled }))
    } catch let error as CancellationError {
      throw error
    } catch let error as EngineError {
      outcome = .failure(error)
    } catch {
      outcome = .failure(EngineError(code: .internalFailure))
    }
    // Readers below are evaluated again only when what they can read changed.
    let revision = entry.map { $0.sameResults(as: outcome) } == true ? entry!.revision : generation
    tableEntries[model.id] = TableFoldEntry(
      model: model, outcome: outcome, scope: scope, earlier: earlierKeys, population: population,
      context: context, revision: revision)
    return TableProseTarget(model: model, snapshot: try? outcome.get(), revision: revision)
  }
}

/// A table's last calculation and what it was calculated from.
private struct TableFoldEntry: Sendable {
  let model: TableModel
  let outcome: Result<TableCalculationSnapshot, EngineError>
  /// The inherited scope captured at the opener, the fingerprint compared
  /// before reuse.
  let scope: TableFormulaScope
  let earlier: [TableReadKey]
  let population: Int
  let context: EvaluationContext
  let revision: UInt64

  var snapshot: TableCalculationSnapshot? { try? outcome.get() }
  var failure: EngineError? {
    if case .failure(let error) = outcome { return error }
    return nil
  }

  func isCurrent(in context: EvaluationContext) -> Bool {
    switch outcome {
    case .success(let snapshot): return snapshot.isCurrent(in: context)
    case .failure: return self.context.at(context.now) == context
    }
  }

  func sameResults(as other: Result<TableCalculationSnapshot, EngineError>) -> Bool {
    switch (outcome, other) {
    case (.success(let old), .success(let new)):
      return old.table == new.table && old.outcomes == new.outcomes
        && old.provenance == new.provenance
    case (.failure(let old), .failure(let new)): return old == new
    default: return false
    }
  }
}

/// The table state of one generation's fold. Inactive, and never consulted
/// per line, in a sheet without table blocks.
private struct TableFold {
  let isActive: Bool
  /// Every valid table's populated cells, including tables hidden by dividers.
  let population: Int
  /// Zero-based physical lines of the blocks at or above the current line.
  var lines = IndexSet()
  /// Valid tables above the current line since the last divider.
  var visible: [TableProseTarget] = []
  /// Each valid block's table, by block index.
  var results: [Int: TableProseTarget] = [:]
  var calculated: [TableID] = []
  /// Provenance of variables, one-based lines and custom functions above,
  /// for the tables that read them.
  var variableProvenance: [String: TableCellProvenance] = [:]
  var lineProvenance: [Int: TableCellProvenance] = [:]
  var functionProvenance: [String: TableCellProvenance] = [:]
  /// The original failing table cells of failed lines, by one-based line,
  /// carried to the lines blocked on them.
  var lineFailures: [Int: [TableCellFailureOrigin]] = [:]

  init(_ blocks: [TableSourceBlock]) {
    isActive = !blocks.isEmpty
    population = blocks.reduce(0) { $0 + ($1.table?.populatedCellCount ?? 0) }
  }

  /// A line's result beside tables. A failed line reference into a table's
  /// source line, which has no answer, says to read the table by name
  /// instead. What the answer depended on is recorded for tables below that
  /// read it: by line number, by the variable it declares and by function.
  @inline(never)
  fileprivate mutating func track(
    _ result: CalculationResult?, of evaluation: LineEvaluation?, declaring name: String?,
    line: Int, outcomes: LineOutcomes
  ) -> CalculationResult? {
    var result = result
    if case .evaluationFailure(let error) = result, error.code == .invalidReference,
      evaluation?.references.contains(where: {
        guard case .line(let number) = $0 else { return false }
        return number >= 1 && number < line && lines.contains(number - 1)
      }) == true
    {
      result = .evaluationFailure(
        EngineError(
          code: .tableReference, ranges: error.ranges, context: .tableReference(.tableLine)))
    }
    var provenance = evaluation?.provenance ?? TableCellProvenance()
    if let evaluation, evaluation.function == nil {
      // Carry the inputs before a redeclaration overwrites their provenance.
      // Table-operand parses are transient; their filtered names conservatively
      // describe the ordinary variables they can consume.
      let names = evaluation.parsing?.expression?.identifiers ?? Set(evaluation.names.keys)
      for name in names {
        if let inherited = variableProvenance[name] { provenance.formUnion(inherited) }
      }
      for reference in evaluation.references {
        for number in outcomes.lineNumbers(for: reference) ?? [] {
          if let inherited = lineProvenance[number] { provenance.formUnion(inherited) }
        }
      }
      for name in evaluation.functions.keys {
        if let inherited = functionProvenance[name] { provenance.formUnion(inherited) }
      }
    }
    lineProvenance[line] = provenance.isEmpty ? nil : provenance
    if let name, result != nil {
      variableProvenance[name.lowercased()] = provenance.isEmpty ? nil : provenance
    }
    if let function = evaluation?.function {
      let captured = TableFormulaScope.functionProvenance(
        of: function, variableProvenance: variableProvenance,
        functionProvenance: functionProvenance)
      functionProvenance[function.name] = captured.isEmpty ? nil : captured
    }
    return result
  }

  /// A failed line's original failing table cells: its own failed table
  /// operand's, and those of the failed lines it was blocked on (variables
  /// and references report the lines that declared them).
  @inline(never)
  fileprivate mutating func failures(
    _ own: [TableCellFailureOrigin]?, lines: [Int], at line: Int
  ) -> [TableCellFailureOrigin] {
    var found = own ?? []
    for number in lines where number != line {
      for origin in lineFailures[number] ?? [] where !found.contains(origin) {
        found.append(origin)
      }
    }
    if !found.isEmpty { lineFailures[line] = found }
    return found
  }

  /// A divider hides the tables and declarations above it.
  mutating func divide() {
    guard isActive else { return }
    visible.removeAll()
    variableProvenance.removeAll()
    functionProvenance.removeAll()
  }
}

/// Everything derived from a line's text alone.
private final class LineSource: Sendable {
  let text: String
  /// The custom units visible to this line, which decide what its words can
  /// name, so a line is derived again when they change.
  let units: [CustomUnit]
  let syntax: LineSyntax
  /// A physical line of a table block, which is never calculated as prose.
  let isTableSource: Bool
  /// Whether Markdown classification read qualified table operands as values.
  let tableOperands: Bool
  /// Whether the expression could name a qualified table operand, which
  /// needs `[` or `!`; only such lines are checked against visible tables.
  let mayReadTables: Bool
  /// Runs of adjacent identifier words, which bound the names a parse can use.
  let words: [[String]]
  /// The normalized declared name, if the line declares a valid one.
  let declaredName: String?
  /// The unit a definition such as `1 bag = 25 kg` names.
  let unitName: String?
  /// The currency of a manual rate declaration such as `1 USD = 83.25 INR`.
  let rateCurrency: String?
  /// The name and parameters of a function definition such as `area(w, h) = w * h`.
  let function: (name: String, parameters: [String])?
  /// A diagnostic for an invalid declared name.
  let nameFailure: CalculationResult?

  init(
    _ text: String,
    _ units: [CustomUnit],
    _ engine: CalculationEngine,
    _ context: EvaluationContext,
    isTableSource: Bool = false,
    tableOperands: Bool = false
  ) {
    self.text = text
    self.isTableSource = isTableSource
    self.tableOperands = tableOperands
    self.units = units
    if isTableSource {
      mayReadTables = false
      syntax = .comment(
        SourceRange(
          lowerBound: 0, upperBound: text.utf8.count, graphemeLowerBound: 0,
          graphemeUpperBound: text.count))
      words = []
      declaredName = nil
      unitName = nil
      rateCurrency = nil
      function = nil
      nameFailure = nil
      return
    }
    let parsed = LineSyntax(text)
    syntax =
      context.isMarkdownMode
      ? MarkdownLines.adjusted(
        parsed, text: text, engine: engine, context: context, tableOperands: tableOperands)
      : parsed
    var runs: [[String]] = [[]]
    for token in Lexer(source: text, configuration: context.lexingConfiguration).lex().tokens {
      if case .identifier(let word) = token.kind {
        runs[runs.count - 1].append(word)
      } else if case .currencySymbol(let symbol) = token.kind,
        let code = CurrencyCatalog.currency(for: symbol, dollarCurrency: context.dollarCurrency)
      {
        // A symbol names its currency's manual rates as its code does.
        runs.append([code])
        runs.append([])
      } else if !runs[runs.count - 1].isEmpty {
        runs.append([])
      }
    }
    words = runs.filter { !$0.isEmpty }
    if case .calculation(_, _, let expressionRange?, _) = syntax {
      mayReadTables = text.utf8.dropFirst(expressionRange.lowerBound)
        .prefix(expressionRange.utf8Length)
        .contains { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "!") }
    } else {
      mayReadTables = false
    }

    guard case .calculation(_, let nameRange?, let expressionRange, _) = syntax else {
      declaredName = nil
      unitName = nil
      rateCurrency = nil
      function = nil
      nameFailure = nil
      return
    }
    let name = slice(of: nameRange, in: text)
    function = engine.functionSignature(in: name, context: context)
    guard function == nil else {
      declaredName = nil
      unitName = nil
      rateCurrency = nil
      nameFailure = nil
      return
    }
    let nameWords = name.split(whereSeparator: \.isWhitespace)
    // `1 x = …` declares a rate when `x` is a currency and defines a unit
    // otherwise, so a name that a variable could take stays a variable.
    let oneOf = nameWords.count == 2 && nameWords[0] == "1" ? String(nameWords[1]) : nil
    rateCurrency = oneOf.flatMap {
      CurrencyCatalog.minorUnits[$0.uppercased()] != nil ? $0.uppercased() : nil
    }
    unitName =
      rateCurrency == nil
      ? oneOf.flatMap { engine.unitName(in: $0, context: context) } : nil
    let isNamed = rateCurrency != nil || unitName != nil
    declaredName = isNamed ? nil : engine.variableName(in: name, context: context)
    // Point at what is wrong, not the whole name, and say which it is.
    let problem = engine.nameProblem(in: name, context: context)
    func shifted(_ range: SourceRange) -> SourceRange {
      SourceRange(
        lowerBound: nameRange.lowerBound + range.lowerBound,
        upperBound: nameRange.lowerBound + range.upperBound,
        graphemeLowerBound: nameRange.graphemeLowerBound + range.graphemeLowerBound,
        graphemeUpperBound: nameRange.graphemeLowerBound + range.graphemeUpperBound
      )
    }
    var diagnostic: SyntaxDiagnostic
    // `1 km = 5 m` defines a unit, so its leading `1` is the shape rather than
    // a name that is not words; the word it names is what is taken.
    switch oneOf == nil ? problem : .takenWord(nameRange) {
    case .takenWord(let range):
      diagnostic = SyntaxDiagnostic(code: .invalidVariableName, range: shifted(range))
    case .notWords(let range):
      diagnostic = SyntaxDiagnostic(code: .nonWordName, range: shifted(range))
    case nil:
      diagnostic = SyntaxDiagnostic(code: .invalidVariableName, range: nameRange)
    }
    // `2 + 3 =` is a calculator's equals key, not a declaration: nothing
    // follows it, and what precedes it is an expression with a number or an
    // operator, where words alone, `Groceries (Costco)`, are a name.
    if declaredName == nil, !isNamed, expressionRange?.isEmpty == true,
      Self.isArithmetic(name, context.lexingConfiguration),
      case let parsedName = engine.parse(name, context: context),
      parsedName.expression != nil, parsedName.diagnostics.isEmpty,
      let equals = text.utf8.dropFirst(nameRange.upperBound).firstIndex(of: UInt8(ascii: "="))
    {
      let offset = text.utf8.distance(from: text.utf8.startIndex, to: equals)
      let graphemes = nameRange.graphemeUpperBound + (offset - nameRange.upperBound)
      diagnostic = SyntaxDiagnostic(
        code: .trailingEquals,
        range: SourceRange(
          lowerBound: offset, upperBound: offset + 1, graphemeLowerBound: graphemes,
          graphemeUpperBound: graphemes + 1))
    }
    nameFailure = declaredName == nil && !isNamed ? .syntaxFailure([diagnostic]) : nil
  }

  private static func isArithmetic(_ text: String, _ configuration: LexingConfiguration) -> Bool {
    Lexer(source: text, configuration: configuration).lex().tokens.contains {
      switch $0.kind {
      case .identifier, .leftParenthesis, .rightParenthesis, .endOfFile: return false
      default: return true
      }
    }
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
  let functions: [String: CustomFunction]
  /// `nil` for a function definition, which has no answer of its own.
  let result: CalculationResult?
  /// The unit a definition line defines, when its value can define one.
  let unit: CustomUnit?
  /// The function a definition line defines, when its body parses.
  let function: CustomFunction?
  /// For a result that read the clock, the moments it stays correct for.
  let clockInterval: DateInterval?
  /// The kinds of exchange rate the result used.
  let rateUses: Set<CurrencyRateUse>
  /// The finance functions the result used.
  let financeUses: Set<FinanceFunction>
  /// The `ask_assistant` prompts the result needed.
  let assistantPrompts: [AssistantPrompt]
  /// The clock, rate and finance provenance of the result, including what
  /// table cells it read carried, for tables below that read this line.
  let provenance: TableCellProvenance
  /// Which tables the line read, if it was checked for table operands.
  let tableReads: TableReads
  /// The original failing table cells of a failed table operand.
  let tableFailures: [TableCellFailureOrigin]

  enum TableReads: Equatable {
    /// Evaluated without visible tables, so never checked for operands.
    case unchecked
    /// No qualified table operand: its result does not depend on tables.
    case none
    /// The visible tables, as they were, that its operands bound against.
    case visible([TableReadKey])
  }

  /// `checkedTables` is whether the line was checked for table operands and
  /// had none, so its result does not depend on the visible tables.
  init(
    source: LineSource,
    expressionRange: SourceRange,
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    functions: [String: CustomFunction],
    parsing reusable: ParsingResult?,
    outcomes: LineOutcomes,
    engine: CalculationEngine,
    context: EvaluationContext,
    checkedTables: Bool = false
  ) {
    self.names = names
    self.rates = rates
    self.functions = functions
    kinds = names.mapValues { $0?.kind ?? .number }
    tableReads = checkedTables ? .none : .unchecked
    tableFailures = []
    if let nameFailure = source.nameFailure {
      function = nil
      parsing = nil
      references = []
      inputs = [:]
      result = nameFailure
      unit = nil
      clockInterval = nil
      rateUses = []
      financeUses = []
      assistantPrompts = []
      provenance = TableCellProvenance()
      return
    }
    if let signature = source.function {
      // A body reads its parameters as numbers until a call gives them values.
      let parameters = Dictionary(
        uniqueKeysWithValues: signature.parameters.map { ($0, EngineValueKind.number) })
      let parsing = engine.parse(
        slice(of: expressionRange, in: source.text),
        context: context,
        origin: SourceLocation(
          utf8Offset: expressionRange.lowerBound,
          graphemeOffset: expressionRange.graphemeLowerBound
        ),
        variables: kinds.merging(parameters) { $1 }
      )
      self.parsing = nil
      references = []
      inputs = [:]
      unit = nil
      clockInterval = nil
      rateUses = []
      financeUses = []
      assistantPrompts = []
      provenance = TableCellProvenance()
      guard let body = parsing.expression else {
        result = .syntaxFailure(parsing.diagnostics)
        function = nil
        return
      }
      result = nil
      function = CustomFunction(
        name: signature.name, parameters: signature.parameters, body: body,
        variables: names.filter { !signature.parameters.contains($0.key) },
        functions: functions)
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
    function = nil
    guard let expression = parsing.expression else {
      references = []
      inputs = [:]
      result = .syntaxFailure(parsing.diagnostics)
      unit = nil
      clockInterval = nil
      rateUses = []
      financeUses = []
      assistantPrompts = []
      provenance = TableCellProvenance()
      return
    }
    references = expression.references
    inputs = Dictionary(
      uniqueKeysWithValues: references.map { ($0, outcomes.inputs(for: $0)) }
    )
    let (evaluated, trace) = engine.evaluate(
      expression, context: context, variables: names, lines: outcomes, manualRates: rates,
      functions: functions)
    let defined = source.unitName.map {
      Self.definedUnit(evaluated, named: $0, context: context, range: expressionRange)
    }
    unit = defined?.unit
    result =
      defined?.result
      ?? source.rateCurrency.map {
        Self.checkedRate(evaluated, from: $0, range: expressionRange)
      } ?? evaluated
    rateUses = trace.rateUses
    financeUses = trace.financeUses
    assistantPrompts = trace.assistantPrompts
    clockInterval = trace.clock?.interval(in: context)
    provenance = TableCellProvenance(trace)
  }

  /// A line whose expression has qualified table operands. Its parse is never
  /// reused, since operand kinds come from table cells.
  private init(
    source: LineSource,
    expressionRange: SourceRange,
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    functions: [String: CustomFunction],
    outcomes: LineOutcomes,
    context: EvaluationContext,
    visible: [TableProseTarget],
    prose: TableProseEvaluation
  ) {
    self.names = names
    self.rates = rates
    self.functions = functions
    kinds = names.mapValues { $0?.kind ?? .number }
    tableReads = .visible(visible.map(\.key))
    tableFailures = prose.failures
    parsing = nil
    function = nil
    references = prose.references
    inputs = Dictionary(
      uniqueKeysWithValues: references.map { ($0, outcomes.inputs(for: $0)) }
    )
    let defined = source.unitName.map {
      Self.definedUnit(prose.result, named: $0, context: context, range: expressionRange)
    }
    unit = defined?.unit
    result =
      defined?.result
      ?? source.rateCurrency.map {
        Self.checkedRate(prose.result, from: $0, range: expressionRange)
      } ?? prose.result
    var provenance = prose.carried
    provenance.formUnion(TableCellProvenance(prose.trace))
    rateUses = provenance.rateUses
    financeUses = provenance.financeUses
    assistantPrompts = prose.trace.assistantPrompts
    clockInterval = prose.trace.clock?.interval(in: context)
    self.provenance = provenance
  }

  /// The evaluation of a calculation line that may read the visible tables.
  /// Kept out of the fold's frame, which stays on the stack under every
  /// line's parse and evaluation.
  @inline(never)
  static func readingTables(
    _ visible: [TableProseTarget],
    source: LineSource,
    expressionRange: SourceRange,
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    functions: [String: CustomFunction],
    parsing reusable: ParsingResult?,
    outcomes: LineOutcomes,
    engine: CalculationEngine,
    context: EvaluationContext
  ) -> LineEvaluation {
    // A definition's name or signature is never a table operand.
    guard source.nameFailure == nil, source.function == nil,
      let discovered = TableProseOperands.discover(
        slice(of: expressionRange, in: source.text), context: context)
    else {
      return LineEvaluation(
        source: source, expressionRange: expressionRange, names: names, rates: rates,
        functions: functions, parsing: reusable, outcomes: outcomes, engine: engine,
        context: context, checkedTables: true)
    }
    let prose = TableProseOperands.evaluate(
      discovered,
      origin: SourceLocation(
        utf8Offset: expressionRange.lowerBound,
        graphemeOffset: expressionRange.graphemeLowerBound),
      visible: visible, names: names, rates: rates, functions: functions, outcomes: outcomes,
      engine: engine, context: context)
    return LineEvaluation(
      source: source, expressionRange: expressionRange, names: names, rates: rates,
      functions: functions, outcomes: outcomes, context: context, visible: visible, prose: prose)
  }

  /// The unit a definition line defines. A value that cannot define a unit,
  /// such as a plain number or a temperature, fails the line rather than
  /// defining nothing silently.
  private static func definedUnit(
    _ result: CalculationResult,
    named name: String,
    context: EvaluationContext,
    range: SourceRange
  ) -> (result: CalculationResult, unit: CustomUnit?) {
    guard case .value(let value) = result else {
      return (result, nil)
    }
    guard let unit = CustomUnit(name: name, value: value, context: context) else {
      return (.evaluationFailure(EngineError(code: .invalidUnitDefinition, ranges: [range])), nil)
    }
    return (result, unit)
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
    functions: [String: CustomFunction],
    outcomes: LineOutcomes,
    now: Date,
    tables: [TableProseTarget]?
  ) -> Bool {
    self.names == names && self.rates == rates && self.functions == functions
      && clockInterval.map { $0.start <= now && now < $0.end } != false
      && inputs.allSatisfy { outcomes.inputs(for: $0.key) == $0.value }
      && isValid(tables: tables)
  }

  /// A line checked for table operands stays valid while the tables its
  /// operands could bind against are unchanged; one never checked is checked
  /// once tables are visible.
  private func isValid(tables: [TableProseTarget]?) -> Bool {
    switch tableReads {
    case .unchecked: return tables == nil
    case .none: return true
    case .visible(let read): return tables.map { read.elementsEqual($0.map(\.key)) } == true
    }
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
  private(set) var failureOrigins: [String: [Int]] = [:]
  /// Manual exchange rates declared above.
  var rates: [CurrencyPair: NumericValue] = [:]
  /// Functions defined above, by lowercased name.
  var functions: [String: CustomFunction]

  init(_ inherited: [String: EngineValue] = [:], functions: [String: CustomFunction] = [:]) {
    self.functions = functions
    for (name, value) in inherited {
      declare(name, result: .value(value))
    }
  }

  /// The functions a word in `runs` names.
  func functions(named runs: [[String]]) -> [String: CustomFunction] {
    guard !functions.isEmpty else {
      return [:]
    }
    let words = Set(runs.joined().map { $0.lowercased() })
    return functions.filter { words.contains($0.key) }
  }

  /// The manual rates for currencies named in `runs`. A conversion names its
  /// target currency, so it can only use these rates.
  func rates(naming runs: [[String]]) -> [CurrencyPair: NumericValue] {
    guard !rates.isEmpty else {
      return [:]
    }
    let words = Set(runs.joined())
    return rates.filter { words.contains($0.key.from) || words.contains($0.key.to) }
  }

  /// Names match whatever their letter case, so `Rent` and `rent` are one
  /// variable; the sheet still shows each as it is written.
  /// Every visible variable, by lowercased name; `nil` for a failed one.
  var all: [String: EngineValue?] { variables }

  mutating func declare(
    _ rawName: String, result: CalculationResult, failureOrigins: [Int] = []
  ) {
    let name = rawName.lowercased()
    self.failureOrigins[name] = failureOrigins.isEmpty ? nil : failureOrigins
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
        var name = words[start].lowercased()
        var end = start
        while true {
          if let value = variables[name] {
            found[name] = value
          }
          end += 1
          guard end < words.count, prefixes.contains(name) else {
            break
          }
          name += " " + words[end].lowercased()
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
