import Foundation

struct TableFailureOrigin: Hashable, Sendable {
  let address: TableCellAddress
  /// UTF-8 and grapheme span in this origin cell's exact source/rule.
  let range: SourceRange
}

struct TableCalculationFailure: Hashable, Sendable {
  enum Code: String, Hashable, Sendable {
    case cycle, blocked, reference, syntax, evaluation, inputRequiresFormula
    case scalarRequired, unsupportedRangeOperation, invalidLiteral
    /// average/median/min/max over a range with no scalar members.
    case emptyRange
    /// A range aggregate this kind cannot form: min/max of rates, or an empty
    /// sum whose columns declare different typed defaults.
    case unsupportedAggregation
  }
  let code: Code
  /// The failing read or expression in the current cell's exact source.
  let sourceRange: SourceRange
  /// Original causes survive any number of blocked readers.
  let causes: TableCauseSet
  var cyclePath: [TableDependencyNode] = []
  var engineError: EngineError?
  var syntaxDiagnostics: [SyntaxDiagnostic] = []
  var referenceDiagnostic: TableFormulaDiagnostic?

  /// Flattened once per shared cause set, then returned without copying.
  var origin: [TableFailureOrigin] { causes.flattened().origins }
  var cycleParticipants: [TableCellAddress] { causes.flattened().participants }
  var originCount: Int { causes.flattened().origins.count }
  func origins(prefix count: Int) -> ArraySlice<TableFailureOrigin> {
    causes.flattened().origins.prefix(count)
  }
}

/// Canonical cause order within one sheet fold: table, row, then column
/// position. `fallback` orders only addresses in tables a calculation
/// cannot see.
struct TableCauseKey: Hashable, Comparable, Sendable {
  let table: Int
  let row: Int
  let column: Int
  let fallback: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.table, lhs.row, lhs.column, lhs.fallback) < (rhs.table, rhs.row, rhs.column, rhs.fallback)
  }
}

/// An immutable, interned union of original causes. A blocked reader links
/// its failed inputs' sets in O(inputs) instead of copying their causes, so
/// readers with distinct causes beside one large shared set stay linear.
///
/// Equality and hashing are structural: two sets are equal when they have
/// the same own causes and pairwise-equal parents in order, i.e. the same
/// cause provenance. Deterministic recalculations compare equal in time
/// linear in the cause graph. Flattened content is `origin` and
/// `cycleParticipants` on the failure, cached per set on first read.
final class TableCauseSet: Hashable, @unchecked Sendable {
  struct Flattened: Sendable {
    let origins: [TableFailureOrigin]
    let originKeys: [TableCauseKey]
    let participants: [TableCellAddress]
    let participantKeys: [TableCauseKey]
  }

  private let origins: [(key: TableCauseKey, origin: TableFailureOrigin)]
  private let participants: [(key: TableCauseKey, address: TableCellAddress)]
  /// Mutated only by `deinit`, on sets no one else references.
  private var parents: [TableCauseSet]
  /// Own causes and parents' structural hashes, fixed at construction.
  private let structuralHash: Int
  /// Snapshots cross threads; the mutable state below is guarded by `lock`.
  private let lock = NSLock()
  private var cache: Flattened?
  /// Readers linking this set; a set with several is flattened and cached
  /// before them, so its causes are never re-sorted per reader.
  private var children = 0
  /// A set already proven structurally equal; repeated comparisons of two
  /// recalculations reach shared ancestors once, not once per reader.
  private weak var equalPeer: TableCauseSet?

  fileprivate init(
    origins: [(key: TableCauseKey, origin: TableFailureOrigin)],
    participants: [(key: TableCauseKey, address: TableCellAddress)] = [],
    parents: [TableCauseSet] = []
  ) {
    self.origins = origins
    self.participants = participants
    self.parents = parents
    var hasher = Hasher()
    hasher.combine(origins.count)
    for entry in origins { hasher.combine(entry.origin) }
    hasher.combine(participants.count)
    for entry in participants { hasher.combine(entry.address) }
    hasher.combine(parents.count)
    for parent in parents {
      hasher.combine(parent.structuralHash)
      parent.lock.lock()
      parent.children += 1
      parent.lock.unlock()
    }
    structuralHash = hasher.finalize()
  }

  /// A 10,000-deep union chain must not release recursively.
  deinit {
    var pending = parents
    parents = []
    while var next = pending.popLast() {
      if isKnownUniquelyReferenced(&next) {
        pending.append(contentsOf: next.parents)
        next.parents = []
      }
    }
  }

  private var cached: Flattened? {
    lock.lock()
    defer { lock.unlock() }
    return cache
  }

  private var shared: Bool {
    lock.lock()
    defer { lock.unlock() }
    return children > 1
  }

  /// Shared uncached ancestors are flattened first, in iterative post-order,
  /// so every walk stops at cached sets and never re-sorts a shared one.
  func flattened() -> Flattened {
    if let cached { return cached }
    var order: [TableCauseSet] = []
    var visited: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
    var stack: [(set: TableCauseSet, next: Int)] = [(self, 0)]
    while let top = stack.last {
      if top.next < top.set.parents.count {
        stack[stack.count - 1].next += 1
        let parent = top.set.parents[top.next]
        if parent.cached == nil, visited.insert(ObjectIdentifier(parent)).inserted {
          stack.append((parent, 0))
        }
      } else {
        stack.removeLast()
        if top.set === self || top.set.shared { order.append(top.set) }
      }
    }
    for set in order where set.cached == nil { set.store(set.walk()) }
    return cached!
  }

  /// Collects causes up to the cached frontier; deduplicated and ordered.
  private func walk() -> Flattened {
    var visited = Set<ObjectIdentifier>()
    var pending = [self]
    var origins: [TableFailureOrigin: TableCauseKey] = [:]
    var participants: [TableCellAddress: TableCauseKey] = [:]
    while let set = pending.popLast() {
      guard visited.insert(ObjectIdentifier(set)).inserted else { continue }
      if set !== self, let known = set.cached {
        for (origin, key) in zip(known.origins, known.originKeys) { origins[origin] = key }
        for (address, key) in zip(known.participants, known.participantKeys) {
          participants[address] = key
        }
        continue
      }
      for (key, origin) in set.origins { origins[origin] = key }
      for (key, address) in set.participants { participants[address] = key }
      pending.append(contentsOf: set.parents)
    }
    let orderedOrigins = origins.sorted {
      ($0.value, $0.key.range.lowerBound, $0.key.range.upperBound)
        < ($1.value, $1.key.range.lowerBound, $1.key.range.upperBound)
    }
    let orderedParticipants = participants.sorted { $0.value < $1.value }
    return Flattened(
      origins: orderedOrigins.map(\.key), originKeys: orderedOrigins.map(\.value),
      participants: orderedParticipants.map(\.key),
      participantKeys: orderedParticipants.map(\.value))
  }

