import Foundation

/// A table visible to a sheet line: the table above it since the last
/// divider, with this generation's calculation, or none when the table could
/// not be calculated (a reader then fails explicitly; values are never
/// substituted from an earlier generation).
struct TableProseTarget: Sendable {
  let model: TableModel
  let snapshot: TableCalculationSnapshot?
  /// Changes whenever the table's model or outcomes do, so a line that read
  /// the table is evaluated again.
  let revision: UInt64
  /// Why a reader cannot use a table without a snapshot: it could not be
  /// calculated, or this surface never calculates tables.
  var unavailable: TableReferenceProblem = .unavailableTable

  var key: TableReadKey { TableReadKey(table: model.id, revision: revision) }
}

/// What a sheet line's table operands depended on, in visible order.
struct TableReadKey: Hashable, Sendable {
  let table: TableID
  let revision: UInt64
}

/// A sheet line's expression with qualified table operands, evaluated.
struct TableProseEvaluation {
  let result: CalculationResult
  let references: Set<LineReference>
  let trace: EvaluationTrace
  /// The clock, rate and finance provenance of the table cells it read.
  let carried: TableCellProvenance
  /// For a failed cell or table it read, the original failing cells.
  var failures: [TableCellFailureOrigin] = []
}

/// Qualified table operands in ordinary sheet lines: `Items[Amount]`,
/// `sum(Items[Amount])`, `Items!B2`, `sum(Items!B2:B8)`, `Items!C:C`.
///
/// Discovery, binding, range membership, reductions and the kind-directed
/// parse are the table formula machinery; everything else is the ordinary
/// line's evaluation with its own variables, `@N` lines, rates and functions.
/// Bare `B2` keeps its variable meaning: only qualified forms are operands.
enum TableProseOperands {
  /// The expression's qualified operands, `nil` when it has none, so the
  /// line stays an ordinary calculation, or the discovery failure.
  static func discover(_ text: String, context: EvaluationContext)
    -> Result<TableFormulaSyntax, TableFormulaDiagnostic>?
  {
    do {
      let syntax = try TableFormulaSyntax.discover(
        text, tableFormula: false, configuration: context.lexingConfiguration)
      return syntax.references.isEmpty ? nil : .success(syntax)
    } catch let diagnostic as TableFormulaDiagnostic {
      return .failure(diagnostic)
    } catch {
      return .failure(TableFormulaDiagnostic(code: .malformedReference, range: wholeRange(text)))
    }
  }

