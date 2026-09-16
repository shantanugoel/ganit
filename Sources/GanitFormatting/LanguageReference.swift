import Foundation
import GanitEngine

/// One entry in the in-app grammar and function reference.
public struct LanguageTopic: Equatable, Sendable, Identifiable {
  public enum Category: String, Equatable, Sendable, CaseIterable {
    case grammar
    case functions
    case keywords
  }

  public let id: String
  public let category: Category
  public let title: String
  public let signature: String?
  public let summary: String
  public let body: String
  public let examples: [String]
  public let keywords: [String]

  public var searchText: String {
    ([id, title, signature, summary, body] + examples + keywords)
      .compactMap { $0 }
      .joined(separator: "\n")
      .lowercased()
  }

  public func matches(_ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else {
      return true
    }
    return needle.split(whereSeparator: \.isWhitespace).allSatisfy { word in
      searchText.contains(word)
    }
  }
}

/// The searchable grammar, function, and keyword reference. Help, hover text,
/// and completions all read this list, so a name has one meaning in the app.
public enum LanguageReference {
  public static let topics: [LanguageTopic] = grammar + functions + keywords

  public static func topic(id: String) -> LanguageTopic? {
    topics.first { $0.id == id }
  }

  /// The topic for a written function or keyword name, such as `sqrt` or `sum`.
  public static func topic(named name: String) -> LanguageTopic? {
    let key = name.lowercased()
    if let exact = topics.first(where: {
      $0.title.lowercased() == key
        || $0.id == "function.\(key)"
        || $0.id == "keyword.\(key)"
    }) {
      return exact
    }
    return topics.first { topic in
      topic.keywords.contains { $0.lowercased() == key }
    }
  }

  public static func topics(matching query: String) -> [LanguageTopic] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
      return topics
    }
    return topics.filter { $0.matches(needle) }
  }

  public static func topics(in category: LanguageTopic.Category) -> [LanguageTopic] {
    topics.filter { $0.category == category }
  }
}