  private func store(_ flattened: Flattened) {
    lock.lock()
    defer { lock.unlock() }
    if cache == nil { cache = flattened }
  }

  private func isKnownEqual(to other: TableCauseSet) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return equalPeer === other
  }

  private func rememberEqual(_ other: TableCauseSet) {
    lock.lock()
    defer { lock.unlock() }
    equalPeer = other
  }

  /// Iterative pairwise comparison of own causes and ordered parents.
  static func == (lhs: TableCauseSet, rhs: TableCauseSet) -> Bool {
    var proven: [(TableCauseSet, TableCauseSet)] = []
    var visited = Set<[ObjectIdentifier]>()
    var pending = [(lhs, rhs)]
    while let (left, right) = pending.popLast() {
      if left === right || left.isKnownEqual(to: right) { continue }
      guard visited.insert([ObjectIdentifier(left), ObjectIdentifier(right)]).inserted else {
        continue
      }
      guard left.structuralHash == right.structuralHash,
        left.origins.count == right.origins.count,
        left.participants.count == right.participants.count,
        left.parents.count == right.parents.count,
        zip(left.origins, right.origins).allSatisfy({ $0.origin == $1.origin }),
        zip(left.participants, right.participants).allSatisfy({ $0.address == $1.address })
      else { return false }
      proven.append((left, right))
      pending.append(contentsOf: zip(left.parents, right.parents))
    }
    for (left, right) in proven {
      left.rememberEqual(right)
      right.rememberEqual(left)
    }
    return true
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(structuralHash)
  }
}

enum TableCellResult: Hashable, Sendable {
  case scalar(EngineValue)
  case text(String)
  case blank
  case failure(TableCalculationFailure)
}

struct TableCalculationSnapshot: Sendable {
  let table: TableModel
  let outcomes: [TableCellAddress: TableCellResult]
  let sources: [TableCellAddress: String]
  let nodes: [TableDependencyNode]
  let dependencies: [[Int]]
  let reverseDependencies: [[Int]]
  let traces: [TableCellAddress: EvaluationTrace]
  let axes: TableAxes
  /// Member cells read by range reductions in this generation. Each shared
  /// range node is reduced at most once per aggregate function, however
  /// many readers it has.
  var rangeCellVisits = 0

  /// A bounded cell without a record is an implicit blank. Sparse grids do
  /// not need a rows×columns dictionary merely to expose these blanks.
  func result(at address: TableCellAddress) -> TableCellResult? {
    guard address.table == table.id, axes.columns[address.column] != nil,
      address.row.map({ axes.rows[$0] != nil }) ?? true
    else { return nil }
    return outcomes[address] ?? .blank
  }
}

struct TableCalculationOptions: Sendable {
  let maximumPopulatedCells: Int
  /// Parses spent finding blocked formulas' own static errors; once spent,
  /// further such formulas deterministically report `blocked`.
  let maximumStaticCheckParses: Int

  init(maximumPopulatedCells: Int, maximumStaticCheckParses: Int? = nil) {
    self.maximumPopulatedCells = maximumPopulatedCells
    self.maximumStaticCheckParses = maximumStaticCheckParses ?? 4 * maximumPopulatedCells
  }

  static let production = Self(maximumPopulatedCells: TableSourceDocument.maximumPopulatedCells)
  /// Explicit internal engine-only stress fixture, never document admission.
  /// Source decode and storage retain their independent production byte gate.
  static let engineStress = Self(maximumPopulatedCells: 10_000)
}

struct TableCalculator: Sendable {
  let engine: CalculationEngine
  let options: TableCalculationOptions
  /// Task-4 hook for inherited custom functions: their lowercased names. A
  /// listed name is never lowercased into a built-in or range aggregate.
  var visibleCustomFunctionNames: Set<String> = []

  init(
    engine: CalculationEngine = CalculationEngine(), options: TableCalculationOptions = .production
  ) {
    self.engine = engine
    self.options = options
  }

