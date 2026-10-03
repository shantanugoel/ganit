import Foundation
import GanitDocuments
import GanitEngine
import GanitFormatting

/// An expression that did not produce an answer, carrying the engine's
/// diagnostics so a headless caller can explain itself.
public struct UnevaluableExpression: Error, LocalizedError, Equatable, Sendable {
  public let diagnostics: [FormattedDiagnostic]

  /// The first problem, which is the one a reader fixes first.
  public var errorDescription: String? {
    diagnostics.first?.message
  }
}

/// A sheet line's answer for a headless caller.
public struct SheetAnswer: Equatable, Sendable {
  /// The displayed answer or failure message, or `nil` without an expression.
  public let text: String?
  public let isFailure: Bool
}

/// One table block's structured output for a headless caller: the display
/// grid and where the block sits in the sheet's line order.
public struct TableSheetAnswer: Equatable, Sendable {
  /// The display grid, with failures as messages. A block Ganit cannot read
  /// has no name, headers or rows, and carries its diagnostics.
  public let grid: TableGrid
  /// The zero-based physical source line where output belongs: the block's
  /// last line. Cell values never become line answers.
  public let lastPhysicalLine: Int

  public init(grid: TableGrid, lastPhysicalLine: Int) {
    self.grid = grid
    self.lastPhysicalLine = lastPhysicalLine
  }
}

/// Evaluates one expression for callers outside the app's windows.
///
/// The Evaluate Expression service and the Calculate Expression intent share
/// this, so neither parses nor evaluates on its own. Source arrives from
/// another process, so it is bounded far below the editor's limits, and an
/// expression that cannot be answered reports why rather than returning
/// nothing.
public struct ExpressionCalculation: Sendable {
  /// The longest expression another process may send.
  public static let maximumSourceUTF8Length = 4_096

  private let preferences: SheetPreferences
  private let rates: CurrencyRates

  public init(
    preferences: SheetPreferences = .standard,
    rates: CurrencyRates = .none
  ) {
    self.preferences = preferences
    self.rates = rates
  }

  /// A calculation using the exchange rates the app last accepted, read from
  /// disk so a headless caller answers currency without the network and
  /// without the app's windows.
  public static func usingStoredRates() -> ExpressionCalculation {
    ExpressionCalculation(
      rates: (try? RateSnapshotStore.applicationSupport().lastKnownGood())?
        .flatMap(\.currencyRates) ?? .none
    )
  }

  /// One answer per line of a sheet, as the editor shows them once editing
  /// leaves each line: the display text or failure message, or `nil` for a
  /// line without an expression. This is the scalar output mode: a table
  /// line has no answer, and its values appear only in structured mode.
  public func answers(forSheet source: String, now: Date = Date()) throws -> [SheetAnswer] {
    try evaluate(source, now: now).lines
  }

  /// The scalar line answers and every table block's structured result, in
  /// source order. This is the structured output mode: a table's cells are
  /// named rows of its own grid at its block position, never line answers.
  public func structuredAnswers(forSheet source: String, now: Date = Date()) throws -> (
    lines: [SheetAnswer], tables: [TableSheetAnswer]
  ) {
    try evaluate(source, now: now)
  }

  private func evaluate(_ source: String, now: Date) throws -> (
    lines: [SheetAnswer], tables: [TableSheetAnswer]
  ) {
    let context = try preferences.evaluationContext(now: now, currencyRates: rates)
    var calculator = SheetCalculator()
    let formatter = ResultFormatter(context: context)
    let diagnostics = DiagnosticFormatter(context: context)
    let evaluation = try calculator.evaluate(SheetSource(source), context: context)
    let lines = try evaluation.lines.map { line in
      switch line.result {
      case .value(let value):
        return SheetAnswer(text: try formatter.format(value).display, isFailure: false)
      case .syntaxFailure(let problems):
        return SheetAnswer(
          text: problems.first.map { diagnostics.format($0).message }, isFailure: true)
      case .evaluationFailure(let error):
        return SheetAnswer(text: diagnostics.format(error).message, isFailure: true)
      case nil:
        return SheetAnswer(text: nil, isFailure: false)
      }
    }
    let tables = evaluation.tableResults.map { result in
      TableSheetAnswer(
        grid: TableGridText.grid(
          result, formatter: formatter, diagnostics: diagnostics, pending: "Pending…"),
        lastPhysicalLine: result.physicalLines.upperBound - 1)
    }
    return (lines, tables)
  }

  /// The answer to `source`, formatted as a sheet would display it. Source
  /// holding a table block, valid or not, is not one expression: it fails
  /// with an explanation instead of reading the block's lines as one.
  public func answer(for source: String, now: Date = Date()) throws -> String {
    let context = try preferences.evaluationContext(now: now, currencyRates: rates)
    if source.utf8.count <= Self.maximumSourceUTF8Length,
      TableSourceDocument.containsBlock(in: SheetSource(source))
    {
      throw UnevaluableExpression(
        diagnostics: [
          DiagnosticFormatter(context: context).format(
            EngineError(code: .tableReference, context: .tableReference(.expression)))
        ])
    }
    let engine = CalculationEngine(
      syntaxLimits: SyntaxLimits(
        maximumSourceUTF8Length: Self.maximumSourceUTF8Length
      )
    )
    switch engine.evaluate(source, context: context) {
    case .value(let value):
      return try ResultFormatter(context: context).format(value).display
    case .syntaxFailure(let diagnostics):
      let formatter = DiagnosticFormatter(context: context)
      throw UnevaluableExpression(diagnostics: diagnostics.map(formatter.format))
    case .evaluationFailure(let error):
      throw UnevaluableExpression(
        diagnostics: [DiagnosticFormatter(context: context).format(error)]
      )
    }
  }
}
