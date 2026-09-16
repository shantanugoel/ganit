import Foundation
import Testing

@testable import GanitEngine

@Suite
struct UnitCatalogTests {
  @Test
  func everyEntryHasResolvableSourceAndConservativeAliases() throws {
    let catalog = try UnitCatalog.minimal()
    let sourceIdentifiers = Set(catalog.sources.map(\.identifier))

    #expect(catalog.entries.count == 55)
    #expect(catalog.prefixes.count == 34)
    #expect(catalog.sources.count == 3)
    for entry in catalog.entries {
      // Every built-in unit encodes a data source; only a person's own unit
      // has none.
      #expect(sourceIdentifiers.contains(try #require(entry.sourceIdentifier)))
      #expect(!entry.aliases.isEmpty)
      for alias in entry.aliases {
        #expect(catalog.unit(matching: alias) == entry)
      }
    }
    for prefix in catalog.prefixes {
      #expect(sourceIdentifiers.contains(prefix.sourceIdentifier))
      for alias in prefix.aliases {
        #expect(catalog.prefix(matching: alias) == prefix)
      }
    }

    #expect(catalog.unit(matching: "m")?.definition.symbol == "m")
    #expect(catalog.prefix(matching: "m")?.prefix.symbol == "m")
    #expect(catalog.prefix(matching: "M")?.prefix.symbol == "M")
    #expect(catalog.unit(matching: "Meter") == nil)
    #expect(catalog.unit(matching: "miles")?.definition.symbol == "mi")
    #expect(catalog.unit(matching: "lbs")?.definition.symbol == "lb")
  }

  @Test
  func spellsLitersInLowercaseAndTakesMilliFromThePrefix() throws {
    let catalog = try UnitCatalog.minimal()

    for alias in ["L", "l", "liter", "litres"] {
      #expect(catalog.resolveUnit(matching: alias)?.entry.definition.symbol == "L")
      #expect(catalog.resolveUnit(matching: alias)?.prefix == nil)
    }
    for alias in ["ml", "mL", "milliliter", "millilitres"] {
      let resolved = try #require(catalog.resolveUnit(matching: alias))
      #expect(resolved.entry.definition.symbol == "L")
      #expect(resolved.prefix?.prefix.symbol == "m")
    }

    // An exact alias still wins over a prefix reading, so a gallon is not
    // a gram of liters and a pint is not a pico-tonne.
    #expect(catalog.resolveUnit(matching: "gal")?.prefix == nil)
    #expect(catalog.resolveUnit(matching: "pt")?.entry.definition.symbol == "pt")
  }

  @Test
  func convertsBetweenTheUnitsPeopleMeasureEverydayThingsIn() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()

    func unit(_ alias: String) throws -> UnitExpression {
      let resolved = try #require(catalog.resolveUnit(matching: alias))
      guard let prefix = resolved.prefix else {
        return try algebra.unit(resolved.entry.definition)
      }
      return try algebra.unit(
        try algebra.applying(prefix.prefix, to: resolved.entry.definition)
      )
    }

    func converted(_ magnitude: Int, _ from: String, to target: String) throws -> NumericValue {
      try algebra.converted(
        QuantityValue(magnitude: integer(magnitude), unit: try unit(from)),
        to: try unit(target)
      ).magnitude
    }