  func calculate(
    _ table: TableModel, scope: TableFormulaScope, context: EvaluationContext,
    earlier: [TableID: TableCalculationSnapshot] = [:],
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> TableCalculationSnapshot {
    try checkCancellation(cancelled)
    guard table.populatedCellCount <= options.maximumPopulatedCells else {
      throw EngineError(code: .resourceLimitExceeded)
    }
    try table.validate()
    // A calculated earlier table is authoritative: binding, membership and
    // values all read the model its snapshot was calculated from.
    let visible = scope.visible.map { model -> TableModel in
      guard var calculated = earlier[model.id]?.table else { return model }
      calculated.name = model.name
      return calculated
    }
    var worker = TableCalculationWorker(
      table: table,
      scope: TableFormulaScope(current: table, visible: visible, inherited: scope.inherited),
      context: context, earlier: earlier, engine: engine,
      staticCheckParses: options.maximumStaticCheckParses,
      customFunctionNames: visibleCustomFunctionNames, cancelled: cancelled)
    return try worker.calculate()
  }
}

private enum TableNodePlan {
  case terminal(TableCellResult)
  /// `template` identifies the formula text shared by every row of a rule.
  case formula(TableFormulaSyntax, [TableBoundReference], template: Int)
  case range(TableRangeOperand)
}

/// Discovery and binding of one formula text, shared by every row of a rule.
private typealias TableFormulaTemplate = Result<
  (Int, TableFormulaSyntax, [TableBoundReference]), TableFormulaDiagnostic
>

/// A formula's own error, found without operand values.
private enum TableStaticFailure {
  case syntax([SyntaxDiagnostic])
  case reference(TableFormulaDiagnostic)
}

/// Static checks depend on the template and on the operand kinds that are
/// known; operands read from one failed input vary together.
private struct TableStaticCheck: Hashable {
  let template: Int
  let known: [String: EngineValueKind]
  let unknown: [[String]]
}

/// Enumerating kinds for more failed inputs than this falls back to blocked.
private let maximumUnknownOperands = 2

private let operandKinds: [EngineValueKind] = [
  .number, .percentage, .quantity, .rate, .date, .time, .instant, .period, .money,
]

private struct TableCalculationWorker {
  let table: TableModel
  let scope: TableFormulaScope
  let context: EvaluationContext
  let earlier: [TableID: TableCalculationSnapshot]
  let engine: CalculationEngine
  let cancelled: @Sendable () -> Bool
  private var staticCheckParses: Int
  private var models: [TableID: TableModel] = [:]
  private var axes: [TableID: TableAxes] = [:]
  private var nodes: [TableDependencyNode] = []
  private var index: [TableDependencyNode: Int] = [:]
  private var dependencies: [Set<Int>] = []
  private var plans: [TableNodePlan] = []
  private var sources: [TableCellAddress: String] = [:]
  private var results: [Int: TableCellResult] = [:]
  private var traces: [TableCellAddress: EvaluationTrace] = [:]
  private var tableRanks: [TableID: Int] = [:]
  private var templates = 0
  private var staticFailures: [TableStaticCheck: TableStaticFailure?] = [:]
  private let reducer: TableRangeReducer
  /// One reduction per shared range node and function, reused by every reader.
  private var rangeReductions:
    [TableRangeReductionKey: Result<EngineValue, TableRangeReductionFailure>] = [:]
  private var rangeMembers: [Int: [EngineValue]?] = [:]
  private var rangeCellVisits = 0
  /// Task-4 hook: lowercased names of visible custom functions. They keep
  /// their own dispatch and are never treated as built-ins or aggregates.
  private let customFunctionNames: Set<String>

  init(
    table: TableModel, scope: TableFormulaScope, context: EvaluationContext,
    earlier: [TableID: TableCalculationSnapshot], engine: CalculationEngine,
    staticCheckParses: Int, customFunctionNames: Set<String>,
    cancelled: @escaping @Sendable () -> Bool
  ) {
    self.staticCheckParses = staticCheckParses
    self.customFunctionNames = customFunctionNames
    self.table = table
    self.scope = scope
    self.context = context
    self.earlier = earlier
    self.engine = engine
    self.cancelled = cancelled
    reducer = engine.tableRangeReducer(context: context)
    for (rank, model) in (scope.visible + [table]).enumerated() {
      models[model.id] = model
      axes[model.id] = TableAxes(model)
      tableRanks[model.id] = rank
    }
  }

  mutating func calculate() throws -> TableCalculationSnapshot {
    try prepareCells()
    var cursor = 0
    while cursor < nodes.count {
      try checkCancellation(cancelled)
      if case .formula(_, let bindings, _) = plans[cursor], case .cell(let address) = nodes[cursor]
      {
        for binding in bindings where !binding.deleted {
          try checkCancellation(cancelled)
          if let target = binding.target {
            let dependency = try node(for: target, owner: address)
            dependencies[cursor].insert(dependency)
          }
        }
      } else if case .range(let range) = plans[cursor] {
        if let membership = membership(of: range.target) {
          for row in membership.rows {
            for column in membership.columns {
              try checkCancellation(cancelled)
              let address = TableCellAddress(table: membership.table, row: row, column: column)
              dependencies[cursor].insert(cellNode(address))
            }
          }
        }
      }
      cursor += 1
    }
    let graph = TableDependencyGraph(nodes: nodes, dependencies: dependencies)
    let components = try graph.components(cancelled: cancelled)
    for component in components.components where graph.isCycle(component) {
      try checkCancellation(cancelled)
      let cycleNodes = Set(component)
      var origins: [(key: TableCauseKey, origin: TableFailureOrigin)] = []
      var participants: [(key: TableCauseKey, address: TableCellAddress)] = []
      for node in component {
        guard case .cell(let address) = nodes[node] else { continue }
        let key = causeKey(address)
        participants.append((key, address))
        origins.append(
          (
            key,
            TableFailureOrigin(address: address, range: failingReadRange(node, failed: cycleNodes))
          )
        )
      }
      let causes = TableCauseSet(origins: origins, participants: participants)
      let path = try graph.cyclePath(in: component, cancelled: cancelled)
      for node in component {
        let range: SourceRange
        if case .cell(let address) = nodes[node] {
          range = failingReadRange(node, failed: cycleNodes)
        } else {
          range = emptyRange
        }
        results[node] = .failure(
          TableCalculationFailure(
            code: .cycle, sourceRange: range, causes: causes, cyclePath: path))
      }
    }
    for node in components.finishOrder {
      try checkCancellation(cancelled)
      if results[node] != nil { continue }
      let failures = graph.dependencies[node].compactMap { input -> TableCalculationFailure? in
        if case .failure(let failure) = results[input] { return failure }
        return nil
      }
      if !failures.isEmpty {
        if case .formula(let syntax, let bindings, let template) = plans[node],
          case .cell(let address) = nodes[node],
          let own = try staticFailure(
            syntax, bindings: bindings, template: template, address: address)
        {
          results[node] = .failure(failure(own, at: address))
          continue
        }
        let range = failingReadRange(
          node,
          failed: Set(
            graph.dependencies[node].filter {
              if case .failure = results[$0] { return true }
              return false
            }))
        var parents: [TableCauseSet] = []
        var linked = Set<ObjectIdentifier>()
        for failure in failures where linked.insert(ObjectIdentifier(failure.causes)).inserted {
          parents.append(failure.causes)
        }
        results[node] = .failure(
          TableCalculationFailure(
            code: .blocked, sourceRange: range,
            causes: parents.count == 1 ? parents[0] : TableCauseSet(origins: [], parents: parents),
            cyclePath: failures.first(where: { !$0.cyclePath.isEmpty })?.cyclePath ?? []))
        continue
      }
      switch plans[node] {
      case .terminal(let outcome): results[node] = outcome
      case .range: break  // Symbolic membership; readers reduce it on demand.
      case .formula(let syntax, let bindings, _):
        if case .cell(let address) = nodes[node] {
          results[node] = try evaluate(syntax, bindings: bindings, address: address)
        }
      }
    }
    var outcomes: [TableCellAddress: TableCellResult] = [:]
    for (node, result) in results {
      if case .cell(let address) = nodes[node], address.table == table.id {
        outcomes[address] = result
      }
    }
    return TableCalculationSnapshot(
      table: table, outcomes: outcomes, sources: sources,
      nodes: nodes, dependencies: graph.dependencies,
      reverseDependencies: graph.reverseDependencies,
      traces: traces, axes: axes[table.id]!, rangeCellVisits: rangeCellVisits)
  }

