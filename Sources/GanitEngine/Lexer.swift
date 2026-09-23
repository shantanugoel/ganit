public struct Lexer: Sendable {
  private let source: String
  private let configuration: LexingConfiguration
  private let limits: SyntaxLimits
  private let origin: SourceLocation

  /// `origin` is the location of `source` within a larger document, such as
  /// a sheet. Every produced range is expressed in that document's offsets.
  public init(
    source: String,
    configuration: LexingConfiguration = .englishUnitedStates,
    limits: SyntaxLimits = .default,
    origin: SourceLocation = .start
  ) {
    self.source = source
    self.configuration = configuration
    self.limits = limits
    self.origin = origin
  }

  public func lex() -> LexingResult {
    let utf8Length = source.utf8.count
    if utf8Length > limits.maximumSourceUTF8Length {
      let utf8End = origin.utf8Offset + utf8Length
      let graphemeEnd = origin.graphemeOffset + source.count
      let sourceRange = SourceRange(
        lowerBound: origin.utf8Offset,
        upperBound: utf8End,
        graphemeLowerBound: origin.graphemeOffset,
        graphemeUpperBound: graphemeEnd
      )
      let endRange = SourceRange(
        lowerBound: utf8End,
        upperBound: utf8End,
        graphemeLowerBound: graphemeEnd,
        graphemeUpperBound: graphemeEnd
      )
      return LexingResult(
        tokens: [Token(kind: .endOfFile, range: endRange)],
        diagnostics: [
          SyntaxDiagnostic(code: .resourceLimitExceeded, range: sourceRange)
        ]
      )
    }

    var scanner = Scanner(
      source: source,
      configuration: configuration,
      maximumTokenCount: limits.maximumTokenCount,
      origin: origin
    )
    return scanner.scan()
  }
}

private struct Scanner {
  private enum GroupingCacheEntry {
    /// `maximumLeadingGroup` is the size of the groups between the leading
    /// digits and the last group, which the leading digits may not exceed.
    case valid(end: Int, maximumLeadingGroup: Int)
    case invalid
  }

  private struct DecimalDigit {
    let value: Int
    let script: UInt32
  }

  private let characters: [Character]
  private let utf8Offsets: [Int]
  private let configuration: LexingConfiguration
  private let maximumTokenCount: Int
  private let graphemeOrigin: Int
  private var cursor = 0
  private var tokens: [Token] = []
  private var diagnostics: [SyntaxDiagnostic] = []
  private var groupingCache: [Int: GroupingCacheEntry] = [:]
  /// Open parentheses of an `ask_assistant` prompt, whose words are not
  /// tokens, and whether a `{…}` placeholder inside it is open.
  private var promptDepth = 0
  private var isInPlaceholder = false

  init(
    source: String,
    configuration: LexingConfiguration,
    maximumTokenCount: Int,
    origin: SourceLocation
  ) {
    characters = Array(source)
    self.configuration = configuration
    self.maximumTokenCount = maximumTokenCount
    graphemeOrigin = origin.graphemeOffset

    var offsets = [origin.utf8Offset]
    offsets.reserveCapacity(characters.count + 1)
    for character in characters {
      offsets.append(offsets[offsets.count - 1] + character.utf8.count)
    }
    utf8Offsets = offsets
  }

