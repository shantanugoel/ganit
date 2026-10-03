import Foundation

/// The aggregates a table formula may apply to a range operand. A range is
/// valid only as the single argument of one of these; anywhere else it is an
/// explicit `unsupportedRangeOperation`.
///
/// Range `min`/`max` are typed (money, quantities across compatible units,
/// percentages, dates, times, instants, comparable periods). Explicit-list
/// `min(…)`/`max(…)`, in tables and sheets alike, keep the ordinary numeric
/// semantics of `BuiltInFunction`.
enum TableRangeFunction: Hashable, Sendable {
  case sum, average, median, minimum, maximum, count

  /// Built-in spellings, already lowercased: `total` and `avg` stay aliases.
  init?(name: String) {
    switch name {
    case "sum", "total": self = .sum
    case "average", "avg": self = .average
    case "median": self = .median
    case "min": self = .minimum
    case "max": self = .maximum
    case "count": self = .count
    default: return nil
    }
  }
}

/// Built-in function names are case-insensitive inside table formulas only:
/// `SUM`, `Sqrt` and `PMT` dispatch as `sum`, `sqrt` and `pmt`. Ordinary sheet
/// dispatch and custom-function naming are unchanged.
let tableBuiltInFunctionNames: Set<String> = Set(
  BuiltInFunction.allCases.map(\.rawValue) + FinanceFunction.allCases.map(\.rawValue)
    + ["sum", "total", "average", "avg", "median", "count"])

/// Why a range could not be reduced, independent of the reader; each reader
/// reports it at its own call.
enum TableRangeReductionFailure: Error, Hashable, Sendable {
  /// average/median/min/max of no scalar members, or a sum with no zero.
  case empty
  /// A kind with no meaningful aggregate here, e.g. min of rates or an empty
  /// sum over columns whose declared defaults disagree.
  case unsupported
  /// Membership could not be resolved; never treated as an empty range.
  case reference
  case engine(EngineError)
}

/// Reductions over the scalar members of one range, in row-major order.
/// Blank and text members are skipped by the caller; failed members never
/// reach here because the shared range node is already blocked.
struct TableRangeReducer {
  let context: EvaluationContext
  let limits: EvaluationLimits
  private let scalarBudget: TableScalarBudget?
  private let operations: NumericOperations
  private let unitAlgebra: UnitAlgebra

  init(context: EvaluationContext, limits: EvaluationLimits, scalarBudget: TableScalarBudget? = nil)
  {
    self.scalarBudget = scalarBudget
    self.context = context
    self.limits = limits
    operations = NumericOperations(context: context, limits: limits, scalarBudget: scalarBudget)
    unitAlgebra = UnitAlgebra(context: context, limits: limits, scalarBudget: scalarBudget)
  }

  /// `typedZero` is the empty `sum`: `0`, a declared typed zero, or `nil`
  /// when the range's declared column defaults admit no single zero.
  func reduce(
    _ function: TableRangeFunction, _ values: [EngineValue], typedZero: () -> EngineValue?
  ) -> Result<EngineValue, TableRangeReductionFailure> {
    do {
      try scalarBudget?.consume()
      switch function {
      case .count:
        return .success(.number(.integer(IntegerValue(values.count))))
      case .sum:
        guard !values.isEmpty else {
          return typedZero().map { .success($0) } ?? .failure(.unsupported)
        }
        return .success(try aggregate(.sum, values))
      case .average, .median:
        guard !values.isEmpty else { return .failure(.empty) }
        return .success(try aggregate(function == .average ? .average : .median, values))
      case .minimum, .maximum:
        guard !values.isEmpty else { return .failure(.empty) }
        return try extremum(values, minimum: function == .minimum)
      }
    } catch let error as EngineError {
      return .failure(.engine(error))
    } catch {
      return .failure(.engine(EngineError(code: .internalFailure)))
    }
  }

  /// The ordinary `total`/`average`/`median` arithmetic: one kind, exact
  /// values, dimension checks and no implicit currency conversion.
  private func aggregate(_ aggregate: Aggregate, _ values: [EngineValue]) throws -> EngineValue {
    try Evaluator(
      context: context, limits: limits, variables: [:], lines: LineOutcomes(),
      scalarBudget: scalarBudget
    ).aggregating(aggregate, of: values)
  }