  private mutating func add(_ node: TableDependencyNode, plan: TableNodePlan) -> Int {
    if let known = index[node] { return known }
    let next = nodes.count
    index[node] = next
    nodes.append(node)
    plans.append(plan)
    dependencies.append([])
    return next
  }

  private mutating func prepareCells() throws {
    for column in table.columns {
      let address = TableCellAddress(table: table.id, row: nil, column: column.id)
      sources[address] = column.header
      _ = add(.cell(address), plan: .terminal(.text(column.header)))
    }
    let ledgers = Dictionary(
      table.ledger.map { ($0.owner, $0) }, uniquingKeysWith: { first, _ in first })
    let cellRecords = Dictionary(
      uniqueKeysWithValues: table.cells.map {
        (TableCellAddress(table: table.id, row: $0.row, column: $0.column), $0)
      })
    let tableAxes = axes[table.id]!
    let ordered = table.cells.sorted {
      let first = tableAxes.rows[$0.row]!
      let second = tableAxes.rows[$1.row]!
      return first == second
        ? tableAxes.columns[$0.column]! < tableAxes.columns[$1.column]! : first < second
    }
    for cell in ordered {
      try checkCancellation(cancelled)
      let address = TableCellAddress(table: table.id, row: cell.row, column: cell.column)
      let column = table.columns[tableAxes.columns[cell.column]!]
      sources[address] = cell.source
      let plan: TableNodePlan
      if cell.source.hasPrefix("=") {
        let owner = TableFormulaOwner.cell(row: cell.row, column: cell.column)
        let template = try self.template(cell.source, ledger: ledgers[owner])
        plan = try instantiate(template, at: address, rowOffset: 0)
      } else {
        plan = .terminal(try literal(cell.source, column: column, address: address))
      }
      _ = add(.cell(address), plan: plan)
    }
    for column in table.columns {
      guard let rule = column.rule else { continue }
      // One discovery and binding per rule; rows only translate the template.
      var template: TableFormulaTemplate?
      for (rowIndex, row) in table.rows.enumerated() {
        try checkCancellation(cancelled)
        let address = TableCellAddress(table: table.id, row: row, column: column.id)
        guard cellRecords[address] == nil else { continue }
        if template == nil {
          template = try self.template(rule, ledger: ledgers[.rule(column: column.id)])
        }
        sources[address] = rule
        _ = add(.cell(address), plan: try instantiate(template!, at: address, rowOffset: rowIndex))
      }
    }
  }

  private mutating func template(_ source: String, ledger: TableLedgerEntry?) throws
    -> TableFormulaTemplate
  {
    do {
      let syntax = try TableFormulaSyntax.discover(
        source, configuration: context.lexingConfiguration)
      let bindings = try syntax.bind(scope: scope, ledger: ledger)
      for binding in bindings {
        if let targetTable = binding.target?.table, targetTable != table.id,
          earlier[targetTable] == nil, !binding.deleted
        {
          throw TableFormulaDiagnostic(code: .missingTable, range: binding.occurrence.range)
        }
      }
      templates += 1
      return .success((templates, syntax, bindings))
    } catch let diagnostic as TableFormulaDiagnostic {
      return .failure(diagnostic)
    }
  }

  private func instantiate(
    _ template: TableFormulaTemplate,
    at address: TableCellAddress, rowOffset: Int
  ) throws -> TableNodePlan {
    do {
      let (id, syntax, bindings) = try template.get()
      let bound = try bindings.map { binding -> TableBoundReference in
        guard rowOffset != 0, let target = binding.target, !binding.deleted else {
          return binding
        }
        return TableBoundReference(
          occurrence: binding.occurrence,
          target: try translated(
            target, locks: binding.locks, rowOffset: rowOffset, range: binding.occurrence.range),
          locks: binding.locks, inheritedName: binding.inheritedName, deleted: binding.deleted)
      }
      return .formula(syntax, bound, template: id)
    } catch let diagnostic as TableFormulaDiagnostic {
      return .terminal(
        .failure(
          failure(.reference, at: address, range: diagnostic.range, reference: diagnostic)))
    }
  }

  private mutating func cellNode(_ address: TableCellAddress) -> Int {
    if let known = index[.cell(address)] { return known }
    let result: TableCellResult
    if address.table == table.id {
      result = .blank
    } else if let earlierResult = earlier[address.table]?.result(at: address) {
      result = earlierResult
    } else {
      result = .failure(failure(.reference, at: address, range: emptyRange))
    }
    return add(.cell(address), plan: .terminal(result))
  }

  private mutating func node(for target: TableReferenceTarget, owner: TableCellAddress) throws
    -> Int
  {
    switch target {
    case .cell(let table, let row, let column):
      return cellNode(TableCellAddress(table: table, row: row, column: column))
    case .currentRow(let column):
      return cellNode(TableCellAddress(table: table.id, row: owner.row, column: column))
    default:
      let range = TableRangeOperand(target: target)
      return add(.range(range), plan: .range(range))
    }
  }