  mutating func scan() -> LexingResult {
    while let character = current {
      if tokens.count + diagnostics.count >= maximumTokenCount {
        diagnose(.resourceLimitExceeded, from: cursor, to: characters.count)
        cursor = characters.count
        break
      }

      let start = cursor

      if character == "\r\n" || character == "\r" || character == "\n" {
        advance()
        if character == "\r", current == "\n" {
          advance()
        }
        append(.newline, from: start)
        promptDepth = 0
        isInPlaceholder = false
        continue
      }

      if promptDepth > 0, !isInPlaceholder {
        scanPromptCharacter(character)
        continue
      }

      if isInPlaceholder, character == "}" {
        advance()
        append(.rightBrace, from: start)
        isInPlaceholder = false
        continue
      }

      if character.isWhitespace {
        advance()
        continue
      }

      if decimalDigit(character) != nil {
        if scanTemporal() {
          continue
        }
        scanNumber()
        continue
      }

      if character == "°" {
        scanDegreeUnit()
        continue
      }

      if isIdentifierStart(character) {
        scanIdentifier()
        continue
      }

      advance()
      switch character {
      case "+":
        append(.plus, from: start)
      case "-", "−":
        append(.minus, from: start)
      case "*" where current == "*":
        // `**` is a power, as it is in many programming languages.
        advance()
        append(.power, from: start)
      case "*", "×", "·":
        append(.multiply, from: start)
      case "/", "÷":
        append(.divide, from: start)
      case "^":
        append(.power, from: start)
      case "√":
        append(.squareRoot, from: start)
      case "!":
        append(.factorial, from: start)
      case "&":
        append(.bitwiseAnd, from: start)
      case "|":
        append(.bitwiseOr, from: start)
      case "<" where current == "<":
        advance()
        append(.shiftLeft, from: start)
      case ">" where current == ">":
        advance()
        append(.shiftRight, from: start)
      case "²":
        append(.superscript(2), from: start)
      case "³":
        append(.superscript(3), from: start)
      case "%":
        append(.percent, from: start)
      case "(":
        append(.leftParenthesis, from: start)
      case ")":
        append(.rightParenthesis, from: start)
      case ",":
        if configuration.decimalSeparator != ","
          || current?.isWhitespace == true
        {
          append(.argumentSeparator, from: start)
        } else {
          diagnose(.unexpectedCharacter, from: start)
        }
      case ";":
        append(.argumentSeparator, from: start)
      case _
      where CurrencyCatalog.symbols[String(character)] != nil
        || CurrencyCatalog.ambiguousSymbols.contains(String(character)):
        append(.currencySymbol(String(character)), from: start)
      default:
        diagnose(.unexpectedCharacter, from: start)
      }
    }

    let endRange = range(from: cursor)
    tokens.append(Token(kind: .endOfFile, range: endRange))
    return LexingResult(tokens: tokens, diagnostics: diagnostics)
  }

  private var current: Character? {
    character(at: cursor)
  }

  private func character(at index: Int) -> Character? {
    characters.indices.contains(index) ? characters[index] : nil
  }

  private mutating func advance() {
    cursor += 1
  }

  private func range(from start: Int, to end: Int? = nil) -> SourceRange {
    SourceRange(
      lowerBound: utf8Offsets[start],
      upperBound: utf8Offsets[end ?? cursor],
      graphemeLowerBound: graphemeOrigin + start,
      graphemeUpperBound: graphemeOrigin + (end ?? cursor)
    )
  }

  private mutating func append(_ kind: TokenKind, from start: Int) {
    tokens.append(Token(kind: kind, range: range(from: start)))
  }

  private mutating func diagnose(
    _ code: SyntaxDiagnostic.Code,
    from start: Int,
    to end: Int? = nil,
    severity: DiagnosticSeverity = .error
  ) {
    diagnostics.append(
      SyntaxDiagnostic(
        code: code,
        severity: severity,
        range: range(from: start, to: end)
      )
    )
  }

  private mutating func scanIdentifier() {
    let start = cursor
    advance()
    while let character = current, isIdentifierContinuation(character) {
      advance()
    }

    let identifier = String(characters[start..<cursor])
    // A currency code may touch its amount: INR7.23 and usd10. Keep other
    // identifiers containing digits whole (for example a sheet variable).
    if identifier.count > 3 {
      let prefix = String(identifier.prefix(3)).uppercased()
      let remainder = identifier.dropFirst(3)
      if CurrencyCatalog.minorUnits[prefix] != nil,
        prefix.allSatisfy(\.isLetter),
        String(identifier.prefix(3)) == prefix
          || builtInMinimalUnitCatalog.resolveUnit(matching: String(identifier.prefix(3))) == nil,
        remainder.allSatisfy({ $0.isASCII && $0.isNumber })
      {
        cursor = start + 3
        append(.identifier(String(characters[start..<cursor])), from: start)
        return
      }
    }
    if current == "$", CurrencyCatalog.symbols[identifier + "$"] != nil {
      advance()
      append(.currencySymbol(identifier + "$"), from: start)
      return
    }
    append(.identifier(identifier), from: start)
    guard identifier == assistantFunctionName, promptDepth == 0 else {
      return
    }
    while let character = current, character.isWhitespace, !character.isNewline {
      advance()
    }
    if current == "(" {
      let parenthesis = cursor
      advance()
      append(.leftParenthesis, from: parenthesis)
      promptDepth = 1
    }
  }

  /// A prompt's words are sent as written, so only its closing parenthesis
  /// and the `{` of each placeholder are tokens.
  private mutating func scanPromptCharacter(_ character: Character) {
    let start = cursor
    advance()
    switch character {
    case "(":
      promptDepth += 1
    case ")":
      promptDepth -= 1
      if promptDepth == 0 {
        append(.rightParenthesis, from: start)
      }
    case "{":
      append(.leftBrace, from: start)
      isInPlaceholder = true
    default:
      break
    }
  }

