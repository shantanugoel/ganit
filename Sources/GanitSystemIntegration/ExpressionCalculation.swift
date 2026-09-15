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
  /// line without an expression.
  public func answers(forSheet source: String, now: Date = Date()) throws -> [SheetAnswer] {
    let context = try preferences.evaluationContext(now: now, currencyRates: rates)
    var calculator = SheetCalculator()
    let formatter = ResultFormatter(context: context)
    let diagnostics = DiagnosticFormatter(context: context)
    return try calculator.evaluate(SheetSource(source), context: context).lines.map { line in
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
  }

  /// The answer to `source`, formatted as a sheet would display it.
  public func answer(for source: String, now: Date = Date()) throws -> String {
    let context = try preferences.evaluationContext(now: now, currencyRates: rates)
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