  private func membership(of target: TableReferenceTarget) -> (
    table: TableID, rows: [RowID], columns: [ColumnID]
  )? {
    guard let tableID = target.table, let model = models[tableID], let axes = axes[tableID] else {
      return nil
    }
    // An unresolvable bound is a reference failure, never an empty range.
    func interval<ID>(_ membership: TableMembership<ID>, positions: [ID: Int], ids: [ID]) -> [ID]? {
      if case .interval(let first, let last) = membership,
        let start = positions[first], let end = positions[last], start <= end
      {
        return Array(ids[start...end])
      }
      return nil
    }
    let rows: [RowID]
    let columns: [ColumnID]
    let allColumns = model.columns.map(\.id)
    switch target {
    case .rectangle(_, let r, let c):
      guard let r = interval(r, positions: axes.rows, ids: model.rows),
        let c = interval(c, positions: axes.columns, ids: allColumns)
      else { return nil }
      rows = r
      columns = c
    case .columns(_, let c):
      guard let c = interval(c, positions: axes.columns, ids: allColumns) else { return nil }
      rows = model.rows
      columns = c
    case .rows(_, let r):
      guard let r = interval(r, positions: axes.rows, ids: model.rows) else { return nil }
      rows = r
      columns = allColumns
    case .namedColumn(_, let c):
      guard axes.columns[c] != nil else { return nil }
      rows = model.rows
      columns = [c]
    default: return nil
    }
    return (tableID, rows, columns)
  }

  private mutating func evaluate(
    _ syntax: TableFormulaSyntax, bindings: [TableBoundReference], address: TableCellAddress
  ) throws -> TableCellResult {
    var operands: [String: TableOperand] = [:]
    var kinds: [String: EngineValueKind] = [:]
    var variables = scope.inherited
    var ranges: [String: TableRangeSlot] = [:]
    for binding in bindings {
      try checkCancellation(cancelled)
      let value: TableOperand
      if binding.deleted {
        return .failure(
          failure(
            .reference, at: address, range: binding.occurrence.range,
            reference: TableFormulaDiagnostic(
              code: .brokenReference, range: binding.occurrence.range)))
      } else if let inherited = binding.inheritedName {
        guard let inheritedValue = scope.inherited[inherited] ?? nil else {
          // The name exists, but its sheet line failed.
          return .failure(
            failure(
              .reference, at: address, range: binding.occurrence.range,
              reference: TableFormulaDiagnostic(
                code: .inheritedFailure, range: binding.occurrence.range)))
        }
        value = .scalar(inheritedValue)
      } else if let target = binding.target {
        let input = try node(for: target, owner: address)
        if case .range(let range) = plans[input] {
          value = .range(range)
          ranges[binding.occurrence.slot] = TableRangeSlot(
            node: input, range: binding.occurrence.range)
        } else {
          switch results[input] {
          case .scalar(let scalar): value = .scalar(scalar)
          case .text(let text): value = .text(text)
          case .blank: value = .blank
          default:
            return .failure(failure(.reference, at: address, range: binding.occurrence.range))
          }
        }
      } else {
        continue
      }
      operands[binding.occurrence.slot] = value
      if case .scalar(let scalar) = value {
        kinds[binding.occurrence.slot] = scalar.kind
        variables[binding.occurrence.slot] = scalar
      }
    }
    // Supported aggregates of one range reduce before the kind-directed
    // parse, so `sum(B:B) of 200` parses as the reduced kind allows. Each
    // call's token span becomes one operand; source ranges stay original.
    let calls = syntax.aggregateCalls(
      rangeSlots: Set(ranges.keys), customFunctions: customFunctionNames)
    // A failed reduction is recorded, not returned: the formula's own syntax,
    // keyword and reference diagnostics outrank it, so its slot parses as a
    // number until those checks pass.
    var reductionFailure: TableCalculationFailure?
    var failedSlots: [String] = []
    for call in calls {
      guard let slot = ranges[call.operand] else { continue }
      switch try reduction(call.function, node: slot.node) {
      case .success(let value):
        variables[call.slot] = value
        kinds[call.slot] = value.kind
      case .failure(let reason):
        kinds[call.slot] = .number
        failedSlots.append(call.slot)
        reductionFailure =
          reductionFailure
          ?? rangeFailure(reason, call: call.range, operand: slot.range, at: address)
      }
      ranges[call.operand] = nil
    }
    let collapsed = calls.isEmpty ? syntax : syntax.collapsing(calls)
    let parsing: ParsingResult
    do {
      parsing = try engine.parse(
        collapsed, context: context, operandKinds: kinds, inheritedKinds: inheritedKinds)
    } catch let diagnostic as TableFormulaDiagnostic {
      return .failure(
        failure(.reference, at: address, range: diagnostic.range, reference: diagnostic))
    }
    if parsing.expression == nil, let reductionFailure,
      try parsesWithSomeKind(collapsed, slots: failedSlots, known: kinds)
    {
      // `max(B:B) of 200` is well formed for some kind the failed reduction
      // could have had; the reduction failure is then the cell's own error.
      return .failure(reductionFailure)
    }
    guard var expression = parsing.expression else {
      var failure = failure(
        .syntax, at: address, range: parsing.diagnostics.first?.range ?? sourceRange(address))
      failure.syntaxDiagnostics = parsing.diagnostics
      return .failure(failure)
    }
    var direct = expression
    while case .grouped(let nested, _) = direct { direct = nested }
    if case .identifier(let slot, _) = direct, let operand = operands[slot] {
      switch operand {
      case .scalar(let value): return .scalar(value)
      case .text(let text): return .text(text)
      case .blank: return .blank
      default: break
      }
    }
    // One walk finds what the ordinary evaluator cannot judge: a failed
    // inherited name, a range left outside a supported single-range
    // aggregate (scalar position, other functions, several arguments), and
    // built-in names that need case-insensitive dispatch.
    var stray: SourceRange?
    var rewrite = false
    var pending = [expression]
    while let next = pending.popLast() {
      switch next {
      case .identifier(let name, let range):
        if let slot = ranges[name], stray.map({ slot.range.lowerBound < $0.lowerBound }) ?? true {
          stray = slot.range
        } else if case .some(.none) = scope.inherited[name.lowercased()] {
          return .failure(
            failure(
              .reference, at: address, range: range,
              reference: TableFormulaDiagnostic(code: .inheritedFailure, range: range)))
        }
      case .call(let name, _, _, _):
        rewrite = rewrite || dispatchedName(name) != name
      default: break
      }
      pending.append(contentsOf: next.tableChildren)
    }
    if let reductionFailure { return .failure(reductionFailure) }
    if let stray {
      return .failure(failure(.unsupportedRangeOperation, at: address, range: stray))
    }
    if rewrite {
      expression = expression.rewritingTableNodes { node in
        guard case .call(let name, let nameRange, let arguments, let range) = node else {
          return node
        }
        return .call(
          name: dispatchedName(name), nameRange: nameRange, arguments: arguments, range: range)
      }
    }
    for binding in bindings {
      switch operands[binding.occurrence.slot] {
      case .blank, .text:
        return .failure(failure(.scalarRequired, at: address, range: binding.occurrence.range))
      default: break
      }
    }
    let evaluation = engine.evaluate(
      expression, context: context, variables: variables, lines: LineOutcomes())
    try checkCancellation(cancelled)
    traces[address] = evaluation.trace
    return result(evaluation.result, at: address)
  }