  private mutating func scanDegreeUnit() {
    let start = cursor
    advance()
    while let character = current, isIdentifierContinuation(character) {
      advance()
    }
    append(.identifier(String(characters[start..<cursor])), from: start)
  }

  private mutating func scanNumber() {
    let start = cursor
    if character(at: cursor) == "0",
      let radix = radix(afterZeroAt: cursor)
    {
      scanRadixNumber(from: start, radix: radix)
      return
    }

    var digits = ""
    var digitScript: UInt32?
    var mixedDigitScriptsReported = false
    var integerDigitCount = 0

    consumeDecimalDigits(
      into: &digits,
      count: &integerDigitCount,
      script: &digitScript,
      mixedDigitScriptsReported: &mixedDigitScriptsReported
    )

    if let groupingSeparator = configuration.groupingSeparator,
      current == groupingSeparator,
      let groupingEnd = groupingCandidate(
        startingAt: cursor,
        initialGroupSize: integerDigitCount
      )
    {
      for _ in cursor..<groupingEnd {
        if let digit = decimalDigit(current) {
          append(
            digit,
            into: &digits,
            script: &digitScript,
            mixedDigitScriptsReported: &mixedDigitScriptsReported
          )
        }
        advance()
      }
    }

    var fractionalDigitCount = 0
    var hasDecimalSeparator = false
    if current == configuration.decimalSeparator,
      configuration.decimalSeparator != ","
        || character(at: cursor + 1)?.isWhitespace != true
    {
      hasDecimalSeparator = true
      let separator = cursor
      advance()
      consumeDecimalDigits(
        into: &digits,
        count: &fractionalDigitCount,
        script: &digitScript,
        mixedDigitScriptsReported: &mixedDigitScriptsReported
      )
      if fractionalDigitCount == 0 {
        diagnose(
          .missingFractionDigits,
          from: separator,
          severity: remainingInputIsWhitespace ? .incomplete : .error
        )
      }
    }

    var exponent = 0
    var hasExponent = false
    if current == "e" || current == "E" {
      hasExponent = true
      let exponentStart = cursor
      advance()

      var exponentIsNegative = false
      if current == "+" {
        advance()
      } else if current == "-" || current == "−" {
        exponentIsNegative = true
        advance()
      }

      var exponentDigits = ""
      var exponentDigitCount = 0
      consumeDecimalDigits(
        into: &exponentDigits,
        count: &exponentDigitCount,
        script: &digitScript,
        mixedDigitScriptsReported: &mixedDigitScriptsReported
      )

      if exponentDigitCount == 0 {
        diagnose(
          .missingExponentDigits,
          from: exponentStart,
          severity: remainingInputIsWhitespace ? .incomplete : .error
        )
      } else if let magnitude = Int(exponentDigits) {
        exponent = exponentIsNegative ? -magnitude : magnitude
      } else {
        diagnose(.exponentOutOfRange, from: exponentStart)
      }
    }

    let literal: NumericLiteral
    if hasDecimalSeparator || hasExponent {
      literal = .decimal(
        digits: digits,
        fractionalDigitCount: fractionalDigitCount,
        exponent: exponent
      )
    } else {
      literal = .integer(digits: digits, radix: .decimal)
    }
    append(.number(literal), from: start)
  }

  private mutating func consumeDecimalDigits(
    into digits: inout String,
    count: inout Int,
    script: inout UInt32?,
    mixedDigitScriptsReported: inout Bool
  ) {
    while let digit = decimalDigit(current) {
      append(
        digit,
        into: &digits,
        script: &script,
        mixedDigitScriptsReported: &mixedDigitScriptsReported
      )
      count += 1
      advance()
    }
  }

  private mutating func append(
    _ digit: DecimalDigit,
    into digits: inout String,
    script: inout UInt32?,
    mixedDigitScriptsReported: inout Bool
  ) {
    if let script, script != digit.script, !mixedDigitScriptsReported {
      diagnose(.mixedDigitScripts, from: cursor, to: cursor + 1)
      mixedDigitScriptsReported = true
    } else if script == nil {
      script = digit.script
    }
    digits.append(String(digit.value))
  }

