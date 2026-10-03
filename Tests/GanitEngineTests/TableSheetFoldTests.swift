import Foundation
import Testing

@testable import GanitEngine

/// M3 task 3: table blocks are calculated inside the sheet's one top-to-bottom
/// fold. Tables capture the scope above them in definition order, their
/// source lines never answer or join aggregates, and prose below reads them
/// only through qualified operands.
@Suite struct TableSheetFoldTests {
  // MARK: - Support

  /// A table of value columns, literal or formula cells by `[row][column]`
  /// (empty means no record) and optional column rules.
  static func table(
    _ name: String, headers: [String], rows: [[String]] = [], rowCount: Int? = nil,
    rules: [Int: String] = [:]
  ) -> TableModel {
    var table = TableModel.creating(
      name: name, headers: headers.map { ($0, .value) }, rowCount: rowCount ?? rows.count)
    for (column, rule) in rules { table.columns[column].rule = rule }
    for (row, sources) in rows.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(
            row: table.rows[row], column: table.columns[column].id, source: source,
            isOverride: table.columns[column].rule != nil))
      }
    }
    return table
  }

  static func block(_ table: TableModel) throws -> String {
    try TableSourceDocument.canonicalBlock(for: table)
  }

  /// One calculator evaluating edit by edit, keeping unchanged lines' IDs as
  /// the editor does, so line caches and table snapshots are exercised.
  struct Run {
    var sheet: SheetSource
    var calculator: SheetCalculator
    let context: EvaluationContext

    init(markdown: Bool = false, calculator: SheetCalculator = SheetCalculator()) throws {
      sheet = SheetSource("")
      self.calculator = calculator
      context = try sheetContext(isMarkdownMode: markdown)
    }

    mutating func evaluate(_ text: String) throws -> SheetEvaluation {
      let old = Array(sheet.text.utf8)
      let new = Array(text.utf8)
      var prefix = 0
      while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
      var suffix = 0
      while suffix < min(old.count, new.count) - prefix,
        old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
      {
        suffix += 1
      }
      sheet.replace(
        utf8Range: prefix..<(old.count - suffix),
        with: String(decoding: new[prefix..<(new.count - suffix)], as: UTF8.self))
      return try calculator.evaluate(sheet, context: context)
    }
  }

  static func describe(_ value: EngineValue) -> String {
    if case .number(.integer(let integer)) = value { return integer.canonicalDigits }
    return "value"
  }

  /// Integers, `value` for other values, and failure codes with context.
  static func describe(_ result: CalculationResult?) -> String? {
    switch result {
    case nil: return nil
    case .value(let value): return describe(value)
    case .syntaxFailure(let diagnostics): return diagnostics.first?.messageKey
    case .evaluationFailure(let error):
      if case .tableReference(let problem) = error.context {
        return "table.\(problem.rawValue)"
      }
      return error.code.rawValue
    }
  }

  /// Every line's answer, without the empty line after the final newline
  /// that each sheet here ends with.
  static func answers(_ evaluation: SheetEvaluation) -> [String?] {
    Array(evaluation.lines.dropLast().map { describe($0.result) })
  }

  /// A data cell's outcome by zero-based data row and column.
  static func cell(
    _ evaluation: SheetEvaluation, _ id: TableID, row: Int, column: Int
  ) -> String? {
    guard let block = evaluation.table(id), let model = block.projection,
      let snapshot = block.calculation
    else { return "uncalculated" }
    let address = TableCellAddress(
      table: id, row: model.rows[row], column: model.columns[column].id)
    switch snapshot.result(at: address) {
    case .scalar(let value): return describe(value)
    case .text(let text): return "text:\(text)"
    case .blank: return "blank"
    case .failure(let failure): return "failure:\(failure.code)"
    case nil: return nil
    }
  }

  static func items(rule: String = "=[@Qty] * rate") -> TableModel {
    table("Items", headers: ["Qty", "Amount"], rows: [["2"], ["4"]], rules: [1: rule])
  }

  // MARK: - Scope

  @Test func assumptionsAboveFeedCellsAndProseBelowReadsThem() throws {
    let items = Self.items()
    var run = try Run()
    let evaluation = try run.evaluate(
      "rate = 3\n" + Self.block(items)
        + "total = sum(Items[Amount])\nItems!B2 + 1\nItems!A3 * 10\n")
    #expect(Self.cell(evaluation, items.id, row: 0, column: 1) == "6")
    #expect(Self.cell(evaluation, items.id, row: 1, column: 1) == "12")
    #expect(Self.answers(evaluation) == ["3", nil, nil, nil, "18", "7", "40"])
    #expect(evaluation.lines[4].declaredVariableName == "total")
    #expect(evaluation.calculatedTables == [items.id])
  }

  @Test func proseReadsCellsColumnsAndRanges() throws {
    let items = Self.items()
    var run = try Run()
    let evaluation = try run.evaluate(
      "rate = 3\n" + Self.block(items)
        + """
        sum(Items!B2:B3)
        sum(Items!B:B)
        average(Items[Qty])
        count(Items[Amount])
        max(Items[Amount]) - min(Items[Amount])
        sum(Items!2:2)
        Items[Amount] * 2
        Items!B1
        Items!B9
        Items[Price]
        Later[Qty]
        sum(Items[Amount]) + B2

        """)
    #expect(
      Array(Self.answers(evaluation).dropFirst(4))
        == [
          "18", "18", "3", "2", "6", "8", "table.notScalar", "table.notScalar",
          "table.outOfBounds", "table.unknownColumn", "table.unknownTable",
          EngineErrorCode.unknownIdentifier.rawValue,
        ])
  }

  @Test func changingAnEarlierAssumptionRecalculatesCellsAndDownstreamProse() throws {
    let items = Self.items()
    var run = try Run()
    let below = "total = sum(Items[Amount])\ntotal + 1\n"
    let first = try run.evaluate("rate = 3\n" + Self.block(items) + below)
    #expect(Self.answers(first).suffix(2) == ["18", "19"])
    let changed = try run.evaluate("rate = 5\n" + Self.block(items) + below)
    #expect(changed.calculatedTables == [items.id])
    #expect(Self.cell(changed, items.id, row: 0, column: 1) == "10")
    #expect(Self.cell(changed, items.id, row: 1, column: 1) == "20")
    #expect(Self.answers(changed).suffix(2) == ["30", "31"])
    #expect(changed.evaluatedLineIDs == [0, 4, 5].map { run.sheet.lines[$0].id })
  }

  @Test func anAppendedRowInheritsTheColumnFormulaAndUpdatesLaterProse() throws {
    let items = Self.items()
    var run = try Run()
    let source = "rate = 3\n" + (try Self.block(items)) + "total = sum(Items[Amount])\n"
    #expect(Self.answers(try run.evaluate(source)).last == "18")
    var document = TableSourceDocument(source)
    var edited = try document.appendRows(table: items.id).applying(to: source)
    document = TableSourceDocument(edited)
    edited = try document.setCell(
      table: items.id, at: TableCellPosition(row: 2, column: 0), source: "10"
    ).applying(to: edited)
    let evaluation = try run.evaluate(edited)
    #expect(Self.cell(evaluation, items.id, row: 2, column: 1) == "30")
    #expect(Self.answers(evaluation).last == "48")
    #expect(evaluation.calculatedTables == [items.id])
  }

  @Test func dividersHideEarlierTablesAndVariables() throws {
    let first = Self.table("First", headers: ["A"], rows: [["7"]])
    let second = Self.table(
      "Second", headers: ["A", "B"], rows: [["=First!A2", "=x + 1"]])
    var run = try Run()
    let evaluation = try run.evaluate(
      "x = 1\n" + Self.block(first) + "First!A2\n---\n" + Self.block(second)
        + "First!A2\nSecond!A2\n")
    #expect(Self.answers(evaluation)[4] == "7")
    #expect(Self.cell(evaluation, second.id, row: 0, column: 0) == "failure:reference")
    #expect(Self.cell(evaluation, second.id, row: 0, column: 1) == "failure:evaluation")
    #expect(Self.answers(evaluation).suffix(2) == ["table.unknownTable", "table.failedCell"])
  }

  @Test func laterTablesAndProseAreNotVisible() throws {
    let first = Self.table("First", headers: ["A"], rows: [["=Second!A2"]])
    let second = Self.table("Second", headers: ["A"], rows: [["=y"]])
    var run = try Run()
    let evaluation = try run.evaluate(
      "Second!A2\n" + Self.block(first) + Self.block(second) + "y = 4\n")
    #expect(Self.answers(evaluation).first == "table.unknownTable")
    #expect(Self.cell(evaluation, first.id, row: 0, column: 0) == "failure:reference")
    #expect(Self.cell(evaluation, second.id, row: 0, column: 0) == "failure:evaluation")
  }

  @Test func redeclarationAfterATableDoesNotChangeItsCapturedValue() throws {
    let items = Self.items()
    var run = try Run()
    let evaluation = try run.evaluate(
      "rate = 3\n" + Self.block(items) + "rate = 100\nItems!B2\nrate\n")
    #expect(Self.cell(evaluation, items.id, row: 0, column: 1) == "6")
    #expect(Self.answers(evaluation).suffix(3) == ["100", "6", "100"])
  }

  @Test func earlierTablesAreReadFromThisGeneration() throws {
    let rates = Self.table("Rates", headers: ["Rate"], rows: [["=base * 2"]])
    let items = Self.table(
      "Items", headers: ["Qty", "Amount"], rows: [["5"]], rules: [1: "=[@Qty] * Rates!$A$2"])
    var run = try Run()
    func source(_ base: Int) throws -> String {
      "base = \(base)\n" + (try Self.block(rates)) + (try Self.block(items))
        + "sum(Items[Amount])\n"
    }
    #expect(Self.answers(try run.evaluate(source(1))).last == "10")
    let changed = try run.evaluate(source(3))
    #expect(changed.calculatedTables == [rates.id, items.id])
    #expect(Self.cell(changed, items.id, row: 0, column: 1) == "30")
    #expect(Self.answers(changed).last == "30")
  }

  @Test func definitionsFunctionsUnitsAndRatesAreInherited() throws {
    let model = Self.table(
      "Calc", headers: ["Qty", "Doubled", "Mass", "Price"],
      rows: [
        [
          "3", "=double([@Qty]) + base", "=(1 box in kg) / (1 kg) * [@Qty]",
          "=(2 EUR in USD) / (1 USD)",
        ]
      ])
    var run = try Run(
      calculator: SheetCalculator(
        definitions: SheetDefinitions(variables: ["base": .number(.integer(IntegerValue(100)))])))
    let evaluation = try run.evaluate(
      "---\ndouble(x) = x * 2\n1 box = 4 kg\n1 EUR = 2 USD\n" + Self.block(model)
        + "Calc!B2 + base\n")
    #expect(Self.cell(evaluation, model.id, row: 0, column: 1) == "106")
    #expect(Self.cell(evaluation, model.id, row: 0, column: 2) == "12")
    #expect(Self.cell(evaluation, model.id, row: 0, column: 3) == "4")
    #expect(Self.answers(evaluation).last == "206")
  }

  @Test func inheritedProvenanceSurvivesProseVariablesLinesAndClosures() throws {
    let clock = Self.table("Clock", headers: ["Date"], rows: [["=nextDay"]])
    let prices = Self.table(
      "Prices", headers: ["Variable", "Line", "Function"],
      rows: [["=cost", "=@5", "=charge()"]])
    var run = try Run()
    let evaluated = try run.evaluate(
      "due = today\nnextDay = due + 1 day\n1 EUR = 2 USD\nprice = 2 EUR in USD\ncost = price * 2\ncharge() = cost\n"
        + Self.block(clock) + Self.block(prices))
    #expect(evaluated.table(clock.id)?.calculation?.combinedProvenance.clock == .day)
    let snapshot = try #require(evaluated.table(prices.id)?.calculation)
    for column in prices.columns {
      let address = TableCellAddress(table: prices.id, row: prices.rows[0], column: column.id)
      #expect(snapshot.provenance[address]?.rateUses == [.manual])
    }
  }

  @Test func anUnchangedTableResultDoesNotReevaluateItsReaders() throws {
    let items = Self.items()
    var run = try Run()
    let below = "total = sum(Items[Amount])\n"
    _ = try run.evaluate("rate = 3\nother = 1\n" + Self.block(items) + below)
    // The captured scope changed, so the table recalculates, but its results
    // did not, so lines reading it keep their answers without evaluating.
    let edited = try run.evaluate("rate = 3\nother = 2\n" + Self.block(items) + below)
    #expect(edited.calculatedTables == [items.id])
    #expect(edited.evaluatedLineIDs == [run.sheet.lines[1].id])
    #expect(Self.answers(edited).last == "18")
  }

  // MARK: - Physical lines and aggregates

  @Test func lineReferencesCountTablePhysicalLines() throws {
    let items = Self.items(rule: "=[@Qty] * @1")
    var run = try Run()
    // Lines: 1 `10`, 2–4 the block, 5 `@1 * 2`, 6 `@5 + 1`, 7 `@3`, 8 `line 2`.
    let evaluation = try run.evaluate(
      "10\n" + Self.block(items) + "@1 * 2\n@5 + 1\n@3\nline 2\n")
    #expect(Self.cell(evaluation, items.id, row: 1, column: 1) == "40")
    #expect(
      Self.answers(evaluation)
        == ["10", nil, nil, nil, "20", "21", "table.tableLine", "table.tableLine"])
    // A table formula reading a table line, its own or below it, fails.
    let reading = Self.table("Reading", headers: ["A", "B"], rows: [["=@2", "=@9"]])
    let other = try run.evaluate("10\n" + Self.block(items) + Self.block(reading) + "1\n")
    #expect(Self.cell(other, reading.id, row: 0, column: 0) == "failure:reference")
    #expect(Self.cell(other, reading.id, row: 0, column: 1) == "failure:reference")
  }

  @Test func tableLinesNeverJoinProseAggregates() throws {
    let items = Self.items(rule: "=[@Qty] * 100")
    var run = try Run()
    let evaluation = try run.evaluate(
      "1\n2\nsum\n" + Self.block(items) + "sum\n3\n4\ntotal\nprevious\n"
        + Self.block(items)
        .replacingOccurrences(of: "Items", with: "Again") + "previous\n")
    let answers = Self.answers(evaluation)
    #expect(answers[2] == "3")
    #expect(answers[6] == "0")
    #expect(answers[9] == "7")
    #expect(answers[10] == "7")
    #expect(answers.last == EngineErrorCode.invalidReference.rawValue)
    for block in evaluation.tables {
      for line in block.physicalLines {
        #expect(evaluation.lines[line].result == nil)
        #expect(evaluation.lines[line].assistantPrompts.isEmpty)
      }
    }
  }

  @Test func malformedAndUnknownBlocksStayQuarantined() throws {
    var run = try Run()
    let evaluation = try run.evaluate(
      "1\n@ganit-table 2\n2 + 2\nx = 5\n@end-ganit-table\n@ganit-table 1\n{\"bad\"\n3 * 3\n"
        + "@end-ganit-table\nsum\nx\n")
    #expect(evaluation.tables.count == 2)
    #expect(evaluation.tables.allSatisfy { $0.calculation == nil && $0.projection == nil })
    #expect(evaluation.calculatedTables.isEmpty)
    let answers = Self.answers(evaluation)
    #expect(answers[1...8].allSatisfy { $0 == nil })
    #expect(answers[9] == "0")
    #expect(answers[10] == EngineErrorCode.unknownIdentifier.rawValue)
  }

  // MARK: - Markdown

  @Test func markdownSheetsTreatTablesIdentically() throws {
    let items = Self.items()
    let source =
      "rate = 3\n" + (try Self.block(items))
      + "total = sum(Items[Amount])\nsum(Items[Amount]) + 1\nItems!B2\nThe end.\n"
    var regular = try Run()
    var markdown = try Run(markdown: true)
    let plain = try regular.evaluate(source)
    let marked = try markdown.evaluate(source)
    #expect(
      Self.answers(plain) == ["3", nil, nil, nil, "18", "19", "6", "syntax.unexpectedCharacter"])
    #expect(Self.answers(marked) == ["3", nil, nil, nil, "18", "19", "6", nil])
    #expect(marked.tables.map(\.physicalLines) == plain.tables.map(\.physicalLines))
    #expect(
      Self.cell(marked, items.id, row: 1, column: 1)
        == Self.cell(plain, items.id, row: 1, column: 1))
  }

  // MARK: - Caching

  @Test func tableFreeSheetsKeepTheirCacheCounters() throws {
    var run = try Run()
    let first = try run.evaluate("a = 1\nc = a + 1\nf = 5!\nd[1]\n")
    #expect(first.evaluatedLineIDs == run.sheet.lines.dropLast().map(\.id))
    #expect(first.parsedLineIDs == run.sheet.lines.dropLast().map(\.id))
    #expect(first.tables.isEmpty && first.calculatedTables.isEmpty)
    #expect(Self.answers(first)[2] == "120")
    let edited = try run.evaluate("a = 2\nc = a + 1\nf = 5!\nd[1]\n")
    #expect(edited.evaluatedLineIDs == [0, 1].map { run.sheet.lines[$0].id })
    #expect(edited.parsedLineIDs == [run.sheet.lines[0].id])
    let again = try run.evaluate("a = 2\nc = a + 1\nf = 5!\nd[1]\n")
    #expect(again.evaluatedLineIDs.isEmpty && again.parsedLineIDs.isEmpty)
  }

  @Test func anUnchangedTableIsReusedAcrossProseEditsBelowIt() throws {
    let items = Self.items()
    var run = try Run()
    let table = "rate = 3\n" + (try Self.block(items)) + "total = sum(Items[Amount])\n"
    let first = try run.evaluate(table + "1 + 1\n")
    let snapshot = try #require(first.table(items.id)?.calculation)
    let edited = try run.evaluate(table + "1 + 2\n")
    #expect(edited.calculatedTables.isEmpty)
    #expect(edited.evaluatedLineIDs == [run.sheet.lines[5].id])
    #expect(edited.table(items.id)?.calculation?.outcomes == snapshot.outcomes)
    #expect(Self.answers(edited).suffix(2) == ["18", "3"])
    // Editing one input recalculates only its dependents and the readers below.
    var document = TableSourceDocument(run.sheet.text)
    let input = try document.setCell(
      table: items.id, at: TableCellPosition(row: 0, column: 0), source: "5"
    ).applying(to: run.sheet.text)
    document = TableSourceDocument(input)
    let recalculated = try run.evaluate(input)
    #expect(recalculated.calculatedTables == [items.id])
    let calculation = try #require(recalculated.table(items.id)?.calculation)
    #expect(calculation.reusedCells == 2)
    #expect(calculation.evaluatedCells == 2)
    #expect(recalculated.evaluatedLineIDs == [run.sheet.lines[4].id])
    #expect(Self.answers(recalculated).suffix(2) == ["27", "3"])
  }

  @Test func aTableIsRecalculatedWhenItsContextChanges() throws {
    let clocked = Self.table("Clock", headers: ["A"], rows: [["=today + 1 day"]])
    var run = try Run()
    let evaluation = try run.evaluate("1\n" + Self.block(clocked))
    let snapshot = try #require(evaluation.table(clocked.id)?.calculation)
    #expect(snapshot.nextRecalculation != nil)
    #expect(evaluation.nextRecalculation == snapshot.nextRecalculation)
    let later = try run.calculator.evaluate(
      run.sheet, context: run.context.at(Date(timeIntervalSince1970: 86_400 * 2)))
    #expect(later.calculatedTables == [clocked.id])
  }

  // MARK: - Failures

  @Test func cyclesInsideATableDoNotBreakProseElsewhere() throws {
    let cyclic = Self.table(
      "Loop", headers: ["A", "B", "C"], rows: [["=B2", "=A2", "4"]])
    var run = try Run()
    let evaluation = try run.evaluate(
      "x = 5\n" + Self.block(cyclic) + "Loop!C2 * 2\nLoop!A2\nsum(Loop[A])\nx + 1\n")
    #expect(Self.cell(evaluation, cyclic.id, row: 0, column: 0) == "failure:cycle")
    #expect(Self.cell(evaluation, cyclic.id, row: 0, column: 2) == "4")
    #expect(
      Self.answers(evaluation).suffix(4)
        == ["8", "table.failedCell", "table.failedCell", "6"])
  }

  @Test func resourceLimitsSurfaceInResults() throws {
    let heavy = Self.table(
      "Heavy", headers: ["A", "B"], rows: [["1", "=A2 + 1"], ["2", "=A3 * 3 + 4"]])
    var run = try Run(
      calculator: SheetCalculator(
        tableOptions: TableCalculationOptions(
          maximumPopulatedCells: 100, maximumScalarOperations: 2)
      ))
    let evaluation = try run.evaluate(
      "1\n" + Self.block(heavy) + "Heavy!A2\n2 + 2\n")
    let block = try #require(evaluation.tables.first)
    #expect(block.projection != nil && block.calculation == nil)
    #expect(block.calculationFailure?.code == .resourceLimitExceeded)
    #expect(Self.answers(evaluation).suffix(2) == ["table.unavailableTable", "4"])
    // The failed generation is not recalculated while nothing it read changed.
    let again = try run.evaluate("1\n" + Self.block(heavy) + "Heavy!A2\n2 + 3\n")
    #expect(again.calculatedTables.isEmpty)
    #expect(again.tables.first?.calculationFailure?.code == .resourceLimitExceeded)
  }
}
