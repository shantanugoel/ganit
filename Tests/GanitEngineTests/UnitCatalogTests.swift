import Foundation
import Testing

@testable import GanitEngine

@Suite
struct UnitCatalogTests {
  @Test
  func everyEntryHasResolvableSourceAndConservativeAliases() throws {
    let catalog = try UnitCatalog.minimal()
    let sourceIdentifiers = Set(catalog.sources.map(\.identifier))

    #expect(catalog.entries.count == 26)
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
      ("mi", .length, try fraction(201_168, 125)),
      ("L", .volume, try fraction(1, 1_000)),
      ("kg", .mass, integer(1)),
      ("g", .mass, try fraction(1, 1_000)),
      ("s", .time, integer(1)),
      ("min", .time, integer(60)),
      ("h", .time, integer(3_600)),
      ("K", .temperature, integer(1)),
      ("rad", .angle, integer(1)),
      ("N", .force, integer(1)),
      ("Pa", .pressure, integer(1)),
      ("J", .energy, integer(1)),
      ("W", .power, integer(1)),
      ("bit", .data, integer(1)),
      ("B", .data, integer(8)),
    ]

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

extension NumericValue {
  fileprivate var isApproximate: Bool {
    if case .approximate = self {
      return true
    }
    return false
  }
}
