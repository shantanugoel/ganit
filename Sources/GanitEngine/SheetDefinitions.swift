/// A unit someone defined, such as `1 bag = 25 kg`.
///
/// A custom unit is a ratio of an existing unit, so it carries that unit's
/// dimension and converts through it. Temperatures, which are affine, and
/// plain numbers, which have no dimension, cannot define one.
public struct CustomUnit: Hashable, Sendable {
  public let name: String
  private let definition: UnitDefinition
  private let exactness: UnitDefinitionExactness

  /// The unit `name` refers to, or `nil` when `value` cannot define a unit.
  init?(name: String, value: EngineValue, context: EvaluationContext) {
    guard
      case .quantity(let quantity) = value,
      quantity.kind == .relative,
      case .ratio(let ratio) = quantity.unit,
      let scale = try? NumericOperations(context: context, limits: .default).applying(
        .multiply,
        left: quantity.magnitude,
        right: ratio.scaleToCanonical
      ),
      let definition = try? UnitDefinition(
        canonicalIdentifier: name,
        symbol: name,
        dimension: quantity.unit.dimension,
        transform: .ratio(scale: scale)
      )
    else {
      return nil
    }
    self.name = name
    self.definition = definition
    exactness = definition.transform.isApproximate ? .approximate : .exact
  }

  /// The English plural `name` also answers to, so `3 bags` and `2 boxes`
  /// read naturally.
  var aliases: [String] {
    [name, Self.plural(of: name)]
  }

  private static func plural(of name: String) -> String {
    if ["s", "x", "z"].contains(where: name.hasSuffix)
      || ["ch", "sh"].contains(where: name.hasSuffix)
    {
      return name + "es"
    }
    if name.count > 1, name.hasSuffix("y"), !"aeiou".contains(name.dropLast().last!) {
      return name.dropLast() + "ies"
    }
    return name + "s"
  }

  func entry(aliases: [String]) -> UnitCatalogEntry {
    UnitCatalogEntry(
      definition: definition,
      aliases: aliases,
      exactness: exactness,
      sourceIdentifier: nil
    )
  }
}

/// A function someone defined, such as `area(w, h) = w * h`.
///
/// Its body reads the variables and functions above its definition, as they
/// were there, and its parameters; so a function cannot call itself.
public struct CustomFunction: Hashable, Sendable {
  public let name: String
  public let parameters: [String]
  let body: Expression
  let variables: [String: EngineValue?]
  let functions: [String: CustomFunction]
}

/// What a sheet evaluates with beyond its own lines: variables, units, and
/// functions defined in the definitions sheet, which every sheet shares.
///
/// Definitions stand above a sheet's first line, so a sheet's own
/// declaration of the same name replaces one for the lines below it, and a
/// divider does not clear them.
public struct SheetDefinitions: Hashable, Sendable {
  public static let none = SheetDefinitions()

  public var variables: [String: EngineValue] = [:]
  public var units: [CustomUnit] = []
  public var functions: [String: CustomFunction] = [:]

  public init(
    variables: [String: EngineValue] = [:], units: [CustomUnit] = [],
    functions: [String: CustomFunction] = [:]
  ) {
    self.variables = variables
    self.units = units
    self.functions = functions
  }

  /// What a definitions sheet's source defines, for a caller that answers
  /// without showing it, such as the app at launch.
  public init(source: String, context: EvaluationContext) throws {
    var calculator = SheetCalculator()
    self = try calculator.evaluate(SheetSource(source), context: context).definitions
  }

  public var isEmpty: Bool {
    variables.isEmpty && units.isEmpty && functions.isEmpty
  }
}