extension LanguageReference {
  fileprivate static let grammar: [LanguageTopic] = [
    topic(
      id: "grammar.lines",
      category: .grammar,
      title: text("help.grammar.lines.title", "Lines"),
      summary: text(
        "help.grammar.lines.summary",
        "Each line is one calculation, heading, comment, divider, or markdown paragraph."
      ),
      body: text(
        "help.grammar.lines.body",
        "Write one calculation to a line. The answer appears beside it, or in the line in Markdown Mode. A label is a name followed by a colon. # starts a heading, // a comment, and --- a divider. Comments, headings, and markdown paragraphs have no answer. In Markdown Mode, sentences are paragraphs, and a calculation can follow them: The cost is 100 + 50. => ends a calculation, Calca-style."
      ),
      examples: ["Rent: 2,100 // shared", "# Trip", "---"],
      keywords: ["heading", "comment", "divider", "label"]
    ),
    topic(
      id: "grammar.arithmetic",
      category: .grammar,
      title: text("help.grammar.arithmetic.title", "Arithmetic"),
      summary: text(
        "help.grammar.arithmetic.summary",
        "Ordinary operators, grouping, powers, and function calls."
      ),
      body: text(
        "help.grammar.arithmetic.body",
        "+, -, *, /, and ^ are the operators. Parentheses group. Powers bind tightest and associate to the right, so -2^2 is -(2^2). Implicit multiplication is only for adjacent tokens such as 2π or 2(3+4). Integers, decimals, scientific notation, and 0b, 0o, 0x literals are exact until a step has to approximate."
      ),
      examples: ["(2 + 3) * 4", "2^10", "0xff + 1", "2π"],
      keywords: ["operators", "power", "hex", "scientific"]
    ),
    topic(
      id: "grammar.percentages",
      category: .grammar,
      title: text("help.grammar.percentages.title", "Percentages"),
      summary: text(
        "help.grammar.percentages.summary",
        "Percent phrases keep the kind of the amount they scale."
      ),
      body: text(
        "help.grammar.percentages.body",
        "20% of 85 is 17, 20% off 85 is 68, and 85 + 20% is 102. 50 is what % of 200 is 25%. percentage change from 50 to 90 is 80%. 0.25 as % shows a ratio as 25%. A percentage of a quantity keeps the unit: 10% of 50 kg is 5 kg. Absolute quantities such as temperatures refuse a percentage of, because a tenth of 20 °C is not a temperature."
      ),
      examples: ["20% off 85", "15 is what % of 60", "10% of 50 kg", "3050 / 7500 as %"],
      keywords: ["percent", "off", "tip", "change", "ratio"]
    ),
    topic(
      id: "grammar.units",
      category: .grammar,
      title: text("help.grammar.units.title", "Units"),
      summary: text(
        "help.grammar.units.summary",
        "Quantities convert and combine by dimension."
      ),
      body: text(
        "help.grammar.units.body",
        "Write a number and a unit, or a unit and a number: 12 km and km 12. Convert with in, to, as, or into: 12 km in miles. Compatible units add; incompatible ones say so. Compound units multiply and divide: 75 MB/s * 2 s. Temperature converts on its scale: 0 °C as °F."
      ),
      examples: ["12 km in miles", "km 12", "75 MB/s * 2 s", "0 °C as °F"],
      keywords: ["conversion", "length", "mass", "data"]
    ),
    topic(
      id: "grammar.variables",
      category: .grammar,
      title: text("help.grammar.variables.title", "Variables"),
      summary: text(
        "help.grammar.variables.summary",
        "A name equals a value, and later lines can use the name."
      ),
      body: text(
        "help.grammar.variables.body",
        "monthly rent = 2,100 names the value. Names may contain spaces. A later line that writes monthly rent * 12 uses it. Function names and grammatical words cannot be variable names."
      ),
      examples: ["monthly rent = 2,100", "monthly rent * 12"],
      keywords: ["name", "assignment", "equals"]
    ),
    topic(
      id: "grammar.references",
      category: .grammar,
      title: text("help.grammar.references.title", "References and totals"),
      summary: text(
        "help.grammar.references.summary",
        "Lines can use answers above them, and totals add those answers."
      ),
      body: text(
        "help.grammar.references.body",
        "line 2 is the answer of line 2, and previous is the answer of the line above. sum and total add every result above. subtotal adds from the last divider or heading. average, median, and count do what they say to those results."
      ),
      examples: ["line 2 * 3", "previous", "subtotal"],
      keywords: ["line", "previous", "sum", "total", "average"]
    ),
    topic(
      id: "grammar.definitions",
      category: .grammar,
      title: text("help.grammar.definitions.title", "Definitions"),
      summary: text(
        "help.grammar.definitions.summary",
        "Shared names and custom units every sheet can read."
      ),
      body: text(
        "help.grammar.definitions.body",
        "Window ▸ Definitions is one sheet of names and units that every calculation reads: hourly rate = 90, or 1 bag = 25 kg. A sheet's own names still win when they collide."
      ),
      examples: ["hourly rate = 90", "1 bag = 25 kg"],
      keywords: ["custom unit", "shared"]
    ),
    topic(
      id: "grammar.dates",
      category: .grammar,
      title: text("help.grammar.dates.title", "Dates and times"),
      summary: text(
        "help.grammar.dates.summary",
        "Calendar dates, times of day, and time zones."
      ),
      body: text(
        "help.grammar.dates.body",
        "today, tomorrow, yesterday, and now follow the clock. Dates add whole calendar periods: today + 3 months. An instant can be shown in a zone: now in Tokyo. A calendar day is not a duration of 24 hours, so 1 day in hours is refused; 24 h in min converts a duration."
      ),
      examples: ["today + 3 months", "2024-03-09T12:00 Europe/London", "now in Tokyo"],
      keywords: ["today", "now", "timezone", "calendar"]
    ),
    topic(
      id: "grammar.money",
      category: .grammar,
      title: text("help.grammar.money.title", "Money"),
      summary: text(
        "help.grammar.money.summary",
        "Amounts keep their currency; conversions use a named rate."
      ),
      body: text(
        "help.grammar.money.body",
        "12.50 EUR, EUR 12.50, €5, and 5€ are money. $ is USD unless Format ▸ Dollar Means or the sheet's right-click menu picks another dollar currency. USD 1.5, 5 dollars, dollars 5, and 11.5 million are the same kinds of amount. ¥ is yen. 100 USD in INR converts with the European Central Bank daily rates, or a rate you declare: 1 USD = 83 INR. Automatic downloads can be turned off."
      ),
      examples: ["$1.5", "USD 1.5", "11.5 million", "12.50 EUR", "100 USD in INR"],
      keywords: ["currency", "exchange", "EUR", "USD"]
    ),
    topic(
      id: "grammar.constants",
      category: .grammar,
      title: text("help.grammar.constants.title", "Constants"),
      summary: text(
        "help.grammar.constants.summary",
        "π, pi, and e are approximate mathematical constants."
      ),
      body: text(
        "help.grammar.constants.body",
        "π and pi are the same constant. e is the base of the natural logarithm. Answers that used them are marked approximate, because they are not exact fractions."
      ),
      examples: ["π", "2 * pi", "exp(1)"],
      keywords: ["pi", "π", "e"]
    ),
  ]