  private mutating func groupingCandidate(
    startingAt start: Int,
    initialGroupSize: Int
  ) -> Int? {
    guard let groupingSeparator = configuration.groupingSeparator else {
      return nil
    }

    if let cached = groupingCache[start] {
      return groupingEnd(
        from: cached,
        initialGroupSize: initialGroupSize
      )
    }

    var probe = start
    var separatorPositions: [Int] = []
    var groupSizes: [Int] = []
    while character(at: probe) == groupingSeparator {
      let separatorPosition = probe
      let groupStart = separatorPosition + 1
      var groupEnd = groupStart
      while decimalDigit(character(at: groupEnd)) != nil {
        groupEnd += 1
      }

      guard groupEnd > groupStart else {
        break
      }
      separatorPositions.append(separatorPosition)
      groupSizes.append(groupEnd - groupStart)
      probe = groupEnd
    }

    guard !separatorPositions.isEmpty else {
      groupingCache[start] = .invalid
      return nil
    }

    // Lakh grouping (`1,00,000`) is also read wherever digits group in
    // threes, as it cannot mean anything else there.
    let secondarySizes = Set([configuration.secondaryGroupingSize, 2])
    var suffixIsValid = true
    var secondary: Int?
    for index in stride(from: groupSizes.count - 1, through: 0, by: -1) {
      if index == groupSizes.count - 1 {
        suffixIsValid =
          groupSizes[index] == configuration.primaryGroupingSize
      } else {
        suffixIsValid =
          suffixIsValid
          && groupSizes[index] == (secondary ?? groupSizes[index])
          && secondarySizes.contains(groupSizes[index])
        secondary = groupSizes[index]
      }
      groupingCache[separatorPositions[index]] =
        suffixIsValid
        ? .valid(end: probe, maximumLeadingGroup: secondary ?? secondarySizes.max()!)
        : .invalid
    }

    return groupingEnd(
      from: groupingCache[start] ?? .invalid,
      initialGroupSize: initialGroupSize
    )
  }

  private func groupingEnd(
    from cacheEntry: GroupingCacheEntry,
    initialGroupSize: Int
  ) -> Int? {
    guard case .valid(let end, let maximumLeadingGroup) = cacheEntry else {
      return nil
    }

    guard
      initialGroupSize > 0,
      initialGroupSize <= maximumLeadingGroup
    else {
      return nil
    }
    return end
  }

  private func radix(afterZeroAt index: Int) -> NumericRadix? {
    switch character(at: index + 1) {
    case "b", "B":
      return .binary
    case "o", "O":
      return .octal
    case "x", "X":
      return .hexadecimal
    default:
      return nil
    }
  }

  private mutating func scanRadixNumber(from start: Int, radix: NumericRadix) {
    cursor += 2
    let digitsStart = cursor
    var digits = ""

    while let value = radixDigitValue(current), value < radix.rawValue {
      digits.append(String(value, radix: radix.rawValue, uppercase: false))
      advance()
    }

    if current.map(isASCIIAlphaNumeric) == true {
      let invalidStart = cursor
      while current.map(isASCIIAlphaNumeric) == true {
        advance()
      }
      diagnose(.invalidRadixDigit, from: invalidStart)
    } else if cursor == digitsStart {
      diagnose(
        .missingRadixDigits,
        from: start,
        severity: remainingInputIsWhitespace ? .incomplete : .error
      )
    }

    append(.number(.integer(digits: digits, radix: radix)), from: start)
  }

  private var remainingInputIsWhitespace: Bool {
    characters[cursor...].allSatisfy(\.isWhitespace)
  }

  private func decimalDigit(_ character: Character?) -> DecimalDigit? {
    guard
      let character,
      character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first,
      scalar.properties.generalCategory == .decimalNumber,
      let value = character.wholeNumberValue
    else {
      return nil
    }

    return DecimalDigit(value: value, script: scalar.value - UInt32(value))
  }

  /// Scans an ISO 8601 date (`2024-03-09`), time (`14:05`, `14:05:30`), or date
  /// and time (`2024-03-09T14:05`, optionally ending in `Z` or `±HH:MM`).
  private mutating func scanTemporal() -> Bool {
    let start = cursor
    // `16/09/2026` is a date in most of the world and a division in the
    // grammar; saying so beats a silently tiny number.
    if let length = slashDateLength(at: start) {
      diagnose(.ambiguousSlashDate, from: start, to: start + length, severity: .ambiguity)
    }
    if let year = asciiNumber(at: start, digits: 4), character(at: start + 4) == "-",
      let month = asciiNumber(at: start + 5, digits: 2), character(at: start + 7) == "-",
      let day = asciiNumber(at: start + 8, digits: 2),
      asciiNumber(at: start + 10, digits: 1) == nil
    {
      guard character(at: start + 10) == "T", let time = timeLength(at: start + 11) else {
        cursor = start + 10
        append(.temporal(.date(year: year, month: month, day: day)), from: start)
        return true
      }
      let (hour, minute, second) = timeFields(at: start + 11)
      cursor = start + 11 + time
      var offset: Int?
      if current == "Z" {
        offset = 0
        advance()
      } else if current == "+" || current == "-",
        let offsetHours = asciiNumber(at: cursor + 1, digits: 2), character(at: cursor + 3) == ":",
        let offsetMinutes = asciiNumber(at: cursor + 4, digits: 2),
        asciiNumber(at: cursor + 6, digits: 1) == nil
      {
        offset = (current == "-" ? -1 : 1) * (offsetHours * 3_600 + offsetMinutes * 60)
        cursor += 6
      }
      append(
        .temporal(
          .dateTime(
            DateTimeLiteral(
              year: year, month: month, day: day, hour: hour, minute: minute, second: second,
              offset: offset))),
        from: start
      )
      return true
    }
    guard let time = timeLength(at: start) else {
      return false
    }
    let (hour, minute, second) = timeFields(at: start)
    cursor = start + time
    append(.temporal(.time(hour: hour, minute: minute, second: second)), from: start)
    return true
  }

