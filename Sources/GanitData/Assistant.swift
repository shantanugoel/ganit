import Foundation

/// The endpoint rules for Ask requests.
public enum Assistant {
  public static func chatCompletionsURL(_ endpoint: URL) -> URL {
    var path = endpoint.path
    if path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    let lowered = path.lowercased()
    if lowered.hasSuffix("/chat/completions") || lowered == "/chat/completions" {
      return endpoint
    }
    if path.isEmpty || path == "/" {
      return endpoint.appending(path: "v1/chat/completions")
    }
    return endpoint.appending(path: "chat/completions")
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