  fileprivate static var functions: [LanguageTopic] {
    BuiltInFunction.allCases.map(functionTopic) + FinanceFunction.allCases.map(financeTopic)
      + AssistantFunction.allCases.map(assistantTopic)
  }

  fileprivate static let keywords: [LanguageTopic] = [
    keyword(
      "previous",
      aliases: ["prev"],
      summary: text("help.keyword.previous.summary", "The answer of the line above."),
      body: text(
        "help.keyword.previous.body",
        "previous, or prev, is the result of the nearest calculation above this line."
      ),
      examples: ["previous * 2"]
    ),
    keyword(
      "sum",
      aliases: ["total"],
      summary: text("help.keyword.sum.summary", "Adds every result above this line."),
      body: text(
        "help.keyword.sum.body",
        "sum and total add the answers above, skipping headings, comments, and dividers."
      ),
      examples: ["sum", "total"]
    ),
    keyword(
      "subtotal",
      summary: text(
        "help.keyword.subtotal.summary",
        "Adds results above this line, back to the last divider or heading."
      ),
      body: text(
        "help.keyword.subtotal.body",
        "subtotal is a running total for the current section. Insert one from Calculate ▸ Insert Subtotal."
      ),
      examples: ["subtotal"]
    ),
    keyword(
      "average",
      aliases: ["avg"],
      summary: text("help.keyword.average.summary", "The mean of the results above this line."),
      body: text(
        "help.keyword.average.body",
        "average, or avg, is the arithmetic mean of the answers above."
      ),
      examples: ["average"]
    ),
    keyword(
      "median",
      summary: text("help.keyword.median.summary", "The median of the results above this line."),
      body: text(
        "help.keyword.median.body",
        "median is the middle value of the answers above, once they are ordered."
      ),
      examples: ["median"]
    ),
    keyword(
      "count",
      summary: text("help.keyword.count.summary", "How many results sit above this line."),
      body: text(
        "help.keyword.count.body",
        "count is the number of answers above, not including headings, comments, or dividers."
      ),
      examples: ["count"]
    ),
    keyword(
      "line",
      summary: text("help.keyword.line.summary", "The answer of a numbered line above."),
      body: text(
        "help.keyword.line.body",
        "line 2 is the answer of the second line. The line must be above this one. Calculate ▸ Insert Reference writes it for the selected answer."
      ),
      examples: ["line 2 * 3"]
    ),
  ]