  /// Whether a formula parses for some kinds of the given failed slots, as
  /// `staticFailure` decides for failed inputs, from the same parse budget;
  /// too many slots or a spent budget count as no.
  private mutating func parsesWithSomeKind(
    _ syntax: TableFormulaSyntax, slots: [String], known: [String: EngineValueKind]
  ) throws -> Bool {
    guard slots.count <= maximumUnknownOperands else { return false }
    var combinations = 1
    for _ in slots { combinations *= operandKinds.count }
    for combination in 0..<combinations {
      try checkCancellation(cancelled)
      guard staticCheckParses > 0 else { return false }
      staticCheckParses -= 1
      var kinds = known
      var digits = combination
      for slot in slots {
        kinds[slot] = operandKinds[digits % operandKinds.count]
        digits /= operandKinds.count
      }
      if (try? engine.parse(
        syntax, context: context, operandKinds: kinds, inheritedKinds: inheritedKinds))?
        .expression != nil
      {
        return true
      }
    }
    return false
  }

  /// Kinds for inherited names; a failed line keeps its name visible, as in
  /// ordinary sheets, so it is never mistaken for a bare keyword.
  private var inheritedKinds: [String: EngineValueKind] {
    scope.inherited.mapValues { $0?.kind ?? .number }
  }

  /// Built-in names dispatch case-insensitively in table formulas, unless a
  /// visible custom function claims the lowercased name.
  private func dispatchedName(_ name: String) -> String {
    let lowered = name.lowercased()
    guard !customFunctionNames.contains(lowered), tableBuiltInFunctionNames.contains(lowered)
    else { return name }
    return lowered
  }

  /// A reduction failure reported at the reader's own call.
  private func rangeFailure(
    _ reason: TableRangeReductionFailure, call: SourceRange, operand: SourceRange,
    at address: TableCellAddress
  ) -> TableCalculationFailure {
    switch reason {
    case .empty: return failure(.emptyRange, at: address, range: call)
    case .unsupported: return failure(.unsupportedAggregation, at: address, range: call)
    case .reference:
      // Membership no longer resolves inside the table's bounds.
      return failure(
        .reference, at: address, range: operand,
        reference: TableFormulaDiagnostic(code: .outOfBounds, range: operand))
    case .engine(let error):
      var failed = failure(.evaluation, at: address, range: call)
      failed.engineError = EngineError(
        code: error.code, severity: error.severity,
        ranges: error.ranges.isEmpty ? [call] : error.ranges, fixIts: error.fixIts,
        context: error.context)
      return failed
    }
  }

  /// Reduces a shared range node once per function, from member values
  /// collected once per node. A failed member has already blocked the range
  /// node, so readers never reach here then.
  private mutating func reduction(_ function: TableRangeFunction, node: Int) throws
    -> Result<EngineValue, TableRangeReductionFailure>
  {
    let key = TableRangeReductionKey(node: node, function: function)
    if let cached = rangeReductions[key] { return cached }
    var outcome: Result<EngineValue, TableRangeReductionFailure> = .failure(.reference)
    if case .range(let range) = plans[node], let membership = membership(of: range.target),
      let values = try members(of: node, membership)
    {
      outcome = reducer.reduce(function, values) {
        typedZero(table: membership.table, columns: membership.columns)
      }
    }
    rangeReductions[key] = outcome
    return outcome
  }

  /// Scalar member values in row-major order; blank and text are skipped.
  /// `nil` when a member has no outcome. Visits count once per range node.
  private mutating func members(
    of node: Int, _ membership: (table: TableID, rows: [RowID], columns: [ColumnID])
  ) throws -> [EngineValue]? {
    if let known = rangeMembers[node] { return known }
    var values: [EngineValue]? = []
    for row in membership.rows {
      try checkCancellation(cancelled)
      for column in membership.columns {
        rangeCellVisits += 1
        let member = TableCellAddress(table: membership.table, row: row, column: column)
        switch index[.cell(member)].flatMap({ results[$0] }) {
        case .scalar(let value): values?.append(value)
        case .text, .blank: break
        case .failure, nil: values = nil
        }
      }
    }
    rangeMembers[node] = .some(values)
    return values
  }

  /// An empty `sum` is `0` unless its value columns declare a typed default:
  /// then the shared default's additive zero (`0 USD`, `0 m`), or none when
  /// the defaults disagree or the unit has no additive zero (a temperature).
  private func typedZero(table: TableID, columns: [ColumnID]) -> EngineValue? {
    guard let model = models[table], let axes = axes[table] else { return nil }
    // A unit default takes precedence over a currency, as for literals.
    struct Default: Hashable {
      let suffix: String
      let unit: Bool
    }
    var defaults = Set<Default?>()
    for column in columns {
      guard let position = axes.columns[column] else { return nil }
      let declared = model.columns[position]
      // Text columns never contribute a scalar, so they declare no zero.
      guard declared.input == .value else { continue }
      defaults.insert(
        declared.unit.map { Default(suffix: $0, unit: true) }
          ?? declared.currency.map { Default(suffix: $0, unit: false) })
    }
    guard defaults.count <= 1 else { return nil }
    guard let only = defaults.first else { return .number(.integer(IntegerValue(0))) }
    guard let declared = only else { return .number(.integer(IntegerValue(0))) }
    let (suffix, unit) = (declared.suffix, declared.unit)
    let source = "0 " + suffix
    guard let expression = engine.parse(source, context: context).expression else { return nil }
    switch (unit, expression) {
    case (true, .quantity), (true, .period), (false, .money): break
    default: return nil
    }
    let evaluation = engine.evaluate(
      expression, context: context, variables: [:], lines: LineOutcomes())
    switch evaluation.result {
    case .value(.quantity(let quantity)) where quantity.kind == .absolute: return nil
    case .value(let value): return value
    default: return nil
    }
  }