    #expect(try converted(1, "L", to: "ml") == integer(1_000))
    #expect(try converted(1, "gal", to: "cup") == integer(16))
    #expect(try converted(1, "cup", to: "tbsp") == integer(16))
    #expect(try converted(1, "tbsp", to: "tsp") == integer(3))
    #expect(try converted(1, "qt", to: "pt") == integer(2))
    #expect(try converted(1, "t", to: "kg") == integer(1_000))
    #expect(try converted(1, "st", to: "lb") == integer(14))
    #expect(try converted(1, "yd", to: "ft") == integer(3))
    #expect(try converted(1, "bar", to: "Pa") == integer(100_000))
    #expect(try converted(1, "atm", to: "Pa") == integer(101_325))
    #expect(try converted(1, "kcal", to: "cal") == integer(1_000))
    #expect(try converted(1, "kWh", to: "J") == integer(3_600_000))
  }

  @Test
  func labelsExactAndApproximateDefinitionsHonestly() throws {
    let catalog = try UnitCatalog.minimal()
    let approximate = catalog.entries.filter { $0.exactness == .approximate }

    #expect(approximate.map(\.definition.canonicalIdentifier) == ["degree"])
    for entry in catalog.entries where entry.exactness == .exact {
      switch entry.definition.transform {
      case .ratio(let scale):
        #expect(!scale.isApproximate)
      case .affine(let scale, let offset):
        #expect(!scale.isApproximate)
        #expect(!offset.isApproximate)
      }
    }
  }

  @Test
  func catalogFactsDriveExactAndAffineConversions() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let meter = try algebra.unit(try definition("m", in: catalog))
    let foot = try algebra.unit(try definition("ft", in: catalog))
    let celsius = try algebra.unit(try definition("°C", in: catalog))
    let fahrenheit = try algebra.unit(try definition("°F", in: catalog))
    let byte = try algebra.unit(try definition("B", in: catalog))
    let bit = try algebra.unit(try definition("bit", in: catalog))

    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(381), unit: meter),
        to: foot
      ).magnitude == integer(1_250)
    )
    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(0), unit: celsius),
        to: fahrenheit
      ).magnitude == integer(32)
    )
    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(1), unit: byte),
        to: bit
      ).magnitude == integer(8)
    )

    let kilometer = try algebra.unit(
      algebra.applying(
        try #require(catalog.prefix(matching: "k")?.prefix),
        to: try definition("m", in: catalog)
      )
    )
    let mile = try algebra.unit(try definition("mi", in: catalog))
    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(12), unit: kilometer),
        to: mile
      ).magnitude
        == .rational(
          try RationalValue(
            numerator: IntegerValue(31_250),
            denominator: IntegerValue(4_191)
          )
        )
    )
  }

  @Test
  func locksEveryRatioUnitFactorAndDimension() throws {
    let catalog = try UnitCatalog.minimal()
    let expected: [(String, GanitEngine.Dimension, NumericValue)] = [
      ("m", .length, integer(1)),
      ("in", .length, try fraction(127, 5_000)),
      ("ft", .length, try fraction(381, 1_250)),
      ("yd", .length, try fraction(9_144, 10_000)),
      ("mi", .length, try fraction(201_168, 125)),
      ("ha", .area, integer(10_000)),
      ("ac", .area, try fraction(40_468_564_224, 10_000_000)),
      ("L", .volume, try fraction(1, 1_000)),
      ("gal", .volume, try fraction(3_785_411_784, 1_000_000_000_000)),
      ("qt", .volume, try fraction(3_785_411_784, 4_000_000_000_000)),
      ("pt", .volume, try fraction(3_785_411_784, 8_000_000_000_000)),
      ("cup", .volume, try fraction(3_785_411_784, 16_000_000_000_000)),
      ("floz", .volume, try fraction(3_785_411_784, 128_000_000_000_000)),
      ("tbsp", .volume, try fraction(3_785_411_784, 256_000_000_000_000)),
      ("tsp", .volume, try fraction(3_785_411_784, 768_000_000_000_000)),
      ("kg", .mass, integer(1)),
      ("t", .mass, integer(1_000)),
      ("lb", .mass, try fraction(45_359_237, 100_000_000)),
      ("oz", .mass, try fraction(45_359_237, 1_600_000_000)),
      ("st", .mass, try fraction(635_029_318, 100_000_000)),
      ("g", .mass, try fraction(1, 1_000)),
      ("s", .time, integer(1)),
      ("min", .time, integer(60)),
      ("h", .time, integer(3_600)),
      ("K", .temperature, integer(1)),
      ("rad", .angle, integer(1)),
      ("N", .force, integer(1)),
      ("Pa", .pressure, integer(1)),
      ("bar", .pressure, integer(100_000)),
      ("atm", .pressure, integer(101_325)),
      ("psi", .pressure, try fraction(44_482_216_152_605, 6_451_600_000)),
      ("J", .energy, integer(1)),
      ("cal", .energy, try fraction(523, 125)),
      ("Wh", .energy, integer(3_600)),
      ("W", .power, integer(1)),
      ("mph", .speed, try fraction(44_704, 100_000)),
      ("bit", .data, integer(1)),
      ("bps", .dataRate, integer(1)),
      ("B", .data, integer(8)),
      ("hp", .power, try fraction(37_284_993_579_113_511, 50_000_000_000_000)),
      (
        "eV", .energy,
        .decimal(try DecimalValue(coefficient: IntegerValue(1_602_176_634), scale: 28))
      ),
      ("A", .current, integer(1)),
      ("V", .voltage, integer(1)),
      ("Ω", .resistance, integer(1)),
      ("F", .capacitance, integer(1)),
      ("H", .inductance, integer(1)),
      ("C", .charge, integer(1)),
      ("Ah", .charge, integer(3_600)),
      ("Hz", .frequency, integer(1)),
      ("nmi", .length, integer(1_852)),
      ("kn", .speed, try fraction(463, 900)),
      (
        "mpg", try GanitEngine.Dimension(exponents: [.length: -2]),
        try fraction(201_168_000_000_000_000, 473_176_473_000)
      ),
    ]

    // Every ratio unit is locked above; only the affine and approximate
    // entries are absent.
    let locked = Set(expected.map(\.0))
    let unlocked = catalog.entries.filter { entry in
      entry.exactness == .exact && entry.definition.transform.isRatio
        && !entry.aliases.contains(where: locked.contains)
    }
    #expect(unlocked.isEmpty)

    for (alias, dimension, scale) in expected {
      let definition = try definition(alias, in: catalog)
      #expect(definition.dimension == dimension)
      #expect(definition.transform == .ratio(scale: scale))
    }
  }

  @Test
  func decimalAndBinaryPrefixesRemainDistinct() throws {
    let catalog = try UnitCatalog.minimal()
    let algebra = try unitAlgebra()
    let byte = try definition("B", in: catalog)
    let mega = try #require(catalog.prefix(matching: "M")?.prefix)
    let mebi = try #require(catalog.prefix(matching: "Mi")?.prefix)
    let base = try algebra.unit(byte)
    let megabyte = try algebra.unit(algebra.applying(mega, to: byte))
    let mebibyte = try algebra.unit(algebra.applying(mebi, to: byte))

    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(1), unit: megabyte),
        to: base
      ).magnitude == integer(1_000_000)
    )
    #expect(throws: EngineError.self) {
      try algebra.applying(
        mebi,
        to: try definition("m", in: catalog)
      )
    }
    #expect(
      try algebra.converted(
        QuantityValue(magnitude: integer(1), unit: mebibyte),
        to: base
      ).magnitude == integer(1_048_576)
    )
  }

  @Test
  func attributionContainsEverySourceAndItsTerms() throws {
    let catalog = try UnitCatalog.minimal()
    for source in catalog.sources {
      #expect(catalog.attributionMarkdown.contains(source.title))
      #expect(catalog.attributionMarkdown.contains(source.revision))
      #expect(catalog.attributionMarkdown.contains(source.url.absoluteString))
      #expect(catalog.attributionMarkdown.contains(source.licenseName))
      #expect(
        catalog.attributionMarkdown.contains(source.licenseURL.absoluteString)
      )
    }
    for entry in catalog.entries {
      #expect(
        catalog.attributionMarkdown.contains(
          "`\(entry.definition.canonicalIdentifier)`"
        )
      )
    }
  }

  @Test
  func rejectsIncompleteSourceMetadata() throws {
    let invalid = UnitSourceMetadata(
      identifier: "invalid",
      title: "",
      revision: "",
      url: try #require(URL(string: "http://example.com")),
      licenseName: "",
      licenseURL: try #require(URL(string: "http://example.com")),
      notice: ""
    )
    #expect(throws: EngineError.self) {
      try UnitCatalog(entries: [], prefixes: [], sources: [invalid])
    }
  }

  private func definition(
    _ alias: String,
    in catalog: UnitCatalog
  ) throws -> UnitDefinition {
    try #require(catalog.unit(matching: alias)?.definition)
  }

  private func integer(_ value: Int) -> NumericValue {
    .integer(IntegerValue(value))
  }

  private func fraction(
    _ numerator: Int,
    _ denominator: Int
  ) throws -> NumericValue {
    .rational(
      try RationalValue(
        numerator: IntegerValue(numerator),
        denominator: IntegerValue(denominator)
      )
    )
  }

  private func unitAlgebra() throws -> UnitAlgebra {
    let timeZone = try #require(TimeZone(identifier: "UTC"))
    return UnitAlgebra(
      context: try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: try PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 1_700_000_000),
        calendar: Calendar(identifier: .gregorian),
        timeZone: timeZone
      )
    )
  }
}

extension UnitTransform {
  fileprivate var isRatio: Bool {
    if case .ratio = self {
      return true
    }
    return false
  }
}

extension NumericValue {
  fileprivate var isApproximate: Bool {
    if case .approximate = self {
      return true
    }
    return false
  }
}