  fileprivate static func functionTopic(_ function: BuiltInFunction) -> LanguageTopic {
    switch function {
    case .absoluteValue:
      return functionHelp(
        "abs", signature: "abs(x)",
        summary: text("help.function.abs.summary", "The absolute value."),
        body: text("help.function.abs.body", "abs(x) is x without its sign."),
        examples: ["abs(-3)"]
      )
    case .minimum:
      return functionHelp(
        "min", signature: "min(x, y, ...)",
        summary: text("help.function.min.summary", "The smallest of two or more numbers."),
        body: text(
          "help.function.min.body",
          "min takes at least two arguments and returns the smallest. Exact values stay exact."
        ),
        examples: ["min(1.00, 1)", "min(-2, 3, 1)"]
      )
    case .maximum:
      return functionHelp(
        "max", signature: "max(x, y, ...)",
        summary: text("help.function.max.summary", "The largest of two or more numbers."),
        body: text(
          "help.function.max.body",
          "max takes at least two arguments and returns the largest."
        ),
        examples: ["max(-2, 3, 1)"]
      )
    case .round:
      return functionHelp(
        "round", signature: "round(x, places?)",
        summary: text(
          "help.function.round.summary",
          "Rounds to a whole number, or to a number of decimal places."
        ),
        body: text(
          "help.function.round.body",
          "round(x) uses the sheet's rounding rule. round(x, 2) keeps two digits after the decimal, including trailing zeroes. Half values follow that rule rather than a hidden convention."
        ),
        examples: ["round(2.5)", "round(1/3, 2)"]
      )
    case .floor:
      return functionHelp(
        "floor", signature: "floor(x)",
        summary: text(
          "help.function.floor.summary", "The greatest integer less than or equal to x."),
        body: text(
          "help.function.floor.body",
          "floor always goes toward negative infinity, regardless of the sheet's rounding rule."
        ),
        examples: ["floor(-3/2)"]
      )
    case .ceiling:
      return functionHelp(
        "ceil", signature: "ceil(x)",
        summary: text(
          "help.function.ceil.summary", "The least integer greater than or equal to x."),
        body: text(
          "help.function.ceil.body",
          "ceil always goes toward positive infinity, regardless of the sheet's rounding rule."
        ),
        examples: ["ceil(-3/2)"]
      )
    case .squareRoot:
      return functionHelp(
        "sqrt", signature: "sqrt(x)",
        summary: text("help.function.sqrt.summary", "The square root; the same as root(x, 2)."),
        body: text(
          "help.function.sqrt.body",
          "A perfect square stays exact. Other roots are marked approximate. Even roots of negative values are refused."
        ),
        examples: ["sqrt(144)", "sqrt(2)"]
      )
    case .root:
      return functionHelp(
        "root", signature: "root(x, n)",
        summary: text("help.function.root.summary", "The nth root of x."),
        body: text(
          "help.function.root.body",
          "n must be a positive whole number. Odd roots keep the sign. Even roots of negative values are refused."
        ),
        examples: ["root(-8, 3)", "root(16, 4)"]
      )
    case .sine:
      return trig("sin", inverse: false)
    case .cosine:
      return trig("cos", inverse: false)
    case .tangent:
      return trig("tan", inverse: false)
    case .arcSine:
      return trig("asin", inverse: true)
    case .arcCosine:
      return trig("acos", inverse: true)
    case .arcTangent:
      return trig("atan", inverse: true)
    case .naturalLogarithm:
      return functionHelp(
        "ln", signature: "ln(x)",
        summary: text("help.function.ln.summary", "The natural logarithm."),
        body: text(
          "help.function.ln.body",
          "ln(x) is log base e. x must be positive. The result is approximate."
        ),
        examples: ["ln(e)"]
      )
    case .commonLogarithm:
      return functionHelp(
        "log", signature: "log(x)",
        summary: text("help.function.log.summary", "The base-10 logarithm."),
        body: text(
          "help.function.log.body",
          "log(x) and log10(x) are the same function. x must be positive. The result is approximate."
        ),
        examples: ["log(1000)", "log10(100)"],
        keywords: ["log10"]
      )
    case .commonLogarithmExplicit:
      return functionHelp(
        "log10", signature: "log10(x)",
        summary: text("help.function.log10.summary", "The base-10 logarithm."),
        body: text(
          "help.function.log10.body",
          "log10(x) is the same as log(x)."
        ),
        examples: ["log10(100)"]
      )
    case .exponential:
      return functionHelp(
        "exp", signature: "exp(x)",
        summary: text("help.function.exp.summary", "e raised to the power x."),
        body: text(
          "help.function.exp.body",
          "exp(x) is e^x. The result is approximate."
        ),
        examples: ["exp(1)"]
      )
    case .binaryLogarithm:
      return functionHelp(
        "log2", signature: "log2(x)",
        summary: text("help.function.log2.summary", "The base-2 logarithm."),
        body: text(
          "help.function.log2.body",
          "log2(x) is the power of two that makes x. x must be positive. The result is approximate."
        ),
        examples: ["log2(8)"]
      )
    case .cubeRoot:
      return functionHelp(
        "cbrt", signature: "cbrt(x)",
        summary: text("help.function.cbrt.summary", "The cube root; the same as root(x, 3)."),
        body: text(
          "help.function.cbrt.body",
          "A perfect cube stays exact. Other roots are marked approximate."
        ),
        examples: ["cbrt(27)"]
      )
    case .truncate:
      return functionHelp(
        "trunc", signature: "trunc(x)",
        summary: text("help.function.trunc.summary", "Drops the fractional part toward zero."),
        body: text(
          "help.function.trunc.body",
          "trunc(1.9) is 1 and trunc(-1.9) is -1. It ignores the sheet's rounding rule."
        ),
        examples: ["trunc(-1.9)"]
      )
    case .sign:
      return functionHelp(
        "sign", signature: "sign(x)",
        summary: text("help.function.sign.summary", "−1, 0, or 1 according to the sign of x."),
        body: text(
          "help.function.sign.body",
          "sign is 0 at zero, −1 when x is negative, and 1 when x is positive."
        ),
        examples: ["sign(-4)"]
      )
    case .arcTangent2:
      return functionHelp(
        "atan2", signature: "atan2(y, x)",
        summary: text(
          "help.function.atan2.summary", "The angle of the point (x, y) from the positive x-axis."
        ),
        body: text(
          "help.function.atan2.body",
          "atan2(y, x) uses the sheet's angle mode. The result is approximate. Both arguments zero is refused."
        ),
        examples: ["atan2(1, 1)"]
      )
    case .hypot:
      return functionHelp(
        "hypot", signature: "hypot(x, y)",
        summary: text("help.function.hypot.summary", "The hypotenuse; sqrt(x² + y²)."),
        body: text(
          "help.function.hypot.body",
          "A perfect Pythagorean pair stays exact, such as hypot(3, 4)."
        ),
        examples: ["hypot(3, 4)"]
      )
    case .clamp:
      return functionHelp(
        "clamp", signature: "clamp(x, low, high)",
        summary: text("help.function.clamp.summary", "x limited to the range low…high."),
        body: text(
          "help.function.clamp.body",
          "clamp(x, low, high) is low if x is below it, high if x is above it, and x otherwise. low must not exceed high."
        ),
        examples: ["clamp(26, 5, 25)"]
      )
    case .factorial:
      return functionHelp(
        "fact", signature: "fact(n)",
        summary: text("help.function.fact.summary", "n × (n − 1) × … × 1 for a whole n ≥ 0."),
        body: text(
          "help.function.fact.body",
          "fact(0) is 1. A negative or fractional n is refused. There is no postfix !."
        ),
        examples: ["fact(5)"]
      )
    case .remainder:
      return functionHelp(
        "mod", signature: "mod(a, b)",
        summary: text("help.function.mod.summary", "The remainder of a divided by b, toward zero."),
        body: text(
          "help.function.mod.body",
          "mod(a, b) is a − b × trunc(a / b). Dividing by zero is refused."
        ),
        examples: ["mod(7, 3)"]
      )
    }
  }