  private mutating func literal(_ source: String, column: TableColumn, address: TableCellAddress)
    throws -> TableCellResult
  {
    if source.isEmpty { return .blank }
    if column.input == .text { return .text(source) }
    let parsing = engine.parse(source, context: context)
    guard let expression = parsing.expression else {
      var invalid = failure(.invalidLiteral, at: address, range: fullRange(source))
      invalid.syntaxDiagnostics = parsing.diagnostics
      return .failure(invalid)
    }
    guard expression.isTableLiteral(in: source) else {
      // Only arithmetic over literals is fixed by prefixing `=`; plain words
      // are not formulas either.
      let code: TableCalculationFailure.Code =
        expression.isArithmetic ? .inputRequiresFormula : .invalidLiteral
      return .failure(failure(code, at: address, range: fullRange(source)))
    }
    let evaluated = engine.evaluate(
      expression, context: context, variables: [:], lines: LineOutcomes())
    traces[address] = evaluated.trace
    if case .value(.number) = evaluated.result, let defaultSuffix = column.unit ?? column.currency {
      let defaultSyntax = engine.parse("1 " + defaultSuffix, context: context)
      guard let defaultExpression = defaultSyntax.expression else {
        return .failure(failure(.invalidLiteral, at: address, range: fullRange(source)))
      }
      switch (column.unit != nil, defaultExpression) {
      case (true, .quantity), (true, .period), (false, .money): break
      default: return .failure(failure(.invalidLiteral, at: address, range: fullRange(source)))
      }
      let interpretedSource = source + " " + defaultSuffix
      let interpretation = engine.parse(interpretedSource, context: context)
      guard let interpreted = interpretation.expression,
        interpreted.isTableLiteral(in: interpretedSource)
      else {
        return .failure(failure(.invalidLiteral, at: address, range: fullRange(source)))
      }
      let evaluation = engine.evaluate(
        interpreted, context: context, variables: [:], lines: LineOutcomes())
      if case .value = evaluation.result {
        traces[address] = evaluation.trace
        return result(evaluation.result, at: address)
      }
      return .failure(failure(.invalidLiteral, at: address, range: fullRange(source)))
    }
    return result(evaluated.result, at: address)
  }

  private func result(_ result: CalculationResult, at address: TableCellAddress) -> TableCellResult
  {
    switch result {
    case .value(let value): return .scalar(value)
    case .syntaxFailure(let diagnostics):
      var error = failure(
        .syntax, at: address, range: diagnostics.first?.range ?? sourceRange(address))
      error.syntaxDiagnostics = diagnostics
      return .failure(error)
    case .evaluationFailure(let engineError):
      var error = failure(
        .evaluation, at: address, range: engineError.ranges.first ?? sourceRange(address))
      error.engineError = engineError
      return .failure(error)
    }
  }

  private func translated(
    _ target: TableReferenceTarget, locks: [Bool], rowOffset: Int, range: SourceRange
  ) throws -> TableReferenceTarget {
    guard let tableID = target.table, let model = models[tableID], let axes = axes[tableID] else {
      return target
    }
    func row(_ row: RowID?, locked: Bool) throws -> RowID? {
      if locked { return row }
      let coordinate = row.map { axes.rows[$0]! + 2 } ?? 1
      let moved = coordinate + rowOffset
      guard moved >= 1, moved <= model.rows.count + 1 else {
        throw TableFormulaDiagnostic(code: .outOfBounds, range: range)
      }
      return moved == 1 ? nil : model.rows[moved - 2]
    }
    func interval(_ axis: TableMembership<RowID>, startLocked: Bool, endLocked: Bool) throws
      -> TableMembership<RowID>
    {
      guard case .interval(let first, let last) = axis,
        let start = try row(first, locked: startLocked), let end = try row(last, locked: endLocked),
        axes.rows[start]! <= axes.rows[end]!
      else {
        throw TableFormulaDiagnostic(code: .outOfBounds, range: range)
      }
      return .interval(first: start, last: end)
    }
    switch target {
    case .cell(_, let original, let column):
      return .cell(table: tableID, row: try row(original, locked: locks[0]), column: column)
    case .rectangle(_, let rows, let columns):
      return .rectangle(
        table: tableID,
        rows: try interval(rows, startLocked: locks[0], endLocked: locks[2]), columns: columns)
    case .rows(_, let rows):
      return .rows(table: tableID, try interval(rows, startLocked: locks[0], endLocked: locks[1]))
    default: return target
    }
  }

  private func failingReadRange(_ node: Int, failed: Set<Int>) -> SourceRange {
    guard case .cell(let address) = nodes[node], case .formula(_, let bindings, _) = plans[node]
    else {
      return emptyRange
    }
    for binding in bindings {
      if let target = binding.target, let id = inputNode(for: target, owner: address),
        failed.contains(id)
      {
        return binding.occurrence.range
      }
    }
    return sourceRange(address)
  }

  /// The existing graph node a bound operand reads, without adding one.
  private func inputNode(for target: TableReferenceTarget, owner address: TableCellAddress)
    -> Int?
  {
    switch target {
    case .cell(let table, let row, let column):
      return index[.cell(TableCellAddress(table: table, row: row, column: column))]
    case .currentRow(let column):
      return index[.cell(TableCellAddress(table: table.id, row: address.row, column: column))]
    default: return index[.range(TableRangeOperand(target: target))]
    }
  }

