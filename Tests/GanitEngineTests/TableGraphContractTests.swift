import Foundation
import Testing

@testable import GanitEngine

/// Task-2 exit evidence: graph order, SCC diagnostics, blocked propagation,
/// original-cause spans, cross-table/inherited reads, rules, stack safety and
/// cancellation. Independent of the implementation's own test corpus.
@Suite struct TableGraphContractTests {
  private func table(
    _ inputs: [[String]], name: String = "Items", policies: [TableInputPolicy]? = nil
  ) -> TableModel {
    let columns = inputs.map(\.count).max() ?? 1
    var table = TableModel.creating(
      name: name, headers: (0..<columns).map { ("Field\($0)", policies?[$0] ?? .value) },
      rowCount: inputs.count)
    for (row, sources) in inputs.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(row: table.rows[row], column: table.columns[column].id, source: source))
      }
    }
    return table
  }

  /// `row` is a zero-based data row index (A1 row = row + 2).
  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  private func calculate(
    _ table: TableModel, visible: [TableModel] = [], inherited: [String: EngineValue?] = [:],
    earlier: [TableID: TableCalculationSnapshot] = [:],
    options: TableCalculationOptions = .production,
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> TableCalculationSnapshot {
    try TableCalculator(options: options).calculate(
      table, scope: TableFormulaScope(current: table, visible: visible, inherited: inherited),
      context: sheetContext(), earlier: earlier, cancelled: cancelled)
  }

  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }

  private func ordinary(_ source: String) throws -> TableCellResult {
    let expression = try #require(Parser(source: source).parse().expression)
    return .scalar(try Evaluator(context: sheetContext()).evaluate(expression))
  }

  private func failure(
    _ snapshot: TableCalculationSnapshot, _ address: TableCellAddress,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) -> TableCalculationFailure? {
    guard case .failure(let failure) = snapshot.result(at: address) else {
      Issue.record(
        "Expected failure, got \(String(describing: snapshot.result(at: address)))",
        sourceLocation: sourceLocation)
      return nil
    }
    return failure
  }

  // MARK: - Graph order

  @Test func referencesInEveryDirectionEvaluateInGraphOrder() throws {
    // 3x3 grid; center B3 reads up, down, left, right and both diagonals. Its
    // inputs are themselves formulas pointing further down/right/left, so row
    // order would read unevaluated cells.
    let table = table([
      ["=C4 + 1", "=A4 * 2", "=B4 - 1"],  // A2 (↘ diagonal), B2 (↙), C2 (↓ left)
      ["=B2 + 1", "=B2 + B4 + A3 + C3 + A2 + C4", "=A3 * 10"],  // A3, center B3, C3
      ["=C4 + 3", "=A4 + C4", "5"],  // A4 (→), B4 (←→), C4
    ])
    let snapshot = try calculate(table)
    // C4=5, A4=8, B4=13, A2=6, B2=16, C2=12, A3=17, C3=170
    #expect(snapshot.result(at: address(table, 2, 2)) == number(5))
    #expect(snapshot.result(at: address(table, 2, 0)) == number(8))
    #expect(snapshot.result(at: address(table, 2, 1)) == number(13))
    #expect(snapshot.result(at: address(table, 0, 0)) == number(6))
    #expect(snapshot.result(at: address(table, 0, 1)) == number(16))
    #expect(snapshot.result(at: address(table, 0, 2)) == number(12))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(17))
    #expect(snapshot.result(at: address(table, 1, 2)) == number(170))
    // B3 = B2 + B4 + A3 + C3 + A2 + C4 = 16 + 13 + 17 + 170 + 6 + 5
    #expect(snapshot.result(at: address(table, 1, 1)) == number(227))
  }

  @Test func downwardAndUpwardChainsEvaluate() throws {
    // Column A: downward chain (each reads the row below);
    // column B: upward chain (each reads the row above).
    let rows = 6
    let table = table(
      (0..<rows).map { row in
        [
          row == rows - 1 ? "1" : "=A\(row + 3) + 1",
          row == 0 ? "100" : "=B\(row + 1) * 2",
        ]
      })
    let snapshot = try calculate(table)
    for row in 0..<rows {
      #expect(snapshot.result(at: address(table, row, 0)) == number(rows - row))
      #expect(snapshot.result(at: address(table, row, 1)) == number(100 << row))
    }
  }

  @Test func diamondDependencyHasOneSharedInputAndEvaluatesCorrectly() throws {
    let table = table([["2", "=A2 * 3", "=A2 + 4", "=B2 + C2"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 3)) == number(12))
    let input = try #require(snapshot.nodes.firstIndex(of: .cell(address(table, 0, 0))))
    #expect(snapshot.nodes.filter { $0 == .cell(address(table, 0, 0)) }.count == 1)
    let readers = Set(snapshot.reverseDependencies[input].map { snapshot.nodes[$0] })
    #expect(readers == [.cell(address(table, 0, 1)), .cell(address(table, 0, 2))])
    let sink = try #require(snapshot.nodes.firstIndex(of: .cell(address(table, 0, 3))))
    #expect(snapshot.dependencies[sink].count == 2)
  }

  @Test func dependencyFromLaterRootStillPrecedesItsReader() throws {
    // A2 reads B3, an inherited column-rule cell that is created after every
    // explicit cell; B3's rule reads A3, which reads C2, a blank-then-literal
    // chain created later still. Explicit A2 is the first DFS root.
    var table = table([["=B3 + 1", "", "7"], ["=C2 * 2", "", ""]])
    table.columns[1].rule = "=A2 + 100"
    // B2's rule cell reads A2 (fine); B3's reads A3 = 14 -> 114; A2 = 115.
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 1, 0)) == number(14))
    #expect(snapshot.result(at: address(table, 1, 1)) == number(114))
    #expect(snapshot.result(at: address(table, 0, 0)) == number(115))
    #expect(snapshot.result(at: address(table, 0, 1)) == number(215))
  }

  // MARK: - Cycles

  @Test func selfReferenceIsACycle() throws {
    let source = "=A2"
    let table = table([[source, "4"]])
    let snapshot = try calculate(table)
    let a2 = address(table, 0, 0)
    guard let cycle = failure(snapshot, a2) else { return }
    #expect(cycle.code == .cycle)
    #expect(cycle.cycleParticipants == [a2])
    #expect(cycle.cyclePath == [.cell(a2), .cell(a2)])
    #expect(cycle.sourceRange.text(in: source) == "A2")
    #expect(cycle.origin.map(\.address) == [a2])
    #expect(snapshot.result(at: address(table, 0, 1)) == number(4))
  }

  @Test func disjointCyclesHaveSeparateParticipantSets() throws {
    let table = table([["=B2 + 1", "=A2 + 1", "=D2 * 2", "=C2 * 2", "=7"]])
    let snapshot = try calculate(table)
    let first: Set = [address(table, 0, 0), address(table, 0, 1)]
    let second: Set = [address(table, 0, 2), address(table, 0, 3)]
    for column in 0..<4 {
      guard let cycle = failure(snapshot, address(table, 0, column)) else { continue }
      #expect(cycle.code == .cycle)
      let expected = column < 2 ? first : second
      #expect(Set(cycle.cycleParticipants) == expected)
      #expect(Set(cycle.origin.map(\.address)).isSubset(of: expected))
      #expect(!cycle.origin.isEmpty)
      #expect(Set(cycle.cyclePath.compactMap(cell)) == expected)
      #expect(cycle.cyclePath.first == cycle.cyclePath.last)
    }
    #expect(snapshot.result(at: address(table, 0, 4)) == number(7))
  }

  @Test func twoLevelBlockedReaderCarriesOriginalCycleOrigin() throws {
    let sources = ["=B2 + 1", "=A2 + 1", "=A2 + 1", "=3 * C2", "=D2"]
    let table = table([sources])
    let snapshot = try calculate(table)
    let participants: Set = [address(table, 0, 0), address(table, 0, 1)]
    guard let cycle = failure(snapshot, address(table, 0, 0)) else { return }
    for (column, read) in [(2, "A2"), (3, "C2"), (4, "D2")] {
      guard let blocked = failure(snapshot, address(table, 0, column)) else { continue }
      #expect(blocked.code == .blocked)
      #expect(blocked.sourceRange.text(in: sources[column]) == Substring(read))
      #expect(Set(blocked.cycleParticipants) == participants)
      #expect(Set(blocked.origin) == Set(cycle.origin))
      #expect(Set(blocked.origin.map(\.address)).isSubset(of: participants))
      #expect(!blocked.cyclePath.isEmpty)
    }
  }

  @Test func independentComponentsCalculateBesideCyclesAndFailures() throws {
    let table = table([
      ["=B2", "=A2", "=1 / 0", "=C2 + 1", "10", "=E2 * 2"],
      ["=E3 + F2", "3", "=B3 * B3", "=C3 - 1", "=B3 + 1", "=E2 + E3"],
    ])
    let snapshot = try calculate(table)
    #expect(failure(snapshot, address(table, 0, 0))?.code == .cycle)
    #expect(failure(snapshot, address(table, 0, 1))?.code == .cycle)
    #expect(failure(snapshot, address(table, 0, 2))?.code == .evaluation)
    #expect(failure(snapshot, address(table, 0, 3))?.code == .blocked)
    #expect(snapshot.result(at: address(table, 0, 4)) == number(10))
    #expect(snapshot.result(at: address(table, 0, 5)) == number(20))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(24))
    #expect(snapshot.result(at: address(table, 1, 1)) == number(3))
    #expect(snapshot.result(at: address(table, 1, 2)) == number(9))
    #expect(snapshot.result(at: address(table, 1, 3)) == number(8))
    #expect(snapshot.result(at: address(table, 1, 4)) == number(4))
    #expect(snapshot.result(at: address(table, 1, 5)) == number(14))
  }

  @Test func repeatedCalculationIsDeterministic() throws {
    let table = table([
      ["=C2", "=A2", "=B2", "=A2 + D3", "=1 / 0"],
      ["=E2 + 1", "=A3", "=D2", "=B2 * 0", "=E3"],
    ])
    let first = try calculate(table)
    let second = try calculate(table)
    #expect(first.outcomes == second.outcomes)
    #expect(first.nodes == second.nodes)
    #expect(first.dependencies == second.dependencies)
    for row in 0..<2 {
      for column in 0..<5 {
        let a = address(table, row, column)
        guard case .failure(let one) = first.result(at: a),
          case .failure(let two) = second.result(at: a)
        else { continue }
        #expect(one.cycleParticipants == two.cycleParticipants)
        #expect(one.cyclePath == two.cyclePath)
        #expect(one.origin == two.origin)
        #expect(one.sourceRange == two.sourceRange)
      }
    }
  }

  // MARK: - Original-cause spans

  @Test func divisionByZeroChainKeepsOriginalCellAndSpan() throws {
    let sources = ["=1 / 0", "=A2 + 1", "=5 * B2", "=C2"]
    let table = table([sources])
    let snapshot = try calculate(table)
    let root = address(table, 0, 0)
    guard let original = failure(snapshot, root) else { return }
    #expect(original.code == .evaluation)
    #expect(original.engineError != nil)
    #expect(original.origin.count == 1)
    let originRange = try #require(original.origin.first).range
    let spanned = try #require(originRange.text(in: sources[0]))
    #expect(!spanned.isEmpty)
    #expect(sources[0].contains(spanned))
    for (column, read) in [(1, "A2"), (2, "B2"), (3, "C2")] {
      guard let blocked = failure(snapshot, address(table, 0, column)) else { continue }
      #expect(blocked.code == .blocked)
      #expect(blocked.origin == [TableFailureOrigin(address: root, range: originRange)])
      #expect(blocked.sourceRange.text(in: sources[column]) == Substring(read))
      #expect(blocked.cycleParticipants.isEmpty)
      #expect(blocked.cyclePath.isEmpty)
    }
  }

  // MARK: - Exact money and units

  @Test func exactMoneyAndUnitsFlowThroughChains() throws {
    let table = table([["$10.10", "$0.20", "=A2 + B2", "=C2 * 3", "3 m", "20 cm", "=E2 + F2"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinary("$10.10 + $0.20")))
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinary("($10.10 + $0.20) * 3")))
    #expect(snapshot.result(at: address(table, 0, 6)) == (try ordinary("3 m + 20 cm")))
    for column in [2, 3] {
      guard case .scalar(.money(let money)) = snapshot.result(at: address(table, 0, column)) else {
        Issue.record("Expected money")
        continue
      }
      #expect(money.currency == "USD")
      if case .approximate = money.amount { Issue.record("Money chain lost exactness") }
    }
    guard case .scalar(.quantity(let length)) = snapshot.result(at: address(table, 0, 6)) else {
      Issue.record("Expected quantity")
      return
    }
    _ = length
  }

  @Test func incompatibleKindsFailAsEvaluationNotCrash() throws {
    let sources = ["$5", "3 m", "=A2 + B2", "=C2 + 1", "€2", "=A2 + E2", "4"]
    let table = table([sources])
    let snapshot = try calculate(table)
    let mixed = failure(snapshot, address(table, 0, 2))
    #expect(mixed?.code == .evaluation)
    #expect(mixed?.engineError != nil)
    #expect(failure(snapshot, address(table, 0, 3))?.code == .blocked)
    #expect(failure(snapshot, address(table, 0, 5))?.code == .evaluation)
    #expect(snapshot.result(at: address(table, 0, 6)) == number(4))
  }

  // MARK: - Cross-table and inherited reads

  @Test func earlierTableSnapshotIsReadThroughQualifiedReference() throws {
    let rates = table(
      [["Standard", "$2.50"], ["Bad", "=1 / 0"]], name: "Rates",
      policies: [.text, .value])
    let ratesSnapshot = try calculate(rates)
    let sources = ["4", "=Rates!B2 * A2", "=Rates!A2", "=Rates!B1", "=Rates!B3 + 1", "=A2 + 1"]
    let items = table([sources])
    let snapshot = try calculate(
      items, visible: [rates], earlier: [rates.id: ratesSnapshot])
    #expect(snapshot.result(at: address(items, 0, 1)) == (try ordinary("$2.50 * 4")))
    #expect(snapshot.result(at: address(items, 0, 2)) == .text("Standard"))
    #expect(snapshot.result(at: address(items, 0, 3)) == .text("Field1"))
    guard let blocked = failure(snapshot, address(items, 0, 4)) else { return }
    #expect(blocked.code == .blocked)
    #expect(blocked.origin.map(\.address) == [address(rates, 1, 1)])
    #expect(blocked.sourceRange.text(in: sources[4]) == "Rates!B3")
    #expect(snapshot.result(at: address(items, 0, 5)) == number(5))
    // Outcomes describe only the calculated table.
    #expect(snapshot.outcomes.keys.allSatisfy { $0.table == items.id })
  }

  @Test func unknownOrUncalculatedTableFailsAsReference() throws {
    let rates = table([["1", "2"]], name: "Rates")
    let sources = ["=Ghost!B2 + 1", "=Rates!B2 + 1", "=Rates!B9", "6"]
    let items = table([sources])
    // Rates is visible but has no earlier snapshot; Ghost is not visible at all.
    let snapshot = try calculate(items, visible: [rates], earlier: [:])
    for (column, operand) in [(0, "Ghost!B2"), (1, "Rates!B2"), (2, "Rates!B9")] {
      guard let missing = failure(snapshot, address(items, 0, column)) else { continue }
      #expect(missing.code == .reference)
      #expect(missing.referenceDiagnostic != nil)
      #expect(missing.sourceRange.text(in: sources[column]) == Substring(operand))
      #expect(missing.origin.map(\.address) == [address(items, 0, column)])
    }
    #expect(snapshot.result(at: address(items, 0, 3)) == number(6))
  }

  @Test func inheritedSheetVariableIsReadFromScope() throws {
    let sources = ["5", "=sheet[rate] * A2", "=sheet[missing] + 1", "=sheet[A2] + A2"]
    let table = table([sources])
    let snapshot = try calculate(
      table,
      inherited: [
        "rate": .number(.integer(IntegerValue(3))), "a2": .number(.integer(IntegerValue(100))),
      ])
    #expect(snapshot.result(at: address(table, 0, 1)) == number(15))
    #expect(failure(snapshot, address(table, 0, 2))?.code == .reference)
    #expect(
      failure(snapshot, address(table, 0, 2))?.sourceRange.text(in: sources[2])
        == "sheet[missing]")
    // `sheet[A2]` is the inherited variable, `A2` the cell.
    #expect(snapshot.result(at: address(table, 0, 3)) == number(105))
  }

  // MARK: - Column rules

  @Test func columnRuleInstantiatesPerRowWithRelativeAndLockedRows() throws {
    var extended = table([["1", "", ""], ["2", "", ""], ["3", "", ""], ["4", "", ""]])
    extended.columns[1].rule = "=A2 * 10 + $A$2 + A$3"
    // Reads the following row; on the last row that translates past the table.
    extended.columns[2].rule = "=A3"
    let snapshot = try calculate(extended)
    for row in 0..<4 {
      #expect(snapshot.result(at: address(extended, row, 1)) == number((row + 1) * 10 + 1 + 2))
    }
    for row in 0..<3 {
      #expect(snapshot.result(at: address(extended, row, 2)) == number(row + 2))
    }
    guard let outside = failure(snapshot, address(extended, 3, 2)) else { return }
    #expect(outside.code == .reference)
    #expect(outside.referenceDiagnostic?.code == .outOfBounds)
    #expect(outside.sourceRange.text(in: "=A3") == "A3")
  }

  // MARK: - Stack safety and cancellation

  @Test func tenThousandCellUpwardChainIsStackSafeOnSmallThread() throws {
    let count = 10_000
    let upward = table((0..<count).map { [$0 == 0 ? "=1" : "=A\($0 + 1) + 1"] })
    let downward = table((0..<count).map { [$0 == count - 1 ? "=1" : "=A\($0 + 3) + 1"] })
    let context = try sheetContext()
    final class Box: @unchecked Sendable {
      var upward: TableCellResult?
      var downward: TableCellResult?
      var error: (any Error)?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let calculator = TableCalculator(options: .engineStress)
    let thread = Thread {
      do {
        let up = try calculator.calculate(
          upward, scope: TableFormulaScope(current: upward, visible: [], inherited: [:]),
          context: context)
        box.upward = up.result(
          at: TableCellAddress(
            table: upward.id, row: upward.rows[count - 1], column: upward.columns[0].id))
        let down = try calculator.calculate(
          downward, scope: TableFormulaScope(current: downward, visible: [], inherited: [:]),
          context: context)
        box.downward = down.result(
          at: TableCellAddress(
            table: downward.id, row: downward.rows[0], column: downward.columns[0].id))
      } catch {
        box.error = error
      }
      done.signal()
    }
    thread.stackSize = 512 * 1024
    let started = Date()
    thread.start()
    #expect(done.wait(timeout: .now() + 120) == .success)
    #expect(Date().timeIntervalSince(started) < 120)
    #expect(box.error == nil)
    #expect(box.upward == number(count))
    #expect(box.downward == number(count))
  }

  @Test func cancellationMidCalculationThrows() throws {
    let count = 300
    let table = table((0..<count).map { [$0 == 0 ? "1" : "=A\($0 + 1) + 1", "=A\($0 + 2) * 2"] })
    final class Counter: @unchecked Sendable {
      let lock = NSLock()
      var calls = 0
      var limit: Int
      init(limit: Int) { self.limit = limit }
      func tick() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls > limit
      }
    }
    let probe = Counter(limit: .max)
    let full = try calculate(table, cancelled: { probe.tick() })
    #expect(full.result(at: address(table, count - 1, 1)) == number(count * 2))
    let total = probe.calls
    #expect(total > 10)
    for fraction in [0.1, 0.5, 0.9] {
      let counter = Counter(limit: Int(Double(total) * fraction))
      #expect(throws: CancellationError.self) {
        try calculate(table, cancelled: { counter.tick() })
      }
      // Cancellation is observed promptly after the flag flips.
      #expect(counter.calls == counter.limit + 1)
    }
  }
}

private func cell(_ node: TableDependencyNode) -> TableCellAddress? {
  if case .cell(let address) = node { return address }
  return nil
}