  fileprivate static func assistantTopic(_ function: AssistantFunction) -> LanguageTopic {
    functionHelp(
      function.rawValue, signature: "\(function.rawValue)(prompt)",
      summary: text(
        "help.function.ask_assistant.summary",
        "Asks the configured assistant and uses its answer as a value."
      ),
      body: text(
        "help.function.ask_assistant.body",
        "The text inside the parentheses is the prompt, not an expression. The assistant must be turned on under Ganit ▸ Assistant…. Its answer is parsed as a Ganit value, so later lines can calculate with it. prompt_assistant is the same function."
      ),
      examples: ["ask_assistant(10 kg of water in ml)"],
      keywords: AssistantFunction.allCases.map(\.rawValue)
    )
  }

  fileprivate static func financeTopic(_ function: FinanceFunction) -> LanguageTopic {
    switch function {
    case .futureValue:
      return functionHelp(
        "fv", signature: "fv(amount, rate, periods)",
        summary: text(
          "help.function.fv.summary",
          "What an amount grows to at a rate for a number of periods."
        ),
        body: text(
          "help.function.fv.body",
          "fv(amount, rate, periods) is amount × (1 + rate)^periods. The rate is for one period, not a year. Money stays in its currency. The interpretation card records the compounding assumption."
        ),
        examples: ["fv(10,000 USD, 5%, 10)"]
      )
    case .presentValue:
      return functionHelp(
        "pv", signature: "pv(amount, rate, periods)",
        summary: text(
          "help.function.pv.summary",
          "What a later amount is worth now."
        ),
        body: text(
          "help.function.pv.body",
          "pv(amount, rate, periods) is amount ÷ (1 + rate)^periods. The rate is for one period."
        ),
        examples: ["pv(1,210, 10%, 2)"]
      )
    case .payment:
      return functionHelp(
        "pmt", signature: "pmt(amount, rate, periods)",
        summary: text(
          "help.function.pmt.summary",
          "The equal payment that repays an amount."
        ),
        body: text(
          "help.function.pmt.body",
          "pmt(amount, rate, periods) is the payment at the end of each period. Write an annual rate as a per-period rate: pmt(300,000 USD, 6% / 12, 360). A rate of zero splits the amount equally."
        ),
        examples: ["pmt(300,000 USD, 0.5%, 360)"]
      )
    }
  }

