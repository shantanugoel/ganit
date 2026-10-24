import Foundation
import GanitSuggestionProtocol

/// The source comment keeps the origin of an assumed value.
public struct AIAssumption: Hashable, Sendable {
  public let basis: String
  public let model: String
  public let date: String

  public init(basis: String, model: String, date: String) {
    self.basis = basis
    self.model = model
    self.date = date
  }

  public var comment: String { "// AI: " + basis + " · " + model + " · " + date }

  public static func valueRange(in source: String) -> SourceRange? {
    guard case .calculation(_, .some, let range?, _) = LineSyntax(source) else { return nil }
    return range
  }

  public static func parse(_ source: String, context supplied: EvaluationContext? = nil) -> Self? {
    guard !source.contains("\n"), !source.contains("\r") else { return nil }
    return parse(source, syntax: LineSyntax(source), context: supplied)
  }

  /// The evaluator already classified the line, so it hands the syntax over
  /// instead of paying for a second parse of every line on every keystroke.
  static func parse(_ source: String, syntax: LineSyntax, context supplied: EvaluationContext?)
    -> Self?
  {
    guard case .calculation(_, .some, let valueRange?, let commentRange?) = syntax,
      let marker = commentRange.text(in: source), marker.hasPrefix("// AI: "),
      let text = valueRange.text(in: source)
    else { return nil }
    let fields = marker.dropFirst("// AI: ".count).components(separatedBy: " · ")
    let stamp = ISO8601DateFormatter()
    guard fields.count == 3,
      fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      fields[2].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
      let date = stamp.date(from: fields[2] + "T00:00:00Z"),
      String(stamp.string(from: date).prefix(10)) == fields[2],
      let context = supplied ?? defaultContext(),
      let expression = CalculationEngine().parse(String(text), context: context).expression,
      isPlainValue(expression)
    else { return nil }
    return Self(basis: fields[0], model: fields[1], date: fields[2])
  }

  package static func isPlainValue(_ expression: Expression) -> Bool {
    switch expression {
    case .literal: return true
    case .prefix(let operation, let child, _, _):
      return (operation == .plus || operation == .minus) && isSignedLiteral(child)
    case .quantity(let child, _, _): return isSignedLiteral(child)
    default: return false
    }
  }

  private static func isSignedLiteral(_ expression: Expression) -> Bool {
    switch expression {
    case .literal: return true
    case .prefix(let operation, let child, _, _):
      return (operation == .plus || operation == .minus) && isSignedLiteral(child)
    default: return false
    }
  }

  private static func defaultContext() -> EvaluationContext? {
    try? EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
  }
}

package struct AssistanceAssumptionDeclaration {
  let lineIndex: Int
  let range: SourceRange
  let value: EngineValue

  static func validate(
    _ candidate: SuggestionCandidate, snapshot: AssistanceSnapshot,
    evidence: [String: AssistanceEvidence]
  ) throws -> Self? {
    guard !candidate.assumptions.isEmpty else { return nil }
    guard candidate.assumptions.count == 1, let assumption = candidate.assumptions.first,
      assumption.id == "A1", evidence[assumption.evidence]?.kind == "relation",
      !assumption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !assumption.text.contains("\n"), !assumption.text.contains("\r"),
      !assumption.text.contains(" · ")
    else { throw invalid("Use one named world fact with a clear basis and task evidence.") }
    let claims = candidate.literals.filter { $0.evidence == assumption.id }
    guard claims.count == 1, let claim = claims.first,
      case .value(let value) = snapshot.scope.engine.evaluate(claim.text, context: snapshot.context)
    else { throw invalid("An assumption must identify one literal value.") }
    let source = SheetSource(candidate.edits[0].replacement)
    var matches: [Self] = []
    for (index, line) in source.lines.enumerated() {
      guard case .calculation(_, let nameRange?, let valueRange?, nil) = LineSyntax(line.text),
        let name = nameRange.text(in: line.text), let text = valueRange.text(in: line.text),
        let expression = snapshot.scope.engine.parse(String(text), context: snapshot.context)
          .expression,
        AIAssumption.isPlainValue(expression),
        case .value(let declared) = snapshot.scope.engine.evaluate(
          String(text), context: snapshot.context),
        assistanceLiteralValuesEqual(declared, value, context: snapshot.context),
        isWorldFact(basis: assumption.text, name: String(name), value: declared)
      else { continue }
      matches.append(
        Self(
          lineIndex: index,
          range: valueRange.shifted(
            by: SourceLocation(
              utf8Offset: line.range.lowerBound, graphemeOffset: line.range.graphemeLowerBound)),
          value: value))
    }
    guard matches.count == 1 else {
      throw invalid(
        "Declare the world fact as one named value on its own line. Ask for personal inputs.")
    }
    return matches[0]
  }

  /// The world-fact classes of §6 that Ganit can verify, each with the
  /// dimension its value must carry. The basis alone decides the class: a
  /// declared name is what the model chose, so it can veto a personal input but
  /// it cannot make a vague basis into a world fact. Anything Ganit cannot
  /// place asks instead, which is what §6 asks of an uncertain classification.
  private enum WorldFactKind {
    case density, acceleration, speed
  }

  private static let worldFactClasses: [(words: [String], kind: WorldFactKind)] = [
    (words: ["density"], kind: .density),
    (words: ["gravity", "gravitational acceleration", "free fall"], kind: .acceleration),
    (
      words: [
        "speed of light", "walking speed", "running speed", "cycling speed", "speed of sound",
      ],
      kind: .speed,
    ),
  ]

  private static func isWorldFact(basis: String, name: String, value: EngineValue) -> Bool {
    let veto = (basis + " " + name).lowercased()
    let personal = [
      "tax", "salary", "budget", "rent", "mortgage", "loan", "interest", "currency", "price",
      "cost", "income", "discount", "payment",
    ]
    guard !personal.contains(where: veto.contains) else { return false }
    let words = basis.lowercased()
    for candidate in worldFactClasses where candidate.words.contains(where: words.contains) {
      return matches(candidate.kind, value)
    }
    return false
  }

  private static func matches(_ kind: WorldFactKind, _ value: EngineValue) -> Bool {
    guard case .quantity(let quantity) = value else { return false }
    let expected: Dimension?
    switch kind {
    case .density: expected = try? Dimension(.mass).divided(by: Dimension(.length).raised(to: 3))
    case .acceleration:
      expected = try? Dimension(.length).divided(by: Dimension(.time).raised(to: 2))
    case .speed: expected = try? Dimension(.length).divided(by: Dimension(.time))
    }
    guard let expected else { return false }
    return quantity.unit.dimension == expected
  }

  private static func invalid(_ message: String) -> AssistanceValidationFailure {
    AssistanceValidationFailure(.missingEvidence, message, concernsAssumption: true)
  }
}