  static func evaluate(
    _ discovered: Result<TableFormulaSyntax, TableFormulaDiagnostic>,
    origin: SourceLocation,
    visible: [TableProseTarget],
    names: [String: EngineValue?],
    rates: [CurrencyPair: NumericValue],
    functions: [String: CustomFunction],
    outcomes: LineOutcomes,
    engine: CalculationEngine,
    context: EvaluationContext
  ) -> TableProseEvaluation {
    func failed(
      _ problem: TableReferenceProblem, _ range: SourceRange,
      origins: [TableCellFailureOrigin] = []
    ) -> TableProseEvaluation {
      TableProseEvaluation(
        result: .evaluationFailure(
          EngineError(
            code: .tableReference, ranges: [range.shifted(by: origin)],
            context: .tableReference(problem))),
        references: [], trace: EvaluationTrace(), carried: TableCellProvenance(),
        failures: origins)
    }
    func causes(_ failure: TableCalculationFailure) -> [TableCellFailureOrigin] {
      failure.origins(prefix: TableCellFailureOrigin.carriedLimit).map(
        TableCellFailureOrigin.init)
    }
    let syntax: TableFormulaSyntax
    let bindings: [TableBoundReference]
    do {
      syntax = try discovered.get()
      bindings = try syntax.bind(
        scope: TableFormulaScope(current: nil, visible: visible.map(\.model), inherited: [:]))
    } catch let diagnostic as TableFormulaDiagnostic {
      return failed(problem(diagnostic.code), diagnostic.range)
    } catch {
      return failed(.malformed, wholeRange(sourceText(of: discovered)))
    }
    let targets = Dictionary(
      visible.map { ($0.model.id, $0) }, uniquingKeysWith: { first, _ in first })
    var variables = names
    var kinds = names.mapValues { $0?.kind ?? .number }
    var ranges: [String: (target: TableReferenceTarget, range: SourceRange)] = [:]
    var carried = TableCellProvenance()
    for binding in bindings {
      let range = binding.occurrence.range
      guard let target = binding.target, !binding.deleted, let table = target.table,
        let read = targets[table]
      else { return failed(.malformed, range) }
      guard let snapshot = read.snapshot else {
        return failed(
          read.unavailable, range,
          origins: [.init(table: table, row: nil, column: nil, formulaRange: nil)])
      }
      guard case .cell(_, let row, let column) = target else {
        ranges[binding.occurrence.slot] = (target, range)
        continue
      }
      let address = TableCellAddress(table: table, row: row, column: column)
      switch snapshot.result(at: address) {
      case .scalar(let value):
        variables[binding.occurrence.slot] = value
        kinds[binding.occurrence.slot] = value.kind
        if let provenance = snapshot.provenance[address] { carried.formUnion(provenance) }
      case .text, .blank: return failed(.notScalar, range)
      case .failure(let failure): return failed(.failedCell, range, origins: causes(failure))
      case nil: return failed(.outOfBounds, range)
      }
    }
    // Ordinary dispatch is case-sensitive, so only the lowercase spelling of
    // an aggregate reduces a range here, unlike in table formulas.
    let calls = syntax.aggregateCalls(
      rangeSlots: Set(ranges.keys), customFunctions: Set(functions.keys)
    ).filter { call in
      syntax.tokens.contains {
        guard $0.range.lowerBound == call.range.lowerBound, case .identifier(let name) = $0.kind
        else { return false }
        return name == name.lowercased()
      }
    }
    for call in calls {
      guard let (target, range) = ranges[call.operand], let table = target.table,
        let read = targets[table], let snapshot = read.snapshot
      else { continue }
      let axes = snapshot.axes
      guard let membership = tableMembership(of: target, in: snapshot.table, axes: axes) else {
        return failed(.outOfBounds, range)
      }
      var values: [EngineValue] = []
      for row in membership.rows {
        for column in membership.columns {
          let member = TableCellAddress(table: table, row: row, column: column)
          switch snapshot.result(at: member) {
          case .scalar(let value):
            values.append(value)
            if let provenance = snapshot.provenance[member] { carried.formUnion(provenance) }
          case .text, .blank: break
          case .failure(let failure): return failed(.failedCell, range, origins: causes(failure))
          case nil: return failed(.outOfBounds, range)
          }
        }
      }
      let reduced = engine.tableRangeReducer(context: context).reduce(call.function, values) {
        tableTypedZero(
          snapshot.table, axes: axes, columns: membership.columns, engine: engine,
          context: context, scalarBudget: nil)
      }
      switch reduced {
      case .success(let value):
        variables[call.slot] = value
        kinds[call.slot] = value.kind
      case .failure(.empty): return failed(.emptyRange, call.range)
      case .failure(.unsupported): return failed(.unsupportedAggregation, call.range)
      case .failure(.reference): return failed(.outOfBounds, range)
      case .failure(.engine(let error)):
        return TableProseEvaluation(
          result: .evaluationFailure(
            EngineError(
              code: error.code, severity: error.severity,
              ranges: [call.range.shifted(by: origin)], fixIts: error.fixIts,
              context: error.context)),
          references: [], trace: EvaluationTrace(), carried: carried)
      }
      ranges[call.operand] = nil
    }
    let collapsed = calls.isEmpty ? syntax : syntax.collapsing(calls)
    guard
      let parsing = try? engine.parse(
        collapsed, context: context, operandKinds: kinds, inheritedKinds: kinds,
        customFunctions: Set(functions.keys), origin: origin)
    else { return failed(.malformed, wholeRange(syntax.source)) }
    guard let expression = parsing.expression else {
      return TableProseEvaluation(
        result: .syntaxFailure(parsing.diagnostics), references: [], trace: EvaluationTrace(),
        carried: carried)
    }
    // A range anywhere but as the one argument of an aggregate has no value.
    if let stray = ranges.values.map(\.range).min(by: { $0.lowerBound < $1.lowerBound }) {
      return failed(.notScalar, stray)
    }
    let (result, trace) = engine.evaluate(
      expression, context: context, variables: variables, lines: outcomes, manualRates: rates,
      functions: functions)
    return TableProseEvaluation(
      result: result, references: expression.references, trace: trace, carried: carried)
  }

  private static func sourceText(of discovered: Result<TableFormulaSyntax, TableFormulaDiagnostic>)
    -> String
  {
    (try? discovered.get().source) ?? ""
  }

  private static func problem(_ code: TableFormulaDiagnostic.Code) -> TableReferenceProblem {
    switch code {
    case .missingTable, .invisibleTable, .staleTable: return .unknownTable
    case .missingColumn: return .unknownColumn
    case .outOfBounds: return .outOfBounds
    default: return .malformed
    }
  }

  private static func wholeRange(_ text: String) -> SourceRange {
    SourceRange(
      lowerBound: 0, upperBound: text.utf8.count, graphemeLowerBound: 0,
      graphemeUpperBound: text.count)
  }
}
