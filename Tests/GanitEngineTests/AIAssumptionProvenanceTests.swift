import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

/// Section 10's provenance row: the badge and the dots follow the dependency
/// graph, not the line numbers, through insertion, deletion, renumbering,
/// function capture and divider clearing.
@Suite
struct AIAssumptionProvenanceTests {
  private static let origin =
    "density = 1 g/ml // AI: Density of water at 4 °C · model · 2026-10-22"

  private struct Marks {
    let text: String
    let isOrigin: Bool
    /// The declared assumptions this line reads, named by their source text.
    let from: [String]
  }

  private func marks(_ source: String) throws -> [Marks] {
    var calculator = SheetCalculator()
    let sheet = SheetSource(source)
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let texts = Dictionary(
      uniqueKeysWithValues: zip(evaluation.lines.map(\.id), sheet.lines.map(\.text)))
    return evaluation.lines.enumerated().map { index, line in
      Marks(
        text: sheet.lines[index].text,
        isOrigin: line.aiAssumption != nil,
        from: line.aiAssumptionOrigins.compactMap { texts[$0] }.sorted()
      )
    }
  }

  private func line(_ source: String, _ prefix: String) throws -> Marks {
    try #require(
      marks(source).first { $0.text.hasPrefix(prefix) }, "no line starting \(prefix)")
  }

  @Test func theDeclaredValueIsMarkedAndOnlyTheLinesThatReadItAreDotted() throws {
    let source = Self.origin + "\nmass = 10 kg\nvolume = mass / density in ml"
    #expect(try line(source, "density = ").isOrigin)
    // An origin reads itself, which is how the editor tells it apart from a
    // reader: the origin gets the badge, and only the readers get a dot.
    #expect(try line(source, "density = ").from == [Self.origin])
    #expect(try line(source, "mass = ").from == [])
    #expect(try line(source, "volume = ").from == [Self.origin])
  }

  @Test func anInsertedLineBetweenTheFactAndItsReaderDoesNotLoseTheDot() throws {
    let before = Self.origin + "\nmass = 10 kg\nvolume = mass / density in ml"
    let after = Self.origin + "\nmass = 10 kg\nrounded = round(mass)\nvolume = mass / density in ml"
    let beforeDots = try line(before, "volume = ").from
    let afterDots = try line(after, "volume = ").from
    #expect(beforeDots == afterDots)
    #expect(try line(after, "rounded = ").from == [])
  }

  @Test func deletingTheDeclaredValueTakesEveryDotWithIt() throws {
    let kept = Self.origin + "\nmass = 10 kg\nvolume = mass / density in ml"
    let removed = "mass = 10 kg\nvolume = mass / density in ml"
    #expect(try line(kept, "volume = ").from == [Self.origin])
    let after = try marks(removed)
    #expect(after.allSatisfy { !$0.isOrigin && $0.from.isEmpty })
  }

  @Test func aFunctionThatReadsTheFactMarksEveryLineThatCallsIt() throws {
    let source = Self.origin + "\nvolume_of(mass) = mass / density in ml\nwater = volume_of(10 kg)"
    #expect(try line(source, "volume_of(").from == [Self.origin])
    #expect(try line(source, "water = ").from == [Self.origin])
    // A second reader keeps its own dot.
    let twice = source + "\nsanitizer = volume_of(5 kg)"
    #expect(try line(twice, "sanitizer = ").from == [Self.origin])
  }

  @Test func anExplicitLineReferenceCarriesTheMarkAndRenumberingDoesNotBreakIt() throws {
    let referenced = Self.origin + "\nmass = 10 kg\nvolume = mass / density in ml\n---\n@3 + 1"
    #expect(try line(referenced, "@3 + 1").from == [Self.origin])
    // One more line above, and the same reference renumbered by one: the mark
    // travels with the line it names, not with the number.
    let renumbered =
      Self.origin + "\nnote = 1\nmass = 10 kg\nvolume = mass / density in ml\n---\n@4 + 1"
    #expect(try line(renumbered, "@4 + 1").from == [Self.origin])
  }

  @Test func aDividerStartsANewScopeSoANameThereDoesNotInheritTheMark() throws {
    let source =
      Self.origin + "\nuses = density * 2\n---\ndensity = 3\nreads = density * 2"
    #expect(try line(source, "uses = ").from == [Self.origin])
    #expect(try line(source, "density = 3").from == [])
    #expect(try line(source, "reads = ").from == [])
  }

  @Test func anOrdinaryValueWithTheSameShapeCarriesNoMarkAtAll() throws {
    // Nothing here came from a model: no origin comment, no badge, no dots.
    let source = "density = 1 g/ml\nmass = 10 kg\nvolume = mass / density in ml"
    let all = try marks(source)
    #expect(all.allSatisfy { !$0.isOrigin && $0.from.isEmpty })
  }

  @Test func aCommentThatIsNotAWellFormedOriginIsJustAComment() throws {
    for text in [
      "density = 1 g/ml // AI: no model or date",
      "density = 1 g/ml // AI: basis · model · not-a-date",
      "density = 1 g/ml // AI: basis · model · 2026-13-45",
      "density = mass * 2 // AI: basis · model · 2026-10-22",
    ] {
      let source = text + "\nmass = 10 kg\nvolume = density + 1"
      let all = try marks(source)
      #expect(all.allSatisfy { !$0.isOrigin }, "\(text) is not an origin")
      #expect(all.allSatisfy { $0.from.isEmpty }, "\(text) marks nothing")
    }
  }
}
