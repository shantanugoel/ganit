import Foundation

/// Connection defaults and authentication for Chat Completions providers.
public enum AssistantProvider: String, CaseIterable, Sendable {
  case openAI, openRouter, ollama, lmStudio, custom

  public var defaultEndpoint: URL? {
    switch self {
    case .openAI: URL(string: "https://api.openai.com/v1")
    case .openRouter: URL(string: "https://openrouter.ai/api/v1")
    case .ollama: URL(string: "http://localhost:11434/v1")
    case .lmStudio: URL(string: "http://localhost:1234/v1")
    case .custom: nil
    }
  }

  public var requiresKey: Bool { self == .openAI || self == .openRouter }

  public func authorization(apiKey: String) throws -> String? {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      if requiresKey { throw ProviderFailure(status: nil, category: .authentication) }
      return nil
    }
    return "Bearer " + key
  }

  public func modelsURL(_ endpoint: URL) -> URL {
    Assistant.apiBaseURL(endpoint).appending(path: self == .openRouter ? "models/user" : "models")
  }
}

/// Unsaved connection edits cannot change the saved Keychain item.
public struct AssistantConnectionDraft: Sendable {
  public private(set) var provider: AssistantProvider
  public private(set) var endpoint: String
  public var apiKey: String

  public init(settings: AssistantSettings) {
    provider = settings.provider
    endpoint = settings.endpoint.absoluteString
    apiKey = settings.apiKey
  }

  public mutating func selectProvider(_ value: AssistantProvider) {
    guard value != provider else { return }
    provider = value
    apiKey = ""
    if let address = value.defaultEndpoint { endpoint = address.absoluteString }
  }

  public mutating func setEndpoint(_ value: String) {
    guard value != endpoint else { return }
    if Self.origin(value) == nil || Self.origin(value) != Self.origin(endpoint) { apiKey = "" }
    endpoint = value
  }

  private static func origin(_ text: String) -> String? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased()
    else { return nil }
    let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
    return "\(scheme)://\(host):\(port)"
  }
}
