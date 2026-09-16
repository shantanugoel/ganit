import Foundation

package let builtInMinimalUnitCatalog = try! UnitCatalog.minimal()

public enum UnitDefinitionExactness: String, Hashable, Sendable {
  case exact
  case approximate
}

extension UnitTransform {
  var isApproximate: Bool {
    switch self {
    case .ratio(let scale):
      return scale.containsApproximation
    case .affine(let scale, let offset):
      return scale.containsApproximation || offset.containsApproximation
    }
  }
}

extension NumericValue {
  var containsApproximation: Bool {
    if case .approximate = self {
      return true
    }
    return false
  }
}

public struct UnitSourceMetadata: Hashable, Sendable {
  public let identifier: String
  public let title: String
  public let revision: String
  public let url: URL
  public let licenseName: String
  public let licenseURL: URL
  public let notice: String

  public init(
    identifier: String,
    title: String,
    revision: String,
    url: URL,
    licenseName: String,
    licenseURL: URL,
    notice: String
  ) {
    self.identifier = identifier
    self.title = title
    self.revision = revision
    self.url = url
    self.licenseName = licenseName
    self.licenseURL = licenseURL
    self.notice = notice
  }
}

public struct UnitCatalogEntry: Hashable, Sendable {
  public let definition: UnitDefinition
  public let aliases: [String]
  public let exactness: UnitDefinitionExactness
  /// The data source this entry encodes, or `nil` for a unit a person
  /// defined, which is their own data and not attributed.
  public let sourceIdentifier: String?
}

public struct UnitPrefixEntry: Hashable, Sendable {
  public let prefix: UnitPrefix
  public let aliases: [String]
  public let sourceIdentifier: String
}

public struct UnitCatalog: Sendable {
  public struct ResolvedUnit: Hashable, Sendable {
    public let entry: UnitCatalogEntry
    public let prefix: UnitPrefixEntry?
  }

  public let entries: [UnitCatalogEntry]
  public let prefixes: [UnitPrefixEntry]
  public let sources: [UnitSourceMetadata]

  private let unitsByAlias: [String: UnitCatalogEntry]
  private let prefixesByAlias: [String: UnitPrefixEntry]

  public init(
    entries: [UnitCatalogEntry],
    prefixes: [UnitPrefixEntry],
    sources: [UnitSourceMetadata]
  ) throws {
    let sourceIdentifiers = Set(sources.map(\.identifier))
    let entriesHaveSources = entries.allSatisfy {
      ($0.sourceIdentifier.map(sourceIdentifiers.contains) ?? true)
        && !$0.aliases.isEmpty
    }
    let prefixesHaveSources = prefixes.allSatisfy {
      sourceIdentifiers.contains($0.sourceIdentifier)
        && !$0.aliases.isEmpty
    }
    let sourcesAreComplete = sources.allSatisfy(Self.isComplete)
    let exactnessIsHonest = entries.allSatisfy {
      $0.exactness == ($0.definition.transform.isApproximate ? .approximate : .exact)
    }
    guard
      sourceIdentifiers.count == sources.count,
      entriesHaveSources,
      prefixesHaveSources,
      sourcesAreComplete,
      exactnessIsHonest
    else {
      throw EngineError(code: .invalidUnitDefinition)
    }

    self.entries = entries
    self.prefixes = prefixes
    self.sources = sources
    unitsByAlias = try Self.index(entries, aliases: \.aliases)
    prefixesByAlias = try Self.index(prefixes, aliases: \.aliases)
  }

  public func unit(matching alias: String) -> UnitCatalogEntry? {
    unitsByAlias[alias]
  }

  public func prefix(matching alias: String) -> UnitPrefixEntry? {
    prefixesByAlias[alias]
  }

  /// Resolves exact unit aliases before considering an attached prefix.
  public func resolveUnit(matching alias: String) -> ResolvedUnit? {
    if let exact = unit(matching: alias) {
      return ResolvedUnit(entry: exact, prefix: nil)
    }
    for prefixAlias in prefixesByAlias.keys.sorted(by: {
      $0.count > $1.count
    }) where alias.hasPrefix(prefixAlias) {
      let unitAlias = String(alias.dropFirst(prefixAlias.count))
      guard
        !unitAlias.isEmpty,
        let prefix = prefix(matching: prefixAlias),
        let entry = unit(matching: unitAlias),
        entry.definition.allowedPrefixFamilies.contains(prefix.prefix.family)
      else {
        continue
      }
      return ResolvedUnit(entry: entry, prefix: prefix)
    }
    return nil
  }

