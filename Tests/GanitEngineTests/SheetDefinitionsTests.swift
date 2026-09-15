import Foundation
import Testing

@testable import GanitEngine

@Suite
struct SheetDefinitionsTests {
  @Test
  func reportsTheVariablesAndUnitsASheetDefines() throws {
    let defined = try definitions(of: "rate = 90 USD\n1 bag = 25 kg\n2 + 2")

    #expect(defined.variables.keys.sorted() == ["rate"])
    #expect(defined.units.map(\.name) == ["bag"])
    #expect(try definitions(of: "2 + 2").isEmpty)
  }

  @Test
  func evaluatesASheetWithVariablesDefinedElsewhere() throws {
    let inherited = try definitions(of: "hourly rate = 90\nweekly days = 4")
    #expect(inherited.variables.keys.sorted() == ["hourly rate", "weekly days"])

    #expect(try answers("hourly rate * weekly days", inherited) == ["360"])
    // Definitions stand above the first line, so a divider does not clear
    // them, and a sheet's own declaration replaces one for the lines below.
    #expect(
      try answers("hourly rate = 100\nhourly rate\n---\nhourly rate", inherited)
        == ["100", "100", nil, "90"])
  }

  @Test
  func measuresWithAUnitDefinedElsewhere() throws {
    let inherited = try definitions(of: "1 bag = 25 kg\n1 box = 3 kg")

    #expect(try answers("3 bags in kg", inherited) == ["75 kg"])
    #expect(try answers("2 boxes in kg", inherited) == ["6 kg"])
    #expect(try answers("1 bag + 5 kg in bags", inherited) == ["6/5 bag"])
    #expect(try answers("2 bags in liters", inherited) == ["incompatibleDimensions"])
  }

  @Test
  func usesAUnitFromTheLineBelowItsDefinition() throws {
    // A unit is vocabulary for the lines below it, so it works in the sheet
    // that defines it, composes with an earlier one, and outlives a divider.
    #expect(
      try answers("2 boxes\n1 box = 3 kg\n2 boxes in kg\n1 pallet = 40 boxes\n---\n1 pallet in kg")
        == ["unexpectedToken", "3 kg", "6 kg", "40 box", nil, "120 kg"])
  }

  @Test
  func reusesLinesBelowADefinitionThatHasNotChanged() throws {
    var calculator = SheetCalculator()
    let context = try sheetContext()
    _ = try calculator.evaluate(SheetSource("1 box = 3 kg\n2 boxes\n5 kg"), context: context)
    let sheet = SheetSource("1 box = 3 kg\n2 boxes\n6 kg")

    let again = try calculator.evaluate(sheet, context: context)

    #expect(again.evaluatedLineIDs == [try #require(sheet.lines.last?.id)])
  }

  @Test
  func refusesAUnitItCannotDefineInsteadOfDefiningNothing() throws {
    #expect(try answers("1 dozen = 12") == ["invalidUnitDefinition"])
    #expect(try answers("1 warmth = 20 °C") == ["invalidUnitDefinition"])
    #expect(try answers("1 fee = 5 USD") == ["invalidUnitDefinition"])
    #expect(try definitions(of: "1 dozen = 12").units.isEmpty)
  }

  @Test
  func refusesToRedefineAUnitADataSourceNames() throws {
    #expect(try answers("1 km = 5 m") == ["invalidVariableName"])
    #expect(try definitions(of: "1 km = 5 m").units.isEmpty)
  }

  @Test
  func definesAUnitOnlyWhereAVariableCannotBeNamed() throws {
    // A name starting with `1` is never a variable, so an everyday name that
    // begins with the word `unit` is still a variable.
    let defined = try definitions(of: "unit price = 5\nunit weight = 2 kg")

    #expect(defined.units.isEmpty)
    #expect(defined.variables.keys.sorted() == ["unit price", "unit weight"])
    #expect(try answers("unit price * 3", defined) == ["15"])
  }

  @Test
  func declaresARateRatherThanAUnitForACurrency() throws {
    // A manual rate keeps its meaning and defines nothing a sheet inherits;
    // money syntax pins how it converts.
    #expect(try definitions(of: "1 USD = 83.25 INR").isEmpty)
  }

  @Test
  func keepsAPluralOnlyWhenItIsFree() throws {
    // `bin`'s plural would be `bins`, which is free, but `in` already means
    // inch, so a unit cannot be named `in` at all.
    #expect(try definitions(of: "1 in = 2 kg").units.isEmpty)

    let inherited = try definitions(of: "1 bin = 2 kg")
    #expect(try answers("3 bins + 1 bin in kg", inherited) == ["8 kg"])
  }

  @Test
  func replacesAnEarlierDefinitionOfTheSameName() throws {
    let inherited = try definitions(
      of: "1 bag = 25 kg\n1 bag = 10 kg\nrate = 1\nrate = 2")

    #expect(try answers("1 bag in kg", inherited) == ["10 kg"])
    #expect(try answers("rate", inherited) == ["2"])
  }

  /// What a sheet's own lines define.
  private func definitions(of source: String) throws -> SheetDefinitions {
    var calculator = SheetCalculator()
    return try calculator.evaluate(SheetSource(source), context: try sheetContext()).definitions
  }

  /// Each line's answer as digits and a symbol, or its failure's code.
  private func answers(
    _ source: String,
    _ definitions: SheetDefinitions = .none
  ) throws -> [String?] {
    var calculator = SheetCalculator(definitions: definitions)
    return try calculator.evaluate(SheetSource(source), context: try sheetContext()).lines.map {
      switch $0.result {
      case nil:
        return nil
      case .value(let value):
        return describe(value)
      case .syntaxFailure(let diagnostics):
        return diagnostics.first.map { unqualified($0.code.rawValue) }
      case .evaluationFailure(let error):
        return unqualified(error.code.rawValue)
      }
    }
  }

  private func unqualified(_ code: String) -> String {
    String(code.split(separator: ".").last ?? "")
  }

  private func describe(_ value: EngineValue) -> String {
    switch value {
    case .quantity(let quantity):
      return "\(digits(quantity.magnitude)) \(quantity.unit.symbol)"
    case .number(let number):
      return digits(number)
    default:
      return "value"
    }
  }

  private func digits(_ value: NumericValue) -> String {
    switch value {
    case .integer(let integer):
      return integer.canonicalDigits
    case .rational(let rational):
      return "\(rational.numerator.canonicalDigits)/\(rational.denominator.canonicalDigits)"
    case .decimal(let decimal):
      return "\(decimal.coefficient.canonicalDigits)e-\(decimal.scale)"
    case .approximate(let approximate):
      return "~\(approximate.estimate)"
    }
  }
}
