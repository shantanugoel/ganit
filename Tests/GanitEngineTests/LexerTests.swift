import Testing

@testable import GanitEngine

@Suite
struct LexerTests {
  @Test
  func lexesUnitProductsDegreeAliasesAndSuperscripts() {
    let result = Lexer(source: "kg·m/s² °C").lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.map(\.kind) == [
        .identifier("kg"),
        .multiply,
        .identifier("m"),
        .divide,
        .identifier("s"),
        .superscript(2),
        .identifier("°C"),
        .endOfFile,
      ]
    )
  }

  @Test
  func lexesISODatesTimesAndDateTimes() {
    let result = Lexer(
      source: "2024-03-09 9:05 14:05:30 2024-03-09T12:00Z 2024-03-09T12:00:01-05:30 2024-3-9"
    ).lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.map(\.kind) == [
        .temporal(.date(year: 2024, month: 3, day: 9)),
        .temporal(.time(hour: 9, minute: 5, second: 0)),
        .temporal(.time(hour: 14, minute: 5, second: 30)),
        .temporal(
          .dateTime(
            DateTimeLiteral(
              year: 2024, month: 3, day: 9, hour: 12, minute: 0, second: 0, offset: 0))),
        .temporal(
          .dateTime(
            DateTimeLiteral(
              year: 2024, month: 3, day: 9, hour: 12, minute: 0, second: 1, offset: -19_800))),
        .number(.integer(digits: "2024", radix: .decimal)),
        .minus,
        .number(.integer(digits: "3", radix: .decimal)),
        .minus,
        .number(.integer(digits: "9", radix: .decimal)),
        .endOfFile,
      ]
    )
  }

  @Test
  func lexesArithmeticNumbersAndProgrammerLiterals() throws {
    let result = Lexer(source: "12 + 3.50e-2 × 0xff").lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.map(\.kind) == [
        .number(.integer(digits: "12", radix: .decimal)),
        .plus,
        .number(.decimal(digits: "350", fractionalDigitCount: 2, exponent: -2)),
        .multiply,
        .number(.integer(digits: "ff", radix: .hexadecimal)),
        .endOfFile,
      ]
    )
  }

  @Test
  func lexesPercentAsItsOwnOperator() {
    let result = Lexer(source: "20%").lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.map(\.kind) == [
        .number(.integer(digits: "20", radix: .decimal)),
        .percent,
        .endOfFile,
      ]
    )
  }

  @Test
  func retainsExactUTF8SourceRanges() throws {
    let source = "π + ٢"
    let result = Lexer(source: source).lex()

    #expect(result.diagnostics.isEmpty)
    #expect(try #require(result.tokens[0].range.text(in: source)) == "π")
    #expect(try #require(result.tokens[1].range.text(in: source)) == "+")
    #expect(try #require(result.tokens[2].range.text(in: source)) == "٢")
    #expect(
      result.tokens[0].range
        == SourceRange(
          lowerBound: 0,
          upperBound: 2,
          graphemeLowerBound: 0,
          graphemeUpperBound: 1
        )
    )
    #expect(
      result.tokens[2].range
        == SourceRange(
          lowerBound: 5,
          upperBound: 7,
          graphemeLowerBound: 4,
          graphemeUpperBound: 5
        )
    )
  }

  @Test
  func normalizesLocaleDigitsAndSeparators() {
    let configuration = LexingConfiguration(
      decimalSeparator: "٫",
      groupingSeparator: "٬"
    )
    let result = Lexer(source: "١٢٬٣٤٥٫٦٠", configuration: configuration).lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.first?.kind
        == .number(
          .decimal(digits: "1234560", fractionalDigitCount: 2, exponent: 0)
        )
    )
  }

  @Test
  func appliesSecondaryGroupingSize() {
    let configuration = LexingConfiguration(
      decimalSeparator: ".",
      groupingSeparator: ",",
      primaryGroupingSize: 3,
      secondaryGroupingSize: 2
    )
    let result = Lexer(source: "12,34,567", configuration: configuration).lex()

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.tokens.first?.kind
        == .number(.integer(digits: "1234567", radix: .decimal))
    )
  }

  @Test
  func doesNotAcceptOversizedIndianLeadingGroup() {
    let configuration = LexingConfiguration(
      decimalSeparator: ".",
      groupingSeparator: ",",
      primaryGroupingSize: 3,
      secondaryGroupingSize: 2
    )
    let result = Lexer(source: "123,45,678", configuration: configuration).lex()

    #expect(
      result.tokens.first?.kind
        == .number(.integer(digits: "123", radix: .decimal))
    )
    #expect(result.tokens.map(\.kind).contains(.argumentSeparator))
  }

  @Test
  func doesNotAcceptOversizedIndianLeadingGroupWithOneSeparator() {
    let configuration = LexingConfiguration(
      decimalSeparator: ".",
      groupingSeparator: ",",
      primaryGroupingSize: 3,
      secondaryGroupingSize: 2
    )
    let result = Lexer(source: "123,456", configuration: configuration).lex()

    #expect(
      result.tokens.first?.kind
        == .number(.integer(digits: "123", radix: .decimal))
    )
    #expect(result.tokens.map(\.kind).contains(.argumentSeparator))
  }

  @Test
  func lexesP0LocaleFixtures() {
    let fixtures: [(source: String, configuration: LexingConfiguration)] = [
      ("1,234,567.89", .englishUnitedStates),  // en-US
      ("1,234,567.89", .englishUnitedStates),  // en-GB
      (
        "12,34,567.89",
        LexingConfiguration(
          decimalSeparator: ".",
          groupingSeparator: ",",
          primaryGroupingSize: 3,
          secondaryGroupingSize: 2
        )
      ),  // en-IN
      (
        "1.234.567,89",
        LexingConfiguration(
          decimalSeparator: ",",
          groupingSeparator: "."
        )
      ),  // de-DE
      (
        "1 234 567,89",
        LexingConfiguration(
          decimalSeparator: ",",
          groupingSeparator: " "
        )
      ),  // fr-FR
      (
        "١٬٢٣٤٬٥٦٧٫٨٩",
        LexingConfiguration(
          decimalSeparator: "٫",
          groupingSeparator: "٬"
        )
      ),  // ar-EG
    ]

    for fixture in fixtures {
      let result = Lexer(
        source: fixture.source,
        configuration: fixture.configuration
      ).lex()
      #expect(result.diagnostics.isEmpty)
      #expect(
        result.tokens.first?.kind
          == .number(
            .decimal(
              digits: "123456789",
              fractionalDigitCount: 2,
              exponent: 0
            )
          )
      )
    }
  }

  @Test
  func distinguishesGroupingFromArgumentSeparators() {
    let result = Lexer(source: "min(1, 2) + 1,234").lex()

    #expect(result.diagnostics.isEmpty)
    #expect(result.tokens.map(\.kind).contains(.argumentSeparator))
    #expect(
      result.tokens.map(\.kind).contains(
        .number(.integer(digits: "1234", radix: .decimal))
      )
    )
  }

  @Test
  func supportsCommaDecimalAndFunctionSeparator() {
    let configuration = LexingConfiguration(
      decimalSeparator: ",",
      groupingSeparator: "."
    )
    let result = Lexer(source: "min(1; 2) + 1,25", configuration: configuration).lex()

    #expect(result.diagnostics.isEmpty)
    #expect(result.tokens.map(\.kind).contains(.argumentSeparator))
    #expect(
      result.tokens.map(\.kind).contains(
        .number(.decimal(digits: "125", fractionalDigitCount: 2, exponent: 0))
      )
    )
  }

  @Test
  func distinguishesIncompleteDecimalCommaFromArguments() {
    let configuration = LexingConfiguration(
      decimalSeparator: ",",
      groupingSeparator: "."
    )

    let incomplete = Lexer(source: "1,", configuration: configuration).lex()
    #expect(incomplete.diagnostics.map(\.code) == [.missingFractionDigits])

    let compactCall = Lexer(
      source: "f(1,+2)",
      configuration: configuration
    ).lex()
    #expect(compactCall.diagnostics.map(\.code) == [.missingFractionDigits])

    let misplacedWhitespace = Lexer(
      source: "f(1 ,2)",
      configuration: configuration
    ).lex()
    #expect(misplacedWhitespace.diagnostics.map(\.code) == [.unexpectedCharacter])

    let spacedCall = Lexer(
      source: "f(1, 2)",
      configuration: configuration
    ).lex()
    #expect(spacedCall.diagnostics.isEmpty)
    #expect(spacedCall.tokens.map(\.kind).contains(.argumentSeparator))
  }

  @Test
  func rejectsMixedDigitScriptsWithinOneLiteral() throws {
    let source = "1٢ + 3e٤"
    let result = Lexer(source: source).lex()

    #expect(result.diagnostics.map(\.code) == [.mixedDigitScripts, .mixedDigitScripts])
    #expect(try #require(result.diagnostics[0].range.text(in: source)) == "٢")
    #expect(try #require(result.diagnostics[1].range.text(in: source)) == "٤")
  }

  @Test
  func reportsRadixAndExponentFailuresWithRanges() throws {
    let source = "0xG + 1e"
    let result = Lexer(source: source).lex()

    #expect(result.diagnostics.map(\.code) == [.invalidRadixDigit, .missingExponentDigits])
    #expect(result.diagnostics.map(\.severity) == [.error, .incomplete])
    #expect(try #require(result.diagnostics[0].range.text(in: source)) == "G")
    #expect(try #require(result.diagnostics[1].range.text(in: source)) == "e")
  }

  @Test
  func marksMissingDigitsIncompleteOnlyAtEndOfInput() {
    let incompleteSources = [
      "0x", "1.", "1e+",
      "0x \t", "1. \t", "1e+ \t",
    ]
    let malformedSources = ["0x + 1", "1.+2", "1e+)"]

    for source in incompleteSources {
      #expect(Lexer(source: source).lex().diagnostics.first?.severity == .incomplete)
    }
    for source in malformedSources {
      #expect(Lexer(source: source).lex().diagnostics.first?.severity == .error)
    }
  }

  @Test
  func emitsOneTokenForCRLF() throws {
    let source = "1\r\n2"
    let result = Lexer(source: source).lex()
    let newline = try #require(result.tokens.first { $0.kind == .newline })

    #expect(try #require(newline.range.text(in: source)) == "\r\n")
  }

  @Test
  func keepsMalformedUnicodeRangesOnStringBoundaries() {
    let sources = [
      "\0 + 1",
      "👨‍👩‍👧‍👦 + 2",
      "\u{202E}12 + 3",
      "e\u{301} + 4",
      "1e" + String(repeating: "9", count: 1_000),
    ]

    for source in sources {
      let result = Lexer(source: source).lex()
      for token in result.tokens {
        #expect(token.range.text(in: source) != nil)
      }
      for diagnostic in result.diagnostics {
        #expect(diagnostic.range.text(in: source) != nil)
      }
    }
  }

  @Test
  func followsUnicodeIdentifierStartAndContinuation() throws {
    let composed = try #require(Lexer(source: "é2").lex().tokens.first)
    let decomposed = try #require(
      Lexer(source: "e\u{301}2").lex().tokens.first
    )
    #expect(composed.kind == decomposed.kind)

    let leadingMark = Lexer(source: "\u{301}x").lex()
    #expect(leadingMark.diagnostics.first?.code == .unexpectedCharacter)
  }

  @Test
  func boundsMalformedGroupingWork() {
    let source = (["1"] + Array(repeating: "111", count: 5_000) + ["11"])
      .joined(separator: ",")
    let limits = SyntaxLimits(
      maximumSourceUTF8Length: source.utf8.count,
      maximumTokenCount: 20_000,
      maximumParseDepth: 256
    )
    let result = Lexer(source: source, limits: limits).lex()

    #expect(result.tokens.last?.kind == .endOfFile)
    #expect(!result.diagnostics.contains { $0.code == .resourceLimitExceeded })
  }
}