  fileprivate static func trig(_ name: String, inverse: Bool) -> LanguageTopic {
    functionHelp(
      name, signature: "\(name)(x)",
      summary: inverse
        ? text("help.function.inverseTrig.summary", "An inverse trigonometric function.")
        : text("help.function.trig.summary", "A trigonometric function."),
      body: inverse
        ? text(
          "help.function.inverseTrig.body",
          "asin, acos, and atan return an angle in the sheet's angle mode. The result is approximate."
        )
        : text(
          "help.function.trig.body",
          "sin, cos, and tan read a bare number in the sheet's angle mode, and an angle in its own unit: sin(30°) is 0.5. The result is approximate."
        ),
      examples: inverse ? ["asin(1)"] : ["sin(30°)", "sin(pi / 2)"]
    )
  }

  fileprivate static func topic(
    id: String,
    category: LanguageTopic.Category,
    title: String,
    signature: String? = nil,
    summary: String,
    body: String,
    examples: [String],
    keywords: [String]
  ) -> LanguageTopic {
    LanguageTopic(
      id: id,
      category: category,
      title: title,
      signature: signature,
      summary: summary,
      body: body,
      examples: examples,
      keywords: keywords
    )
  }

  fileprivate static func functionHelp(
    _ name: String,
    signature: String,
    summary: String,
    body: String,
    examples: [String],
    keywords: [String] = []
  ) -> LanguageTopic {
    topic(
      id: "function.\(name)",
      category: .functions,
      title: name,
      signature: signature,
      summary: summary,
      body: body,
      examples: examples,
      keywords: [name] + keywords
    )
  }

  fileprivate static func keyword(
    _ name: String,
    aliases: [String] = [],
    summary: String,
    body: String,
    examples: [String]
  ) -> LanguageTopic {
    topic(
      id: "keyword.\(name)",
      category: .keywords,
      title: name,
      summary: summary,
      body: body,
      examples: examples,
      keywords: [name] + aliases
    )
  }

  fileprivate static func text(_ key: StaticString, _ defaultValue: String.LocalizationValue)
    -> String
  {
    String(
      localized: key,
      defaultValue: defaultValue,
      bundle: FormattingResources.bundle
    )
  }
}
