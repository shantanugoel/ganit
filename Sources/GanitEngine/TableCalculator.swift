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
      staticCheckParses: options.maximumStaticCheckParses, cancelled: cancelled)
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

  init(
    table: TableModel, scope: TableFormulaScope, context: EvaluationContext,
    earlier: [TableID: TableCalculationSnapshot], engine: CalculationEngine,
    staticCheckParses: Int, cancelled: @escaping @Sendable () -> Bool
  ) {
    self.staticCheckParses = staticCheckParses
    self.table = table
    self.scope = scope
    self.context = context
    self.earlier = earlier
    self.engine = engine
    self.cancelled = cancelled
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
      case .range: break  // Symbolic membership; reductions are M2 task 3.
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
      traces: traces, axes: axes[table.id]!)
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
    func interval<ID>(_ membership: TableMembership<ID>, positions: [ID: Int], ids: [ID]) -> [ID] {
      if case .interval(let first, let last) = membership,
        let start = positions[first], let end = positions[last]
      {
        return Array(ids[start...end])
      }
      return []
    }
    let rows: [RowID]
    let columns: [ColumnID]
    let allColumns = model.columns.map(\.id)
    switch target {
    case .rectangle(_, let r, let c):
      rows = interval(r, positions: axes.rows, ids: model.rows)
      columns = interval(c, positions: axes.columns, ids: allColumns)
    case .columns(_, let c):
      rows = model.rows
      columns = interval(c, positions: axes.columns, ids: allColumns)
    case .rows(_, let r):
      rows = interval(r, positions: axes.rows, ids: model.rows)
      columns = allColumns
    case .namedColumn(_, let c):
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
    let parsing: ParsingResult
    do {
      parsing = try engine.parse(
        syntax, context: context, operandKinds: kinds,
        inheritedKinds: scope.inherited.compactMapValues { $0?.kind })
    } catch let diagnostic as TableFormulaDiagnostic {
      return .failure(
        failure(.reference, at: address, range: diagnostic.range, reference: diagnostic))
    }
    guard let expression = parsing.expression else {
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
    for binding in bindings {
      switch operands[binding.occurrence.slot] {
      case .range:
        return .failure(
          failure(.unsupportedRangeOperation, at: address, range: binding.occurrence.range))
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
        if case .range = plans[input] { continue }
        switch results[input] {
        case .scalar(let value): known[slot] = value.kind
        case .failure: unknown[input, default: []].append(slot)
        default: break
        }
      }
    }
    guard unknown.count <= maximumUnknownOperands else { return nil }
    let groups = unknown.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    let check = TableStaticCheck(template: template, known: known, unknown: groups)
    if let cached = staticFailures[check] { return cached }
    let inheritedKinds = scope.inherited.compactMapValues { $0?.kind }
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
