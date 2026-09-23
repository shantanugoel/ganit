/// How a markdown sheet decides whether a line is a calculation or a paragraph.
enum MarkdownLines {
  /// Turns a line that is only words into a paragraph, and skips leading
  /// words so `The cost is 100 + 50` still calculates.
  static func adjusted(
    _ syntax: LineSyntax,
    text: String,
    engine: CalculationEngine,
    context: EvaluationContext
  ) -> LineSyntax {
    guard
      case .calculation(let label, let name, let expression?, let comment) = syntax
    else {
      return syntax
    }
    var slice = Self.slice(of: expression, in: text)
    // A list item or quote is its words: `- 2 + 3` is 2 + 3, not -2 + 3.
    let marker = listMarker(in: slice)
    slice.removeFirst(marker.count)
    let origin = SourceLocation(
      utf8Offset: expression.lowerBound + marker.utf8.count,
      graphemeOffset: expression.graphemeLowerBound + marker.count
    )
    if let kept = calculationRange(
      in: slice,
      origin: origin,
      engine: engine,
      context: context
    ) {
      return .calculation(label: label, name: name, expression: kept, comment: comment)
    }
    // A spaced operator is arithmetic, not prose, so a mistyped calculation
    // shows its problem instead of quietly becoming a paragraph.
    if name != nil || hasSpacedOperator(slice) {
      return syntax
    }
    return .markdown
  }

  /// A leading `- `, `* `, `+ `, `> `, or `1. ` and the spaces after it, or
  /// an empty string.
  private static func listMarker(in text: String) -> Substring {
    let digits = text.prefix(while: \.isASCII).prefix(while: \.isNumber)
    let marker =
      !digits.isEmpty && text.dropFirst(digits.count).first == "."
      ? text.prefix(digits.count + 1) : text.prefix(1)
    guard ["-", "*", "+", ">"].contains(marker) || marker.hasSuffix("."),
      let space = text.dropFirst(marker.count).first, space == " " || space == "\t"
    else {
      return ""
    }
    let spaces = text.dropFirst(marker.count).prefix { $0 == " " || $0 == "\t" }
    return text.prefix(marker.count + spaces.count)
  }

  /// ` + `, ` * `, ` / `, ` ^ `, or ` = `. A spaced `-` is a dash in prose.
  private static func hasSpacedOperator(_ text: String) -> Bool {
    ["+", "*", "×", "/", "÷", "^", "="].contains { text.contains(" \($0) ") }
  }

  /// The range to evaluate, or `nil` when the text is a markdown paragraph.
  static func calculationRange(
    in source: String,
    origin: SourceLocation,
    engine: CalculationEngine,
    context: EvaluationContext
  ) -> SourceRange? {
    let parsing = engine.parse(source, context: context, origin: origin)
    if parsing.diagnostics.isEmpty, let expression = parsing.expression,
      !isBareProse(expression)
    {
      return expression.range
    }

    let tokens = Lexer(source: source, configuration: context.lexingConfiguration, origin: origin)
      .lex().tokens.filter { $0.kind != .endOfFile && $0.kind != .newline }
    var start = 0
    while start < tokens.count, isSkippable(tokens[start]) {
      start += 1
      guard start < tokens.count, isCalculationStart(tokens[start]) else {
        continue
      }
      let utf8Start = tokens[start].range.lowerBound - origin.utf8Offset
      let remainder = slice(from: utf8Start, in: source)
      let nextOrigin = SourceLocation(
        utf8Offset: tokens[start].range.lowerBound,
        graphemeOffset: tokens[start].range.graphemeLowerBound
      )
      let skipped = engine.parse(remainder, context: context, origin: nextOrigin)
      if skipped.diagnostics.isEmpty, let expression = skipped.expression,
        !isBareProse(expression)
      {
        return expression.range
      }
    }
    return nil
  }

  private static func isBareProse(_ expression: Expression) -> Bool {
    // `Wow!` is a word with a mark, not the factorial of a word.
    if case .call(let name, _, let arguments, _) = expression,
      name == BuiltInFunction.factorial.rawValue, arguments.count == 1
    {
      return isBareProse(arguments[0])
    }
    guard case .identifier(let name, _) = expression else {
      return false
    }
    return !isCalculationWord(name)
  }

  private static func isSkippable(_ token: Token) -> Bool {
    guard case .identifier(let name) = token.kind else {
      return false
    }
    return !isCalculationWord(name)
  }

  private static func isCalculationStart(_ token: Token) -> Bool {
    switch token.kind {
    case .number, .currencySymbol, .leftParenthesis, .temporal:
      return true
    case .identifier(let name):
      return isCalculationWord(name)
    default:
      return false
    }
  }

  private static func isCalculationWord(_ name: String) -> Bool {
    referenceKeywords[name] != nil
      || BuiltInFunction(rawValue: name) != nil
      || FinanceFunction(rawValue: name) != nil
      || name == assistantFunctionName
      || CurrencyCatalog.minorUnits[name.uppercased()] != nil
      || CurrencyCatalog.names[name.lowercased()] != nil
      || ScaleWord.digits[name.lowercased()] != nil
      || CalendarPeriodUnit(word: name) != nil
      || builtInMinimalUnitCatalog.resolveUnit(matching: name) != nil
      || ["pi", "π", "e", "now", "today", "tomorrow", "yesterday"].contains(name)
  }

  private static func slice(of range: SourceRange, in text: String) -> String {
    slice(from: range.lowerBound, length: range.utf8Length, in: text)
  }

  private static func slice(from utf8Offset: Int, in text: String) -> String {
    let utf8 = text.utf8
    let lower = utf8.index(utf8.startIndex, offsetBy: min(max(utf8Offset, 0), utf8.count))
    return String(text[lower...])
  }

  private static func slice(from utf8Offset: Int, length: Int, in text: String) -> String {
    let utf8 = text.utf8
    let lower = utf8.index(utf8.startIndex, offsetBy: min(utf8Offset, utf8.count))
    let upper = utf8.index(
      lower, offsetBy: min(length, utf8.distance(from: lower, to: utf8.endIndex)))
    return String(text[lower..<upper])
  }
}
