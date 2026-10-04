import Foundation
import Testing

@testable import GanitEngine

@Suite struct TableGraphIndependentTests {
  private func table(_ inputs: [[String]], policies: [TableInputPolicy]? = nil) -> TableModel {
    let columns = inputs.first?.count ?? 1
    var table = TableModel.creating(
      name: "Items", headers: (0..<columns).map { ("Field\($0)", policies?[$0] ?? .value) },
      rowCount: inputs.count)
    for (row, sources) in inputs.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(row: table.rows[row], column: table.columns[column].id, source: source))
      }
    }
    return table
  }

  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  private func calculate(_ table: TableModel) throws -> TableCalculationSnapshot {
    try TableCalculator().calculate(
      table, scope: TableFormulaScope(current: table, visible: [], inherited: [:]),
      context: sheetContext())
  }

  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }

  @Test func cycleWitnessUsesDirectedEdgesAndLeavesIndependentCellsValid() throws {
    let table = table([["=C2", "=A2", "=B2", "=A2 + 1", "=7"]])
    let snapshot = try calculate(table)
    let a = address(table, 0, 0)
    guard case .failure(let failure) = snapshot.outcomes[a] else {
      Issue.record("Expected cycle failure")
      return
    }
    #expect(Set(failure.cycleParticipants) == Set((0..<3).map { address(table, 0, $0) }))
    #expect(failure.cyclePath.count >= 4)
    #expect(failure.cyclePath.first == failure.cyclePath.last)
    for (from, to) in zip(failure.cyclePath, failure.cyclePath.dropFirst()) {
      let fromIndex = try #require(snapshot.nodes.firstIndex(of: from))
      let toIndex = try #require(snapshot.nodes.firstIndex(of: to))
      #expect(snapshot.dependencies[fromIndex].contains(toIndex))
    }
    guard case .failure(let blocked) = snapshot.outcomes[address(table, 0, 3)] else {
      Issue.record("Expected blocked cycle reader")
      return
    }
    #expect(!blocked.origin.isEmpty)
    #expect(snapshot.outcomes[address(table, 0, 4)] == number(7))
  }

  @Test func duplicateOperandsShareOneDependencyAndReverseLink() throws {
    let table = table([["=B2 + B2", "3"]])
    let snapshot = try calculate(table)
    let reader = try #require(snapshot.nodes.firstIndex(of: .cell(address(table, 0, 0))))
    let input = try #require(snapshot.nodes.firstIndex(of: .cell(address(table, 0, 1))))
    #expect(snapshot.dependencies[reader] == [input])
    #expect(snapshot.reverseDependencies[input] == [reader])
    #expect(snapshot.outcomes[address(table, 0, 0)] == number(6))
  }

  @Test func strictLiteralPoliciesAndBlankArithmeticRemainDistinct() throws {
    let table = table(
      [["1-2", "1-2", "", "=C2 + 1", "=B1"]], policies: [.value, .text, .value, .value, .value])
    let snapshot = try calculate(table)
    guard case .failure = snapshot.outcomes[address(table, 0, 0)] else {
      Issue.record("Arithmetic input needs an explicit formula")
      return
    }
    #expect(snapshot.outcomes[address(table, 0, 1)] == .text("1-2"))
    #expect(snapshot.outcomes[address(table, 0, 2)] == .blank)
    guard case .failure = snapshot.outcomes[address(table, 0, 3)] else {
      Issue.record("Blank arithmetic must fail")
      return
    }
    #expect(snapshot.outcomes[address(table, 0, 4)] == .text("Field1"))
  }

  @Test func ruleTemplateLocksAndBlankOverridesDoNotCollapseToInheritance() throws {
    var table = table([["1", ""], ["2", ""], ["3", ""], ["4", ""]])
    table.columns[1].rule = "=$A$2 + A2"
    table.cells.append(
      TableCell(row: table.rows[2], column: table.columns[1].id, source: "", isOverride: true))
    table.cells.append(
      TableCell(row: table.rows[3], column: table.columns[1].id, source: "=100", isOverride: true))
    let snapshot = try calculate(table)
    #expect(snapshot.outcomes[address(table, 0, 1)] == number(2))
    #expect(snapshot.outcomes[address(table, 1, 1)] == number(3))
    #expect(snapshot.outcomes[address(table, 2, 1)] == .blank)
    #expect(snapshot.outcomes[address(table, 3, 1)] == number(100))
  }

  @Test func stressModeTenThousandForwardCellsIsSeparateFromProductionCeiling() throws {
    let count = 10_000
    let table = table((0..<count).map { [$0 == count - 1 ? "=1" : "=A\($0 + 3) + 1"] })
    let snapshot = try TableCalculator(options: .engineStress).calculate(
      table, scope: TableFormulaScope(current: table, visible: [], inherited: [:]),
      context: sheetContext())
    #expect(snapshot.outcomes[address(table, 0, 0)] == number(count))
    #expect(snapshot.outcomes[address(table, count - 1, 0)] == number(1))
    #expect(throws: (any Error).self) { try calculate(table) }
  }

  @Test func cancelledGenerationProducesNoCommittedSnapshot() throws {
    let table = table([["1", "=A2 + 1"]])
    #expect(throws: CancellationError.self) {
      try TableCalculator().calculate(
        table, scope: TableFormulaScope(current: table, visible: [], inherited: [:]),
        context: sheetContext(), cancelled: { true })
    }
  }

  @Test func textWhitespaceIsLiteralAndUnitDefaultsCannotInjectArithmetic() throws {
    var table = table([[" \t\n", "5", "=B2 + 1 m"]], policies: [.text, .value, .value])
    table.columns[1].unit = "m + 1 m"
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == .text(" \t\n"))
    guard case .failure = snapshot.result(at: address(table, 0, 1)) else {
      Issue.record("A semantic unit default cannot execute an arithmetic expression")
      return
    }
    guard case .failure(let reader) = snapshot.result(at: address(table, 0, 2)) else {
      Issue.record("Reader of invalid default input must fail")
      return
    }
    #expect(reader.origin.contains { $0.address == address(table, 0, 1) })
  }

  @Test func cyclicOperandSpansAndTransitiveRootUnionRemainExact() throws {
    let sources = ["=1 / 0", "=2 / 0", "=A2", "=C2 + B2", "=7"]
    let table = table([sources])
    let snapshot = try calculate(table)
    guard case .failure(let first) = snapshot.result(at: address(table, 0, 0)),
      case .failure(let second) = snapshot.result(at: address(table, 0, 1)),
      case .failure(let blocked) = snapshot.result(at: address(table, 0, 3))
    else {
      Issue.record("Expected failures and a blocked reader")
      return
    }
    #expect(Set(blocked.origin) == Set(first.origin + second.origin))
    #expect(blocked.sourceRange.text(in: sources[3]) == "C2")
    #expect(snapshot.result(at: address(table, 0, 4)) == number(7))

    let cyclicSources = ["=10 + B2", "=20 + A2", "=B2 + 1"]
    let cyclic = self.table([cyclicSources])
    let cycleSnapshot = try calculate(cyclic)
    for (column, expected) in [(0, "B2"), (1, "A2")] {
      guard case .failure(let cycle) = cycleSnapshot.result(at: address(cyclic, 0, column)) else {
        Issue.record("Expected cycle")
        continue
      }
      #expect(cycle.sourceRange.text(in: cyclicSources[column]) == Substring(expected))
      for root in cycle.origin {
        let rootColumn = try #require(cyclic.columns.firstIndex { $0.id == root.address.column })
        #expect(root.range.text(in: cyclicSources[rootColumn]) == (rootColumn == 0 ? "B2" : "A2"))
      }
    }
  }

  @Test func sharedRangeMembershipAppearsInRealCycleWitness() throws {
    let table = table([["=sum(B:B)", "=A2", "9"]])
    let snapshot = try calculate(table)
    guard case .failure(let cycle) = snapshot.result(at: address(table, 0, 0)) else {
      Issue.record("Expected a range membership cycle")
      return
    }
    #expect(cycle.code == .cycle)
    #expect(
      cycle.cyclePath.contains {
        if case .range = $0 { return true }
        return false
      })
    for (from, to) in zip(cycle.cyclePath, cycle.cyclePath.dropFirst()) {
      let fromIndex = try #require(snapshot.nodes.firstIndex(of: from))
      let toIndex = try #require(snapshot.nodes.firstIndex(of: to))
      #expect(snapshot.dependencies[fromIndex].contains(toIndex))
    }
    #expect(snapshot.result(at: address(table, 0, 2)) == number(9))
  }

  @Test func forwardPercentageAndQuantityKindsReachTheExistingParser() throws {
    let table = table([["=B2 of C2", "20%", "200", "=E2 + 2 m", "3 m"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(40))
    let expected = try #require(Parser(source: "5 m").parse().expression)
    let value = try Evaluator(context: sheetContext()).evaluate(expected)
    #expect(snapshot.result(at: address(table, 0, 3)) == .scalar(value))
  }

  // MARK: - Review regressions

  @Test func calculatedEarlierTableIsTheAuthoritativeModel() throws {
    var rates = table([["1"], ["2"], ["3"]])
    rates.name = "Rates"
    let ratesSnapshot = try calculate(rates)
    var shorter = rates
    shorter.rows = [rates.rows[0]]
    shorter.cells = [rates.cells[0]]

    // Scope still shows the shorter model; the calculated three-row table wins.
    let items = table([["=Rates!A4 + 1", "=sum(Rates!A:A)"]])
    let snapshot = try TableCalculator().calculate(
      items, scope: TableFormulaScope(current: items, visible: [shorter], inherited: [:]),
      context: sheetContext(), earlier: [rates.id: ratesSnapshot])
    #expect(snapshot.result(at: address(items, 0, 0)) == number(4))
    let range = try #require(
      snapshot.nodes.firstIndex {
        if case .range = $0 { return true }
        return false
      })
    #expect(snapshot.dependencies[range].count == 3)

    // The reverse mismatch fails at the reading cell's own operand.
    let shorterSnapshot = try calculate(shorter)
    let source = "=Rates!A4 + 1"
    let reader = table([[source]])
    let mismatch = try TableCalculator().calculate(
      reader, scope: TableFormulaScope(current: reader, visible: [rates], inherited: [:]),
      context: sheetContext(), earlier: [rates.id: shorterSnapshot])
    guard case .failure(let failure) = mismatch.result(at: address(reader, 0, 0)) else {
      Issue.record("Expected a reference failure")
      return
    }
    #expect(failure.code == .reference)
    #expect(failure.referenceDiagnostic?.code == .outOfBounds)
    #expect(failure.origin.map(\.address) == [address(reader, 0, 0)])
    #expect(failure.sourceRange.text(in: source) == "Rates!A4")
  }

  @Test func ownStaticErrorOutranksBlockedInput() throws {
    let sources = ["=1 / 0", "=A2 +", "=A2 + sum", "=A2 + 1", "=A2 of 5", "=A2 + previous"]
    let table = table([sources])
    let snapshot = try calculate(table)
    func failure(_ column: Int) -> TableCalculationFailure? {
      guard case .failure(let failure) = snapshot.result(at: address(table, 0, column)) else {
        Issue.record("Expected failure in column \(column)")
        return nil
      }
      return failure
    }
    let syntax = failure(1)
    #expect(syntax?.code == .syntax)
    #expect(syntax?.syntaxDiagnostics.isEmpty == false)
    #expect(syntax?.origin.map(\.address) == [address(table, 0, 1)])
    for column in [2, 5] {
      let bare = failure(column)
      #expect(bare?.code == .reference)
      #expect(bare?.referenceDiagnostic?.code == .bareAggregate)
      #expect(bare?.origin.map(\.address) == [address(table, 0, column)])
    }
    #expect(failure(3)?.code == .blocked)
    // Valid when A2 is a percentage: parsing depends on the failed kind.
    #expect(failure(4)?.code == .blocked)
  }

  @Test func failedInheritedLineIsDistinctFromMissingName() throws {
    let sources = ["=sheet[rate] + 1", "=sheet[missing] + 1", "=A2 * 2"]
    let table = table([sources])
    let snapshot = try TableCalculator().calculate(
      table, scope: TableFormulaScope(current: table, visible: [], inherited: ["rate": nil]),
      context: sheetContext())
    guard case .failure(let failed) = snapshot.result(at: address(table, 0, 0)),
      case .failure(let missing) = snapshot.result(at: address(table, 0, 1)),
      case .failure(let blocked) = snapshot.result(at: address(table, 0, 2))
    else {
      Issue.record("Expected failures")
      return
    }
    #expect(failed.code == .reference)
    #expect(failed.referenceDiagnostic?.code == .inheritedFailure)
    #expect(failed.sourceRange.text(in: sources[0]) == "sheet[rate]")
    #expect(missing.referenceDiagnostic?.code == .missingInheritedVariable)
    #expect(blocked.code == .blocked)
    #expect(blocked.origin.map(\.address) == [address(table, 0, 0)])
  }

  @Test func onlyArithmeticInputSuggestsAFormula() throws {
    let sources = ["abc", "half", "1-2", "2 * 3", "sqrt(4)", "abc + 1"]
    let table = table([sources])
    let snapshot = try calculate(table)
    for (column, expected) in [
      (0, TableCalculationFailure.Code.invalidLiteral), (1, .invalidLiteral),
      (2, .inputRequiresFormula), (3, .inputRequiresFormula), (4, .inputRequiresFormula),
      (5, .invalidLiteral),
    ] {
      guard case .failure(let failure) = snapshot.result(at: address(table, 0, column)) else {
        Issue.record("Expected failure for \(sources[column])")
        continue
      }
      #expect(failure.code == expected, "\(sources[column])")
    }
  }

  @Test func deepCauseChainBuildsFlattensAndReleasesOnSmallThread() throws {
    // Each reader links its predecessor's set and one distinct cause: a
    // 5,000-deep union chain that must never recurse on teardown.
    let rows = 5_000
    let table = table(
      (0..<rows).map { row in [row == 0 ? "=B2" : "=A\(row + 1) + B\(row + 2)", "abc"] })
    let context = try sheetContext()
    final class Box: @unchecked Sendable {
      var count = 0
      var error: (any Error)?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
      do {
        let snapshot = try TableCalculator(options: .engineStress).calculate(
          table, scope: TableFormulaScope(current: table, visible: [], inherited: [:]),
          context: context)
        let last = TableCellAddress(
          table: table.id, row: table.rows[rows - 1], column: table.columns[0].id)
        if case .failure(let failure) = snapshot.result(at: last) {
          box.count = failure.origin.count
        }
      } catch {
        box.error = error
      }
      done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    #expect(done.wait(timeout: .now() + 120) == .success)
    #expect(box.error == nil)
    #expect(box.count == rows)
  }

  @Test func staticCheckKeepsKnownOperandKinds() throws {
    let percentKnown = table([["20%", "=1/0", "=A2 of B2%"]])
    var snapshot = try calculate(percentKnown)
    guard case .failure(let blocked) = snapshot.result(at: address(percentKnown, 0, 2)) else {
      Issue.record("Expected a blocked reader")
      return
    }
    #expect(blocked.code == .blocked)
    #expect(blocked.origin.map(\.address) == [address(percentKnown, 0, 1)])

    let percentFailed = table([["=1/0", "5", "=A2 of B2%"]])
    snapshot = try calculate(percentFailed)
    guard case .failure(let mirror) = snapshot.result(at: address(percentFailed, 0, 2)) else {
      Issue.record("Expected a blocked reader")
      return
    }
    #expect(mirror.code == .blocked)
    #expect(mirror.origin.map(\.address) == [address(percentFailed, 0, 0)])

    // Too many failed inputs to enumerate: conservatively blocked.
    let many = table([["=1/0", "=2/0", "=3/0", "=A2 + B2 + C2 +"]])
    snapshot = try calculate(many)
    guard case .failure(let fallback) = snapshot.result(at: address(many, 0, 3)) else {
      Issue.record("Expected a blocked reader")
      return
    }
    #expect(fallback.code == .blocked)
  }

  // MARK: - Growth regressions

  /// Wall time varies by large constant factors across debug, ASan and TSan
  /// builds, so these check growth: 4× the input must cost well under the
  /// 16× a quadratic path needs. Best of two damps scheduling noise. A
  /// generous absolute ceiling applies only without sanitizers.
  private func expectNearLinear(
    base: Int, sourceLocation: Testing.SourceLocation = #_sourceLocation,
    _ work: (Int) throws -> Void
  ) throws {
    func best(_ size: Int) throws -> Double {
      var fastest = Double.infinity
      for _ in 0..<2 {
        let start = ContinuousClock.now
        try work(size)
        let elapsed = (ContinuousClock.now - start).components
        fastest = min(
          fastest, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
      }
      return fastest
    }
    let small = try best(base)
    let large = try best(base * 4)
    #expect(
      large < max(small, 0.05) * 9, "\(base)→\(base * 4): \(small)s → \(large)s",
      sourceLocation: sourceLocation)
    if !sanitized {
      #expect(large < 30, "\(large)s", sourceLocation: sourceLocation)
    }
  }

  private func cycleFanOut(_ rows: Int) -> TableModel {
    var table = table((0..<rows).map { _ in ["", ""] })
    table.columns[0].rule = "=sum(A:A)"
    table.columns[1].rule = "=A2 * 2"
    return table
  }

  private func invalidFanOut(_ rows: Int) -> TableModel {
    var table = table((0..<rows).map { _ in ["", "abc"] })
    table.columns[0].rule = "=B2 / sum(B:B)"
    return table
  }

  /// Each reader has two distinct causes beside one large shared cause set.
  private func distinctCauses(_ rows: Int) -> TableModel {
    var table = table((0..<rows).map { _ in ["", "abc", "def", "ghi"] })
    table.columns[0].rule = "=B2 + C2 + sum(D:D)"
    return table
  }

  /// Each reader links its predecessor's set and one distinct cause.
  private func causeChain(_ rows: Int) -> TableModel {
    table((0..<rows).map { row in [row == 0 ? "=B2" : "=A\(row + 1) + B\(row + 2)", "abc"] })
  }

  @Test func blockedFanOutOverProductionSizedFailuresStaysLinear() throws {
    let rows = 2_000
    let cycle = cycleFanOut(rows)
    #expect(cycle.populatedCellCount == TableCalculationOptions.production.maximumPopulatedCells)
    let cycleSnapshot = try calculate(cycle)
    for row in [0, rows - 1] {
      guard case .failure(let blocked) = cycleSnapshot.result(at: address(cycle, row, 1)) else {
        Issue.record("Expected a blocked reader")
        continue
      }
      #expect(blocked.code == .blocked)
      #expect(blocked.origin.count == rows)
      #expect(blocked.cycleParticipants.count == rows)
      #expect(blocked.cycleParticipants.first == address(cycle, 0, 0))
      #expect(!blocked.cyclePath.isEmpty)
    }
    let invalid = invalidFanOut(rows)
    let invalidSnapshot = try calculate(invalid)
    guard case .failure(let blocked) = invalidSnapshot.result(at: address(invalid, rows - 1, 0))
    else {
      Issue.record("Expected a blocked reader")
      return
    }
    #expect(blocked.code == .blocked)
    #expect(blocked.origin.map(\.address) == (0..<rows).map { address(invalid, $0, 1) })

    try expectNearLinear(base: rows / 4) { rows in
      _ = try calculate(cycleFanOut(rows))
      _ = try calculate(invalidFanOut(rows))
    }
  }

  @Test func distinctCausesBesideASharedLargeCauseSetAreNotCopiedPerReader() throws {
    let rows = 1_000
    let table = distinctCauses(rows)
    #expect(table.populatedCellCount == TableCalculationOptions.production.maximumPopulatedCells)
    let snapshot = try calculate(table)
    for row in [0, rows / 2, rows - 1] {
      guard case .failure(let blocked) = snapshot.result(at: address(table, row, 0)) else {
        Issue.record("Expected a blocked reader")
        continue
      }
      #expect(blocked.code == .blocked)
      let origins = blocked.origin.map(\.address)
      #expect(origins.count == rows + 2)
      #expect(blocked.originCount == rows + 2)
      #expect(Set(origins).count == origins.count)
      #expect(origins.contains(address(table, row, 1)))
      #expect(origins.contains(address(table, row, 2)))
      #expect(!origins.contains(address(table, (row + 1) % rows, 1)))
      #expect(origins.first == address(table, 0, row == 0 ? 1 : 3))
      #expect(blocked.cycleParticipants.isEmpty)
    }
    // Building plus touching a few readers' origins.
    try expectNearLinear(base: rows / 4) { rows in
      let table = distinctCauses(rows)
      let snapshot = try calculate(table)
      for row in [0, rows - 1] {
        if case .failure(let failure) = snapshot.result(at: address(table, row, 0)) {
          _ = failure.origin
        }
      }
    }
  }

  @Test func comparingAndReadingSharedCausesFlattensEachSetOnce() throws {
    let rows = 2_000
    let table = cycleFanOut(rows)
    let first = try calculate(table)
    let second = try calculate(table)
    #expect(first.outcomes == second.outcomes)
    var origins = 0
    for snapshot in [first, second] {
      for result in snapshot.outcomes.values {
        guard case .failure(let failure) = result else { continue }
        origins += failure.origin.count + failure.cycleParticipants.count
      }
    }
    #expect(origins == 2 * (2 * rows) * (2 * rows))
    guard case .failure(let reader) = first.result(at: address(table, rows - 1, 1)) else {
      Issue.record("Expected a blocked reader")
      return
    }
    #expect(reader.originCount == rows)
    #expect(
      reader.origins(prefix: 2).map(\.address) == [address(table, 0, 0), address(table, 1, 0)])

    try expectNearLinear(base: rows / 4) { rows in
      let table = cycleFanOut(rows)
      let first = try calculate(table)
      let second = try calculate(table)
      #expect(first.outcomes == second.outcomes)
      for result in first.outcomes.values {
        if case .failure(let failure) = result { _ = failure.origin.count }
      }
    }
  }

  @Test func hashingOutcomesWithSharedCauseSetsStaysLinear() throws {
    let rows = 1_000
    let snapshot = try calculate(distinctCauses(rows))
    let distinct = Set(snapshot.outcomes.values)
    // Readers differ by their own causes; the shared literal failures differ by cell.
    #expect(distinct.count == snapshot.outcomes.count)
    try expectNearLinear(base: rows / 4) { rows in
      let snapshot = try calculate(distinctCauses(rows))
      _ = Set(snapshot.outcomes.values)
    }
  }

  @Test func separateCalculationsCompareEqualInLinearTime() throws {
    for fixture in [distinctCauses, causeChain] {
      let table = fixture(1_000)
      #expect(try calculate(table).outcomes == calculate(table).outcomes)
    }
    // A different cause structure is not equal, even with equal codes.
    let one = table([["abc", "=A2 + 1"]])
    let other = table([["def", "=A2 + 1"]])
    let a = try calculate(one).result(at: address(one, 0, 1))
    let b = try calculate(other).result(at: address(other, 0, 1))
    #expect(a != b)

    try expectNearLinear(base: 250) { rows in
      let table = distinctCauses(rows)
      let first = try calculate(table)
      let second = try calculate(table)
      #expect(first.outcomes == second.outcomes)
    }
    try expectNearLinear(base: 500) { rows in
      let table = causeChain(rows)
      let first = try calculate(table)
      let second = try calculate(table)
      #expect(first.outcomes == second.outcomes)
    }
  }

  @Test func failedInheritedOperandOutranksKindSearch() throws {
    let sources = ["=sheet[p] of B2", "=1/0"]
    let table = table([sources])
    let snapshot = try TableCalculator().calculate(
      table, scope: TableFormulaScope(current: table, visible: [], inherited: ["p": nil]),
      context: sheetContext())
    guard case .failure(let failure) = snapshot.result(at: address(table, 0, 0)) else {
      Issue.record("Expected a failure")
      return
    }
    #expect(failure.code == .reference)
    #expect(failure.referenceDiagnostic?.code == .inheritedFailure)
    #expect(failure.sourceRange.text(in: sources[0]) == "sheet[p]")
    #expect(failure.origin.map(\.address) == [address(table, 0, 0)])
  }

  @Test func staticCheckParsesAreBudgeted() throws {
    // Two independently broken formulas over two failed inputs: each needs
    // the full 9 × 9 kind search before it can be called a syntax error.
    let broken = table([["abc", "def", "=A2 + B2 +", "=B2 + A2 +"]])
    let unlimited = try calculate(broken)
    for column in [2, 3] {
      guard case .failure(let failure) = unlimited.result(at: address(broken, 0, column)) else {
        Issue.record("Expected a failure")
        continue
      }
      #expect(failure.code == .syntax)
    }
    let budgeted = try TableCalculator(
      options: TableCalculationOptions(maximumPopulatedCells: 4_000, maximumStaticCheckParses: 81)
    ).calculate(
      broken, scope: TableFormulaScope(current: broken, visible: [], inherited: [:]),
      context: sheetContext())
    var codes: [TableCalculationFailure.Code] = []
    for column in [2, 3] {
      if case .failure(let failure) = budgeted.result(at: address(broken, 0, column)) {
        codes.append(failure.code)
      }
    }
    #expect(codes.sorted { $0.rawValue < $1.rawValue } == [.blocked, .syntax])
    #expect(TableCalculationOptions.production.maximumStaticCheckParses == 16_000)
  }
}

private let sanitized = ["__asan_init", "__tsan_init"].contains { (symbol: String) in
  dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil
}