  /// Static checks run only for a formula with a failed input, so its own
  /// error outranks `blocked`. Parsing is kind-directed: operands that
  /// evaluated keep their kinds, and a failure counts only when every kind
  /// combination for the failed inputs fails.
  private mutating func staticFailure(
    _ syntax: TableFormulaSyntax, bindings: [TableBoundReference], template: Int,
    address: TableCellAddress
  ) throws -> TableStaticFailure? {
    var known: [String: EngineValueKind] = [:]
    var unknown: [Int: [String]] = [:]
    var ranges: [String: Int] = [:]
    for binding in bindings {
      let slot = binding.occurrence.slot
      if binding.deleted {
        return .reference(
          TableFormulaDiagnostic(code: .brokenReference, range: binding.occurrence.range))
      } else if let name = binding.inheritedName {
        // A failed sheet line is this cell's own original cause, as in `evaluate`.
        guard let value = scope.inherited[name] ?? nil else {
          return .reference(
            TableFormulaDiagnostic(code: .inheritedFailure, range: binding.occurrence.range))
        }
        known[slot] = value.kind
      } else if let target = binding.target, let input = inputNode(for: target, owner: address) {
        if case .range = plans[input] {
          ranges[slot] = input
          continue
        }
        switch results[input] {
        case .scalar(let value): known[slot] = value.kind
        case .failure: unknown[input, default: []].append(slot)
        default: break
        }
      }
    }
    // Aggregate calls collapse exactly as in `evaluate`; a blocked range or
    // a failed reduction leaves the call's kind unknown.
    let calls = syntax.aggregateCalls(
      rangeSlots: Set(ranges.keys), customFunctions: customFunctionNames)
    for call in calls {
      guard let node = ranges[call.operand] else { continue }
      if case .failure = results[node] {
        unknown[node, default: []].append(call.slot)
      } else if case .success(let value) = try reduction(call.function, node: node) {
        known[call.slot] = value.kind
      } else {
        unknown[node, default: []].append(call.slot)
      }
    }
    let syntax = calls.isEmpty ? syntax : syntax.collapsing(calls)
    guard unknown.count <= maximumUnknownOperands else { return nil }
    let groups = unknown.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    let check = TableStaticCheck(template: template, known: known, unknown: groups)
    if let cached = staticFailures[check] { return cached }
    let inheritedKinds = self.inheritedKinds
    var found: TableStaticFailure?
    var combinations = 1
    for _ in groups { combinations *= operandKinds.count }
    for combination in 0..<combinations {
      try checkCancellation(cancelled)
      guard staticCheckParses > 0 else {
        found = nil
        break
      }
      staticCheckParses -= 1
      var kinds = known
      var digits = combination
      for group in groups {
        for slot in group { kinds[slot] = operandKinds[digits % operandKinds.count] }
        digits /= operandKinds.count
      }
      do {
        let parsing = try engine.parse(
          syntax, context: context, operandKinds: kinds, inheritedKinds: inheritedKinds)
        if parsing.expression != nil {
          found = nil
          break
        }
        found = found ?? .syntax(parsing.diagnostics)
      } catch let diagnostic as TableFormulaDiagnostic {
        found = found ?? .reference(diagnostic)
      }
    }
    staticFailures[check] = .some(found)
    return found
  }

  private func failure(_ own: TableStaticFailure, at address: TableCellAddress)
    -> TableCalculationFailure
  {
    switch own {
    case .syntax(let diagnostics):
      var error = failure(
        .syntax, at: address, range: diagnostics.first?.range ?? sourceRange(address))
      error.syntaxDiagnostics = diagnostics
      return error
    case .reference(let diagnostic):
      return failure(.reference, at: address, range: diagnostic.range, reference: diagnostic)
    }
  }

  private func causeKey(_ address: TableCellAddress) -> TableCauseKey {
    guard let rank = tableRanks[address.table], let axes = axes[address.table] else {
      return TableCauseKey(table: .max, row: 0, column: 0, fallback: addressKey(address))
    }
    return TableCauseKey(
      table: rank, row: address.row.flatMap { axes.rows[$0] } ?? -1,
      column: axes.columns[address.column] ?? -1, fallback: "")
  }

  private func sourceRange(_ address: TableCellAddress) -> SourceRange {
    fullRange(sources[address] ?? "")
  }
  private func failure(
    _ code: TableCalculationFailure.Code, at address: TableCellAddress, range: SourceRange,
    reference: TableFormulaDiagnostic? = nil
  ) -> TableCalculationFailure {
    TableCalculationFailure(
      code: code, sourceRange: range,
      causes: TableCauseSet(
        origins: [(causeKey(address), TableFailureOrigin(address: address, range: range))]),
      referenceDiagnostic: reference)
  }
}

private struct TableRangeSlot {
  let node: Int
  let range: SourceRange
}

private struct TableRangeReductionKey: Hashable {
  let node: Int
  let function: TableRangeFunction
}

private let emptyRange = SourceRange(
  lowerBound: 0, upperBound: 0, graphemeLowerBound: 0, graphemeUpperBound: 0)
private func fullRange(_ source: String) -> SourceRange {
  SourceRange(
    lowerBound: 0, upperBound: source.utf8.count, graphemeLowerBound: 0,
    graphemeUpperBound: source.count)
}

private func addressKey(_ address: TableCellAddress) -> String {
  address.table.string + "/" + (address.row?.string ?? "header") + "/" + address.column.string
}

extension Expression {
  /// Arithmetic over literals and functions, with no names or references.
  fileprivate var isArithmetic: Bool {
    var pending = [self]
    while let next = pending.popLast() {
      switch next {
      case .identifier, .reference, .assistantPrompt: return false
      default: pending.append(contentsOf: next.tableChildren)
      }
    }
    return true
  }

  fileprivate func isTableLiteral(in source: String) -> Bool {
    switch self {
    case .literal: return true
    case .temporal(let temporal, _):
      switch temporal {
      case .date, .time, .dateTime: return true
      default: return false
      }
    case .prefix(let op, let value, _, _):
      return (op == .plus || op == .minus) && value.isTableLiteral(in: source)
    case .money(let amount, _, _), .quantity(let amount, _, _), .period(let amount, _, _),
      .percentage(let amount, _, _):
      return amount.isTableLiteral(in: source)
    case .infix(let left, let op, let right, let operatorRange, _):
      guard left.isTableLiteral(in: source), right.isTableLiteral(in: source),
        let spelling = operatorRange.text(in: source)
      else { return false }
      if op == .add, spelling.first?.isNumber == true {
        if case .quantity = left, case .quantity = right { return true }
      }
      if op == .multiply, ScaleWord.digits[String(spelling).lowercased()] != nil { return true }
      if op == .divide, case .money = left, case .quantity(let magnitude, _, _) = right,
        magnitude.range.text(in: source)?.first?.isLetter == true
      {
        return true
      }
      return false
    case .grouped(let value, let range):
      return range.text(in: source)?.first != "(" && value.isTableLiteral(in: source)
    default: return false
    }
  }
}