  /// The length of `H:MM`, `HH:MM`, `H:MM:SS`, or `HH:MM:SS` at an index.
  private func timeLength(at index: Int) -> Int? {
    let hourDigits = asciiNumber(at: index + 1, digits: 1) == nil ? 1 : 2
    guard asciiNumber(at: index, digits: hourDigits) != nil,
      character(at: index + hourDigits) == ":",
      asciiNumber(at: index + hourDigits + 1, digits: 2) != nil
    else {
      return nil
    }
    var length = hourDigits + 3
    if character(at: index + length) == ":", asciiNumber(at: index + length + 1, digits: 2) != nil {
      length += 3
    }
    return asciiNumber(at: index + length, digits: 1) == nil ? length : nil
  }

  private func timeFields(at index: Int) -> (hour: Int, minute: Int, second: Int) {
    let length = timeLength(at: index)!
    let hourDigits = length % 3 == 1 ? 1 : 2
    let minute = asciiNumber(at: index + hourDigits + 1, digits: 2)!
    let second = length > hourDigits + 3 ? asciiNumber(at: index + hourDigits + 4, digits: 2)! : 0
    return (asciiNumber(at: index, digits: hourDigits)!, minute, second)
  }

  /// The value of exactly `digits` ASCII digits at an index.
  /// The length of `d/m/yyyy` or `m/d/yyyy` at `index`, with one or two digits
  /// for day and month, written without spaces.
  private func slashDateLength(at index: Int) -> Int? {
    var cursor = index
    for digits in [2, 2, 4] {
      var count = 0
      while count < digits, asciiNumber(at: cursor + count, digits: 1) != nil {
        count += 1
      }
      guard count > 0, digits != 4 || count == 4 else {
        return nil
      }
      cursor += count
      if digits != 4 {
        guard character(at: cursor) == "/" else {
          return nil
        }
        cursor += 1
      }
    }
    return asciiNumber(at: cursor, digits: 1) == nil ? cursor - index : nil
  }

  private func asciiNumber(at index: Int, digits: Int) -> Int? {
    var value = 0
    for offset in 0..<digits {
      guard let digit = character(at: index + offset)?.asciiValue, (48...57).contains(digit) else {
        return nil
      }
      value = value * 10 + Int(digit - 48)
    }
    return value
  }

  private func radixDigitValue(_ character: Character?) -> Int? {
    guard let scalar = character?.unicodeScalars.first,
      character?.unicodeScalars.count == 1
    else {
      return nil
    }

    switch scalar.value {
    case 48...57:
      return Int(scalar.value - 48)
    case 65...70:
      return Int(scalar.value - 65 + 10)
    case 97...102:
      return Int(scalar.value - 97 + 10)
    default:
      return nil
    }
  }

  private func isASCIIAlphaNumeric(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1,
      let value = character.unicodeScalars.first?.value
    else {
      return false
    }
    return (48...57).contains(value)
      || (65...90).contains(value)
      || (97...122).contains(value)
  }

  private func isIdentifierStart(_ character: Character) -> Bool {
    if character == "_" {
      return true
    }

    guard let firstScalar = character.unicodeScalars.first,
      firstScalar.properties.isXIDStart
    else {
      return false
    }
    return character.unicodeScalars.dropFirst().allSatisfy {
      $0.properties.isXIDContinue
    }
  }

  private func isIdentifierContinuation(_ character: Character) -> Bool {
    if character == "·" || character == "²" || character == "³" {
      return false
    }
    if character == "_" {
      return true
    }
    return character.unicodeScalars.allSatisfy {
      $0.properties.isXIDContinue
    }
  }
}
