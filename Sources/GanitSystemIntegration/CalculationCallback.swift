import Foundation

public enum CalculationCallbackError: Error, Equatable, Sendable {
  case tooLong
  case unsupportedAction
  case invalidParameters
  case disallowedCallback
}

/// `ganit://x-callback-url/calculate?expression=…&x-success=…&x-error=…`,
/// the one URL action Ganit answers.
///
/// It evaluates the given expression with `ExpressionCalculation` and opens
/// `x-success` with `result` added, or `x-error` with `errorMessage` added. It
/// reads and writes nothing else, so it needs no confirmation: the only thing
/// returned is the answer to the caller's own expression.
public struct CalculationCallback: Equatable, Sendable {
  public static let scheme = "ganit"
  /// The longest URL accepted, with the expression still bounded by
  /// `ExpressionCalculation.maximumSourceUTF8Length`.
  public static let maximumURLLength = 8_192
  public static let maximumCallbackLength = 2_048

  public let expression: String
  public let success: URL?
  public let failure: URL?

  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= Self.maximumURLLength else {
      throw CalculationCallbackError.tooLong
    }
    guard url.scheme == Self.scheme, url.host() == "x-callback-url", url.path() == "/calculate"
    else {
      throw CalculationCallbackError.unsupportedAction
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let names = items.map(\.name)
    guard Set(names).count == names.count,
      Set(names).isSubset(of: ["expression", "x-success", "x-error", "x-cancel", "x-source"]),
      let expression = items.first(where: { $0.name == "expression" })?.value
    else {
      throw CalculationCallbackError.invalidParameters
    }
    self.expression = expression
    success = try Self.callback(items.first { $0.name == "x-success" }?.value)
    failure = try Self.callback(items.first { $0.name == "x-error" }?.value)
  }

  /// The callback to open with the answer or the reason there is none.
  public func response(using calculation: ExpressionCalculation) -> URL? {
    do {
      let answer = try calculation.answer(for: expression)
      return success.map { Self.adding("result", answer, to: $0) }
    } catch {
      return failure.map { Self.adding("errorMessage", error.localizedDescription, to: $0) }
    }
  }

  /// A callback must be an absolute URL for another app; `ganit:` would loop
  /// and `file:` would open local files.
  private static func callback(_ text: String?) throws -> URL? {
    guard let text else {
      return nil
    }
    guard text.utf8.count <= maximumCallbackLength, let url = URL(string: text),
      let scheme = url.scheme?.lowercased(), ![Self.scheme, "file"].contains(scheme)
    else {
      throw CalculationCallbackError.disallowedCallback
    }
    return url
  }

  private static func adding(_ name: String, _ value: String, to url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: name, value: value)]
    return components.url ?? url
  }
}
