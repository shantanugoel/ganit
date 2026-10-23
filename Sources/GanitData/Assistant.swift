import Foundation

/// The endpoint rules for Ask requests.
public enum Assistant {
  public static func chatCompletionsURL(_ endpoint: URL) -> URL {
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    var path = parts.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    if path.lowercased().hasSuffix("/chat/completions") {
      parts.percentEncodedPath = path
      return parts.url!
    }
    return apiBaseURL(endpoint).appending(path: "chat/completions")
  }

  static func apiBaseURL(_ endpoint: URL) -> URL {
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    var path = parts.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    let suffix = "/chat/completions"
    if path.lowercased().hasSuffix(suffix) {
      path.removeLast(suffix.count)
    } else if path.isEmpty {
      path = "/v1"
    }
    parts.percentEncodedPath = path
    return parts.url!
  }

  /// A hosted model must be reached over HTTPS. A model running on this Mac
  /// answers over plain HTTP on the loopback address, where nothing leaves the
  /// machine.
  public static func isAllowed(_ url: URL) -> Bool {
    switch url.scheme {
    case "https":
      return url.host() != nil
    case "http":
      return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host() ?? "")
    default:
      return false
    }
  }

}