  public var attributionMarkdown: String {
    var lines = [
      "# Unit data sources",
      "",
      "Ganit independently encodes the factual unit definitions listed below.",
      "It does not claim conformance with any external unit standard.",
      "",
    ]
    for source in sources.sorted(by: { $0.identifier < $1.identifier }) {
      lines.append("## \(source.title)")
      lines.append("")
      lines.append("- Revision: \(source.revision)")
      lines.append("- Source: \(source.url.absoluteString)")
      lines.append(
        "- Terms: \(source.licenseName) (\(source.licenseURL.absoluteString))"
      )
      lines.append("- Notice: \(source.notice)")
      lines.append("")
    }
    lines.append("## Catalog entries")
    lines.append("")
    for entry in entries.filter({ $0.sourceIdentifier != nil }).sorted(
      by: {
        $0.definition.canonicalIdentifier < $1.definition.canonicalIdentifier
      }
    ) {
      let identifier = entry.definition.canonicalIdentifier
      let symbol = entry.definition.symbol
      let dimension = entry.definition.dimension.canonicalDescription
      let transform = Self.describe(entry.definition.transform)
      let exactness = entry.exactness.rawValue
      let source = entry.sourceIdentifier ?? ""
      lines.append(
        "- `\(identifier)` (\(symbol)): dimension `\(dimension)`, "
          + "transform `\(transform)`, \(exactness), source `\(source)`"
      )
    }
    lines.append("")
    lines.append(
      "This file is generated from `UnitCatalog` metadata. Do not edit it manually."
    )
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// This catalog's data-source units plus a person's own units, replacing
  /// any custom units it already holds.
  ///
  /// A later unit replaces an earlier one of the same name, and a name a data
  /// source already uses is refused, so the built-in meaning of `m` or `min`
  /// cannot be redefined. A plural is added when it is free.
  func replacingCustomUnits(with units: [CustomUnit]) throws -> UnitCatalog {
    let sourced = entries.filter { $0.sourceIdentifier != nil }
    let reserved = Set(sourced.flatMap(\.aliases))
    var names: [String] = []
    var definitions: [String: CustomUnit] = [:]
    for unit in units where !reserved.contains(unit.name) {
      if definitions.updateValue(unit, forKey: unit.name) == nil {
        names.append(unit.name)
      }
    }
    var taken = reserved.union(names)
    let custom = names.map { name -> UnitCatalogEntry in
      let unit = definitions[name]!
      let plurals = unit.aliases.filter { $0 != name && !taken.contains($0) }
      taken.formUnion(plurals)
      return unit.entry(aliases: [name] + plurals)
    }
    return try UnitCatalog(entries: sourced + custom, prefixes: prefixes, sources: sources)
  }

  public static func minimal() throws -> UnitCatalog {
    let sources = try sourceMetadata()
    return try UnitCatalog(
      entries: try minimalEntries(),
      prefixes: try minimalPrefixes(),
      sources: sources
    )
  }

  private static func index<Element>(
    _ elements: [Element],
    aliases: KeyPath<Element, [String]>
  ) throws -> [String: Element] {
    var result: [String: Element] = [:]
    for element in elements {
      for alias in element[keyPath: aliases] {
        guard
          !alias.isEmpty,
          alias.utf8.count <= UnitDefinition.maximumIdentifierLength,
          result.updateValue(element, forKey: alias) == nil
        else {
          throw EngineError(code: .invalidUnitDefinition)
        }
      }
    }
    return result
  }

  private static func isComplete(_ source: UnitSourceMetadata) -> Bool {
    let strings = [
      source.identifier,
      source.title,
      source.revision,
      source.licenseName,
      source.notice,
    ]
    return strings.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      && source.url.scheme == "https"
      && source.url.host != nil
      && source.licenseURL.scheme == "https"
      && source.licenseURL.host != nil
  }

  private static func describe(_ transform: UnitTransform) -> String {
    switch transform {
    case .ratio(let scale):
      return "ratio \(describe(scale))"
    case .affine(let scale, let offset):
      return "affine scale \(describe(scale)), offset \(describe(offset))"
    }
  }

  private static func describe(_ value: NumericValue) -> String {
    switch value {
    case .integer(let integer):
      return integer.canonicalDigits
    case .rational(let rational):
      return
        "\(rational.numerator.canonicalDigits)/"
        + rational.denominator.canonicalDigits
    case .decimal(let decimal):
      return "\(decimal.coefficient.canonicalDigits)e-\(decimal.scale)"
    case .approximate(let approximate):
      return "≈\(approximate.estimate)"
    }
  }

  private static func sourceMetadata() throws -> [UnitSourceMetadata] {
    [
      UnitSourceMetadata(
        identifier: "bipm-si-9-v4.01",
        title: "BIPM SI Brochure, 9th edition",
        revision: "version 4.01, June 2026",
        url: try url("https://doi.org/10.59161/AUEZ1291"),
        licenseName: "Creative Commons Attribution 4.0 International",
        licenseURL: try url("https://creativecommons.org/licenses/by/4.0/"),
        notice:
          "Definitions were independently encoded from the SI Brochure. "
          + "BIPM endorsement is not implied."
      ),
      UnitSourceMetadata(
        identifier: "nist-sp811-2008",
        title: "NIST Special Publication 811",
        revision: "second printing, November 2008",
        url: try url("https://doi.org/10.6028/NIST.SP.811e2008"),
        licenseName: "United States public information",
        licenseURL: try url("https://www.nist.gov/copyrights-disclaimers"),
        notice:
          "NIST is credited as the source of exact non-SI conversion facts. "
          + "NIST endorsement is not implied."
      ),
      UnitSourceMetadata(
        identifier: "iec-80000-13-2025",
        title: "IEC 80000-13:2025",
        revision: "edition 2.0, 2025-02-11",
        url: try url("https://webstore.iec.ch/en/publication/87379"),
        licenseName: "IEC copyrighted standard; factual definitions only",
        licenseURL: try url("https://www.iec.ch/copyright"),
        notice:
          "Ganit independently encodes bit, byte, and binary-prefix facts. "
          + "No IEC standard text or tables are redistributed."
      ),
    ]
  }

  private static func minimalEntries() throws -> [UnitCatalogEntry] {
    let bipm = "bipm-si-9-v4.01"
    let nist = "nist-sp811-2008"
    let iec = "iec-80000-13-2025"
    return [
      try entry(
        "meter", "m", .length, 1, ["m", "meter", "meters", "metre", "metres"], bipm,
        families: [.decimal]),
      try entry("inch", "in", .length, 254, 10_000, ["in", "inch", "inches"], nist),
      try entry("foot", "ft", .length, 381, 1_250, ["ft", "foot", "feet"], nist),
      try entry("yard", "yd", .length, 9_144, 10_000, ["yd", "yard", "yards"], nist),
      try entry(
        "mile", "mi", .length, 201_168, 125, ["mi", "mile", "miles"], nist),
      try entry(
        "hectare", "ha", .area, 10_000, ["ha", "hectare", "hectares"], bipm),
      try entry(
        "acre", "ac", .area, 40_468_564_224, 10_000_000, ["ac", "acre", "acres"], nist),
      try entry(
        "liter", "L", .volume, 1, 1_000,
        ["L", "l", "liter", "liters", "litre", "litres"], bipm,
        families: [.decimal]),
      try entry(
        "gallon", "gal", .volume, 3_785_411_784, 1_000_000_000_000,
        ["gal", "gallon", "gallons"], nist),
      try entry(
        "quart", "qt", .volume, 3_785_411_784, 4_000_000_000_000,
        ["qt", "quart", "quarts"], nist),
      try entry(
        "pint", "pt", .volume, 3_785_411_784, 8_000_000_000_000,
        ["pt", "pint", "pints"], nist),
      try entry(
        "cup", "cup", .volume, 3_785_411_784, 16_000_000_000_000,
        ["cup", "cups"], nist),
      try entry(
        "fluid-ounce", "floz", .volume, 3_785_411_784, 128_000_000_000_000,
        ["floz", "fluidounce", "fluidounces"], nist),
      try entry(
        "tablespoon", "tbsp", .volume, 3_785_411_784, 256_000_000_000_000,
        ["tbsp", "tablespoon", "tablespoons"], nist),
      try entry(
        "teaspoon", "tsp", .volume, 3_785_411_784, 768_000_000_000_000,
        ["tsp", "teaspoon", "teaspoons"], nist),
      try entry("kilogram", "kg", .mass, 1, ["kg", "kilogram", "kilograms"], bipm),
      try entry("tonne", "t", .mass, 1_000, ["t", "tonne", "tonnes"], bipm),
      try entry(
        "pound", "lb", .mass, 45_359_237, 100_000_000, ["lb", "lbs", "pound", "pounds"], nist),
      try entry(
        "ounce", "oz", .mass, 45_359_237, 1_600_000_000, ["oz", "ounce", "ounces"], nist),
      try entry(
        "stone", "st", .mass, 635_029_318, 100_000_000, ["st", "stone", "stones"], nist),
      try entry(
        "gram", "g", .mass, 1, 1_000, ["g", "gram", "grams"], bipm,
        families: [.decimal]),
      try entry(
        "second", "s", .time, 1, ["s", "second", "seconds"], bipm,
        families: [.decimal]),
      try entry("minute", "min", .time, 60, ["min", "minute", "minutes"], bipm),
      try entry("hour", "h", .time, 3_600, ["h", "hr", "hour", "hours"], bipm),
      try entry(
        "kelvin", "K", .temperature, 1, ["K", "kelvin", "kelvins"], bipm,
        families: [.decimal]),
      try affineEntry(
        "degree-celsius", "°C", 1, decimal(27_315, scale: 2), ["°C", "celsius"], bipm),
      try affineEntry(
        "degree-fahrenheit", "°F", fraction(5, 9), fraction(45_967, 180), ["°F", "fahrenheit"], nist
      ),
      try entry("radian", "rad", .angle, 1, ["rad", "radian", "radians"], bipm),
      try approximateEntry(
        "degree", "°", .angle, .pi / 180, ["°", "deg", "degree", "degrees"], bipm),
      try entry(
        "newton", "N", .force, 1, ["N", "newton", "newtons"], bipm,
        families: [.decimal]),
      try entry(
        "pascal", "Pa", .pressure, 1, ["Pa", "pascal", "pascals"], bipm,
        families: [.decimal]),
      try entry(
        "bar", "bar", .pressure, 100_000, ["bar", "bars"], bipm,
        families: [.decimal]),
      try entry(
        "atmosphere", "atm", .pressure, 101_325, ["atm", "atmosphere", "atmospheres"], nist),
      try entry(
        "pound-per-square-inch", "psi", .pressure, 44_482_216_152_605, 6_451_600_000, ["psi"],
        nist),
      try entry(
        "joule", "J", .energy, 1, ["J", "joule", "joules"], bipm,
        families: [.decimal]),
      try entry(
        "calorie", "cal", .energy, 523, 125, ["cal", "calorie", "calories"], nist,
        families: [.decimal]),
      try entry(
        "watt-hour", "Wh", .energy, 3_600, ["Wh"], bipm,
        families: [.decimal]),
      try entry(
        "watt", "W", .power, 1, ["W", "watt", "watts"], bipm,
        families: [.decimal]),
      try entry(
        "horsepower", "hp", .power, 37_284_993_579_113_511, 50_000_000_000_000,
        ["hp", "horsepower"], nist),
      try entry(
        "electronvolt", "eV", .energy, decimal(1_602_176_634, scale: 28),
        ["eV", "electronvolt", "electronvolts"], bipm, families: [.decimal]),
      try entry(
        "ampere", "A", .current, 1, ["A", "amp", "amps", "ampere", "amperes"], bipm,
        families: [.decimal]),
      try entry(
        "volt", "V", .voltage, 1, ["V", "volt", "volts"], bipm, families: [.decimal]),
      try entry(
        "ohm", "Ω", .resistance, 1, ["Ω", "ohm", "ohms"], bipm, families: [.decimal]),
      try entry(
        "farad", "F", .capacitance, 1, ["F", "farad", "farads"], bipm, families: [.decimal]),
      try entry(
        "henry", "H", .inductance, 1, ["H", "henry", "henries"], bipm, families: [.decimal]),
      try entry(
        "coulomb", "C", .charge, 1, ["C", "coulomb", "coulombs"], bipm, families: [.decimal]),
      try entry(
        "ampere-hour", "Ah", .charge, 3_600, ["Ah"], bipm, families: [.decimal]),
      try entry(
        "hertz", "Hz", .frequency, 1, ["Hz", "hertz"], bipm, families: [.decimal]),
      try entry(
        "mile-per-hour", "mph", .speed, 44_704, 100_000, ["mph"], nist),
      try entry(
        "bit", "bit", .data, 1, ["bit", "bits", "b"], iec,
        families: [.decimal, .binary]),
      try entry(
        "bit-per-second", "bps", .dataRate, 1, ["bps"], iec,
        families: [.decimal]),
      try entry(
        "byte", "B", .data, 8, ["B", "byte", "bytes"], iec,
        families: [.decimal, .binary]),
    ]
  }

  private static func minimalPrefixes() throws -> [UnitPrefixEntry] {
    let bipm = "bipm-si-9-v4.01"
    let iec = "iec-80000-13-2025"
    return [
      try decimalPrefix("quetta", "Q", 30, bipm),
      try decimalPrefix("ronna", "R", 27, bipm),
      try decimalPrefix("yotta", "Y", 24, bipm),
      try decimalPrefix("zetta", "Z", 21, bipm),
      try decimalPrefix("exa", "E", 18, bipm),
      try decimalPrefix("peta", "P", 15, bipm),
      try decimalPrefix("tera", "T", 12, bipm),
      try decimalPrefix("giga", "G", 9, bipm),
      try decimalPrefix("mega", "M", 6, bipm),
      try decimalPrefix("kilo", "k", 3, bipm),
      try decimalPrefix("hecto", "h", 2, bipm),
      try decimalPrefix("deca", "da", 1, bipm),
      try decimalPrefix("deci", "d", -1, bipm),
      try decimalPrefix("centi", "c", -2, bipm),
      try decimalPrefix("milli", "m", -3, bipm),
      try decimalPrefix("micro", "µ", -6, bipm),
      try decimalPrefix("nano", "n", -9, bipm),
      try decimalPrefix("pico", "p", -12, bipm),
      try decimalPrefix("femto", "f", -15, bipm),
      try decimalPrefix("atto", "a", -18, bipm),
      try decimalPrefix("zepto", "z", -21, bipm),
      try decimalPrefix("yocto", "y", -24, bipm),
      try decimalPrefix("ronto", "r", -27, bipm),
      try decimalPrefix("quecto", "q", -30, bipm),
      try binaryPrefix("kibi", "Ki", "1024", iec),
      try binaryPrefix("mebi", "Mi", "1048576", iec),
      try binaryPrefix("gibi", "Gi", "1073741824", iec),
      try binaryPrefix("tebi", "Ti", "1099511627776", iec),
      try binaryPrefix("pebi", "Pi", "1125899906842624", iec),
      try binaryPrefix("exbi", "Ei", "1152921504606846976", iec),
      try binaryPrefix("zebi", "Zi", "1180591620717411303424", iec),
      try binaryPrefix("yobi", "Yi", "1208925819614629174706176", iec),
      try binaryPrefix("robi", "Ri", "1237940039285380274899124224", iec),
      try binaryPrefix("quebi", "Qi", "1267650600228229401496703205376", iec),
    ]
  }

  private static func decimalPrefix(
    _ identifier: String,
    _ symbol: String,
    _ exponent: Int,
    _ source: String
  ) throws -> UnitPrefixEntry {
    try prefix(
      identifier,
      symbol,
      decimalPower(exponent),
      [symbol, identifier],
      source,
      family: .decimal
    )
  }

  private static func binaryPrefix(
    _ identifier: String,
    _ symbol: String,
    _ digits: String,
    _ source: String
  ) throws -> UnitPrefixEntry {
    try prefix(
      identifier,
      symbol,
      .integer(try IntegerValue(digits)),
      [symbol, identifier],
      source,
      family: .binary
    )
  }

  private static func entry(
    _ identifier: String,
    _ symbol: String,
    _ dimension: Dimension,
    _ scale: Int,
    _ aliases: [String],
    _ source: String,
    families: Set<UnitPrefixFamily> = []
  ) throws -> UnitCatalogEntry {
    try entry(
      identifier, symbol, dimension, scale, 1, aliases, source,
      families: families)
  }

  private static func entry(
    _ identifier: String,
    _ symbol: String,
    _ dimension: Dimension,
    _ numerator: Int,
    _ denominator: Int,
    _ aliases: [String],
    _ source: String,
    families: Set<UnitPrefixFamily> = []
  ) throws -> UnitCatalogEntry {
    try entry(
      identifier, symbol, dimension, try fraction(numerator, denominator), aliases, source,
      families: families)
  }

  private static func entry(
    _ identifier: String,
    _ symbol: String,
    _ dimension: Dimension,
    _ scale: NumericValue,
    _ aliases: [String],
    _ source: String,
    families: Set<UnitPrefixFamily> = []
  ) throws -> UnitCatalogEntry {
    UnitCatalogEntry(
      definition: try UnitDefinition(
        canonicalIdentifier: identifier,
        symbol: symbol,
        dimension: dimension,
        transform: .ratio(scale: scale),
        allowedPrefixFamilies: families
      ),
      aliases: aliases,
      exactness: .exact,
      sourceIdentifier: source
    )
  }

  private static func affineEntry(
    _ identifier: String,
    _ symbol: String,
    _ scale: NumericValue,
    _ offset: NumericValue,
    _ aliases: [String],
    _ source: String
  ) throws -> UnitCatalogEntry {
    UnitCatalogEntry(
      definition: try UnitDefinition(
        canonicalIdentifier: identifier,
        symbol: symbol,
        dimension: .temperature,
        transform: .affine(scale: scale, offset: offset)
      ),
      aliases: aliases,
      exactness: .exact,
      sourceIdentifier: source
    )
  }

  private static func affineEntry(
    _ identifier: String,
    _ symbol: String,
    _ scale: Int,
    _ offset: NumericValue,
    _ aliases: [String],
    _ source: String
  ) throws -> UnitCatalogEntry {
    try affineEntry(identifier, symbol, integer(scale), offset, aliases, source)
  }

  private static func approximateEntry(
    _ identifier: String,
    _ symbol: String,
    _ dimension: Dimension,
    _ scale: Double,
    _ aliases: [String],
    _ source: String
  ) throws -> UnitCatalogEntry {
    UnitCatalogEntry(
      definition: try UnitDefinition(
        canonicalIdentifier: identifier,
        symbol: symbol,
        dimension: dimension,
        transform: .ratio(
          scale: .approximate(
            try ApproximateValue(
              estimate: scale,
              source: .binaryFloatingPointConversion,
              precision: .significantDecimalDigits(17)
            )
          )
        )
      ),
      aliases: aliases,
      exactness: .approximate,
      sourceIdentifier: source
    )
  }

  private static func prefix(
    _ identifier: String,
    _ symbol: String,
    _ scale: NumericValue,
    _ aliases: [String],
    _ source: String,
    family: UnitPrefixFamily
  ) throws -> UnitPrefixEntry {
    UnitPrefixEntry(
      prefix: try UnitPrefix(
        canonicalIdentifier: identifier,
        symbol: symbol,
        scale: scale,
        family: family
      ),
      aliases: aliases,
      sourceIdentifier: source
    )
  }

  private static func integer(_ value: Int) -> NumericValue {
    .integer(IntegerValue(value))
  }

  private static func decimalPower(_ exponent: Int) throws -> NumericValue {
    let magnitude = try IntegerValue(
      "1" + String(repeating: "0", count: abs(exponent))
    )
    if exponent >= 0 {
      return .integer(magnitude)
    }
    return .rational(
      try RationalValue(
        numerator: IntegerValue(1),
        denominator: magnitude
      )
    )
  }

  private static func fraction(
    _ numerator: Int,
    _ denominator: Int
  ) throws -> NumericValue {
    if denominator == 1 {
      return integer(numerator)
    }
    return .rational(
      try RationalValue(
        numerator: IntegerValue(numerator),
        denominator: IntegerValue(denominator)
      )
    )
  }

  private static func decimal(_ coefficient: Int, scale: Int) throws -> NumericValue {
    .decimal(
      try DecimalValue(coefficient: IntegerValue(coefficient), scale: scale)
    )
  }

  private static func url(_ string: String) throws -> URL {
    guard let value = URL(string: string) else {
      throw EngineError(code: .invalidUnitDefinition)
    }
    return value
  }
}
