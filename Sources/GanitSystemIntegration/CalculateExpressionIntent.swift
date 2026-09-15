import AppIntents
import Foundation

/// Calculate Expression, the action Shortcuts offers.
///
/// The intent answers in the background without opening a window, using the
/// same engine, grammar, and formatting a sheet uses. It returns one answer
/// and never a guess: an expression that cannot be evaluated fails with the
/// engine's explanation.
public struct CalculateExpressionIntent: AppIntent {
  public static let title: LocalizedStringResource = "Calculate Expression"

  public static let description = IntentDescription(
    "Answers one Ganit expression, such as 20% off 85 USD or 12 km in miles.",
    categoryName: "Calculate"
  )

  public static let openAppWhenRun = false

  @Parameter(
    title: "Expression",
    description: "The expression to answer, written as you would in a sheet."
  )
  public var expression: String

  public init() {}

  public init(expression: String) {
    self.expression = expression
  }

  public func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try ExpressionCalculation.usingStoredRates().answer(for: expression))
  }
}
