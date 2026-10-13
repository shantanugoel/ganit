import Foundation

public struct AssistanceEvidence: Encodable, Sendable {
  public let handle: String
  public let source: String
  public let text: String
  public let kind: String
  let value: EngineValue?
  let temporal: TemporalLiteral?

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: Key.self)
    try fields.encode(handle, forKey: .handle)
    try fields.encode(source, forKey: .source)
    try fields.encode(text, forKey: .text)
    try fields.encode(kind, forKey: .kind)
    try fields.encodeIfPresent(value.map(AssistanceValue.init), forKey: .canonical)
  }
  private enum Key: String, CodingKey { case handle, source, text, kind, canonical }
}

extension AssistanceSnapshot {
  /// A small, versioned conversion rule. Other number words need clarification.
  public static let englishNumbers: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
  ]

  public func evidence(including handles: Set<String> = []) -> [AssistanceEvidence] {
    var records: [AssistanceEvidence] = []
    var sources = [("T1", target.text)]
    sources += notes.enumerated().filter { !$0.element.historical }.map {
      ("N\($0.offset + 1)", $0.element.source)
    }
    sources += inventory.filter {
      !$0.unreviewed && ($0.matchesTarget || handles.contains($0.handle))
    }
    .compactMap { symbol in symbol.declaration.map { (symbol.handle, $0.text) } }
    func append(
      source: String, text: String, kind: String, value: EngineValue? = nil,
      temporal: TemporalLiteral? = nil
    ) {
      records.append(
        AssistanceEvidence(
          handle: "E\(records.count + 1)", source: source, text: text, kind: kind, value: value,
          temporal: temporal))
    }
    for (handle, text) in sources {
      let tokens = Lexer(source: text, configuration: context.lexingConfiguration).lex().tokens
      for (index, token) in tokens.enumerated() {
        switch token.kind {
        case .number(let number):
          var range = token.range
          var expression = Expression.literal(number, range: token.range)
          if index + 1 < tokens.count, tokens[index + 1].kind == .percent {
            range = range.union(tokens[index + 1].range)
            expression = .percentage(
              points: expression, percentRange: tokens[index + 1].range, range: range)
          }
          guard let literal = range.text(in: text).map(String.init),
            case .value(let value) = scope.engine.evaluate(
              expression, context: context, variables: [:], lines: LineOutcomes()
            ).result
          else { continue }
          append(source: handle, text: literal, kind: "literal", value: value)
          // Inspect small native parse spans for an attached currency or unit.
          let first =
            index > 0
              && {
                if case .currencySymbol = tokens[index - 1].kind { return true }
                return false
              }() ? index - 1 : index
          for last in index..<min(tokens.count, index + 8) {
            let span = tokens[first].range.union(tokens[last].range)
            guard let textValue = span.text(in: text).map(String.init),
              let parsed = scope.engine.parse(
                textValue, context: context,
                variables: scope.names.mapValues { $0?.kind ?? .number }
              ).expression
            else { continue }
            let operand: Expression
            switch parsed {
            case .quantity(let amount, _, _), .money(let amount, _, _): operand = amount
            default: continue
            }
            guard AssistanceExpressionFacts.isPrimitive(operand),
              case .value(let wrapped) = scope.engine.evaluate(
                parsed, context: context, variables: [:], lines: LineOutcomes()
              ).result
            else { continue }
            append(source: handle, text: textValue, kind: "literal", value: wrapped)
          }
        case .identifier(let word):
          if let number = scope.engine.assistanceScaleEvidence(
            token: token,
            previous: index > 0 ? tokens[index - 1] : nil, source: text, context: context,
            variables: scope.names.mapValues { $0?.kind ?? .number })
          {
            append(
              source: handle, text: token.range.text(in: text).map(String.init) ?? word,
              kind: "literal", value: .number(.integer(number)))
          }
          if let number = Self.englishNumbers[word.lowercased()] {
            append(
              source: handle, text: token.range.text(in: text).map(String.init) ?? word,
              kind: "literal", value: .number(.integer(IntegerValue(number))))
          }
          if case .temporal(let temporal, _) = scope.engine.parse(word, context: context).expression,
            case .value(let value) = scope.engine.evaluate(word, context: context)
          {
            append(
              source: handle, text: token.range.text(in: text).map(String.init) ?? word,
              kind: "temporal", value: value, temporal: temporal)
          }
        case .temporal(let temporal):
          let literal = token.range.text(in: text).map(String.init) ?? ""
          if case .value(let value) = scope.engine.evaluate(literal, context: context) {
            append(
              source: handle, text: literal, kind: "temporal", value: value, temporal: temporal)
          }
        default: break
        }
      }
      append(source: handle, text: text, kind: "relation")
    }
    return records
  }
}