  /// Typed min/max select a member unchanged (exactness and approximation
  /// provenance included); the first of equal members wins.
  private func extremum(_ values: [EngineValue], minimum: Bool) throws
    -> Result<EngineValue, TableRangeReductionFailure>
  {
    let first = values[0]
    if let other = values.first(where: { $0.kind != first.kind }) {
      throw EngineError(
        code: .typeMismatch, context: .typeMismatch(expected: first.kind, actual: other.kind))
    }
    if case .rate = first { return .failure(.unsupported) }
    var selected = first
    for candidate in values.dropFirst() {
      let order = try ordering(candidate, selected)
      if minimum ? order < 0 : order > 0 { selected = candidate }
    }
    return .success(selected)
  }

  /// The sign of `left - right` for two values of one kind.
  func ordering(_ left: EngineValue, _ right: EngineValue) throws -> Int {
    func sign<T: Comparable>(_ lhs: T, _ rhs: T) -> Int { lhs < rhs ? -1 : (lhs > rhs ? 1 : 0) }
    try scalarBudget?.consume()
    switch (left, right) {
    case (.number(let lhs), .number(let rhs)):
      return try operations.ordering(lhs, rhs)
    case (.percentage(let lhs), .percentage(let rhs)):
      return try operations.ordering(lhs.points, rhs.points)
    case (.quantity(let lhs), .quantity(let rhs)):
      // A temperature reading and a temperature difference do not order.
      guard lhs.kind == rhs.kind else {
        throw EngineError(code: .invalidAbsoluteQuantityOperation)
      }
      return try operations.ordering(
        unitAlgebra.converted(lhs, to: rhs.unit).magnitude, rhs.magnitude)
    case (.money(let lhs), .money(let rhs)):
      guard lhs.currency == rhs.currency else { throw EngineError(code: .mixedCurrencies) }
      guard lhs.unit == rhs.unit else {
        throw EngineError(
          code: .typeMismatch, context: .typeMismatch(expected: .money, actual: .money))
      }
      return try operations.ordering(lhs.amount, rhs.amount)
    case (.date(let lhs), .date(let rhs)):
      return [sign(lhs.year, rhs.year), sign(lhs.month, rhs.month), sign(lhs.day, rhs.day)]
        .first { $0 != 0 } ?? 0
    case (.time(let lhs), .time(let rhs)):
      return sign(lhs.secondsSinceMidnight, rhs.secondsSinceMidnight)
    case (.instant(let lhs), .instant(let rhs)):
      return sign(lhs.date, rhs.date)
    case (.period(let lhs), .period(let rhs)):
      // A month is 28 to 31 days, so a span of months bounds the difference
      // in days. Order only when every month length gives the same sign:
      // 1 month > 20 days, 2 months > 1 month 5 days, but 1 month ? 30 days.
      let months = lhs.months - rhs.months
      let days = lhs.days - rhs.days
      let shortest = days + (months > 0 ? 28 : 31) * months
      let longest = days + (months > 0 ? 31 : 28) * months
      if months == 0 { return sign(days, 0) }
      if shortest > 0 { return 1 }
      if longest < 0 { return -1 }
      throw EngineError(code: .invalidDomain)
    default:
      throw EngineError(
        code: .typeMismatch, context: .typeMismatch(expected: right.kind, actual: left.kind))
    }
  }
}

/// A supported aggregate whose only argument is one range operand, found in
/// tokens before the kind-directed parse.
struct TableAggregateCall: Hashable, Sendable {
  let function: TableRangeFunction
  /// The range operand's slot.
  let operand: String
  /// From the function name through its closing parenthesis.
  let range: SourceRange
  /// The collapsed call's own operand slot.
  var slot: String { "\u{1f}range\(range.lowerBound)" }
}

extension TableFormulaSyntax {
  /// `name ( … slot … )` with only parentheses around one range slot, where
  /// the lowercased name is a range aggregate. A visible custom function of
  /// that name claims every other spelling, so `SUM(B:B)` is never the
  /// built-in then; exact `sum`, as ordinary dispatch resolves it, still is.
  /// Anything else stays ordinary syntax and is diagnosed after parsing.
  func aggregateCalls(rangeSlots: Set<String>, customFunctions: Set<String>)
    -> [TableAggregateCall]
  {
    guard !rangeSlots.isEmpty else { return [] }
    var calls: [TableAggregateCall] = []
    var index = 0
    while index + 1 < tokens.count {
      defer { index += 1 }
      guard case .identifier(let name) = tokens[index].kind,
        tokens[index + 1].kind == .leftParenthesis
      else { continue }
      let lowered = name.lowercased()
      guard name == lowered || !customFunctions.contains(lowered),
        let function = TableRangeFunction(name: lowered)
      else { continue }
      var cursor = index + 1
      var depth = 0
      while cursor < tokens.count, tokens[cursor].kind == .leftParenthesis {
        depth += 1
        cursor += 1
      }
      guard cursor < tokens.count, case .identifier(let operand) = tokens[cursor].kind,
        rangeSlots.contains(operand)
      else { continue }
      var closed = 0
      while closed < depth, cursor + 1 < tokens.count,
        tokens[cursor + 1].kind == .rightParenthesis
      {
        closed += 1
        cursor += 1
      }
      guard closed == depth else { continue }
      calls.append(
        TableAggregateCall(
          function: function, operand: operand,
          range: tokens[index].range.union(tokens[cursor].range)))
      index = cursor
    }
    return calls
  }

  /// This formula with each call's tokens replaced by its operand slot.
  func collapsing(_ calls: [TableAggregateCall]) -> TableFormulaSyntax {
    var collapsed: [Token] = []
    var next = calls.makeIterator()
    var call = next.next()
    for token in tokens {
      guard let current = call, token.range.lowerBound >= current.range.lowerBound else {
        collapsed.append(token)
        continue
      }
      if token.range.upperBound < current.range.upperBound { continue }
      collapsed.append(Token(kind: .identifier(current.slot), range: current.range))
      call = next.next()
    }
    return TableFormulaSyntax(
      source: source, tableFormula: tableFormula, references: references, tokens: collapsed,
      diagnostics: diagnostics)
  }
}

extension Expression {
  /// This node with replaced direct children, in `tableChildren` order.
  func replacingTableChildren(_ children: [Expression]) -> Expression {
    switch self {
    case .literal, .temporal, .identifier, .reference: return self
    case .relative(_, let isPast, let range):
      return .relative(offset: children[0], isPast: isPast, range: range)
    case .money(_, let currency, let range):
      return .money(amount: children[0], currency: currency, range: range)
    case .currencyConversion(_, let currency, let range):
      return .currencyConversion(value: children[0], currency: currency, range: range)
    case .zoneConversion(_, let zone, let range):
      return .zoneConversion(value: children[0], zone: zone, range: range)
    case .prefix(let op, _, let operatorRange, let range):
      return .prefix(op, operand: children[0], operatorRange: operatorRange, range: range)
    case .percentage(_, let percentRange, let range):
      return .percentage(points: children[0], percentRange: percentRange, range: range)
    case .quantity(_, let unit, let range):
      return .quantity(magnitude: children[0], unit: unit, range: range)
    case .period(_, let unit, let range):
      return .period(count: children[0], unit: unit, range: range)
    case .conversion(_, let target, let keywordRange, let range):
      return .conversion(
        value: children[0], target: target, keywordRange: keywordRange, range: range)
    case .grouped(_, let range):
      return .grouped(children[0], range: range)
    case .infix(_, let op, _, let operatorRange, let range):
      return .infix(
        left: children[0], operator: op, right: children[1], operatorRange: operatorRange,
        range: range)
    case .percentageOperation(let op, _, _, let operatorRange, let range):
      return .percentageOperation(
        operator: op, left: children[0], right: children[1], operatorRange: operatorRange,
        range: range)
    case .call(let name, let nameRange, _, let range):
      return .call(name: name, nameRange: nameRange, arguments: children, range: range)
    case .assistantPrompt(let parts, let nameRange, let range):
      var next = children.makeIterator()
      let replaced = parts.map { part -> PromptPart in
        if case .placeholder = part { return .placeholder(next.next()!) }
        return part
      }
      return .assistantPrompt(parts: replaced, nameRange: nameRange, range: range)
    }
  }

  /// Iterative post-order rebuild: `transform` sees each node with its
  /// already-transformed children. Never recursive, so it adds no stack
  /// depth beyond the evaluator's own bounded walk.
  func rewritingTableNodes(_ transform: (Expression) throws -> Expression) rethrows -> Expression {
    var pending: [(node: Expression, expanded: Bool)] = [(self, false)]
    var built: [Expression] = []
    while let (node, expanded) = pending.popLast() {
      let children = node.tableChildren
      if expanded || children.isEmpty {
        let rebuilt =
          children.isEmpty
          ? node : node.replacingTableChildren(Array(built.suffix(children.count)))
        built.removeLast(children.count)
        built.append(try transform(rebuilt))
      } else {
        pending.append((node, true))
        for child in children.reversed() { pending.append((child, false)) }
      }
    }
    return built[0]
  }
}
