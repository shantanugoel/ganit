import GanitData

/// Use fixed messages. Server messages can contain credentials or request data.
public enum ProviderErrorMessages {
  public static func message(for category: ProviderErrorCategory) -> String {
    switch category {
    case .authentication:
      localized(
        "provider.error.authentication",
        "The provider rejected the credentials. Check the API key and access permissions.")
    case .model:
      localized(
        "provider.error.model",
        "The model is unknown or unavailable. Check the model identifier and your access. A model list does not confirm Chat Completions support."
      )
    case .parameter:
      localized(
        "provider.error.parameter",
        "The provider rejected a request parameter. The model may not support Chat Completions or the Ganit reply format."
      )
    case .rateLimit:
      localized(
        "provider.error.rateLimit",
        "The provider reported a rate or usage limit. Check your account limits before you try again."
      )
    case .server:
      localized("provider.error.server", "The provider reported a server failure. Try again later.")
    case .contextLimit:
      localized(
        "provider.error.contextLimit",
        "The request exceeds the model context limit. Select fewer lines or use a different model.")
    case .request:
      localized(
        "provider.error.request",
        "The provider rejected the request. Check the connection and model settings.")
    case .unknown:
      localized(
        "provider.error.unknown",
        "The provider could not complete the request. The model may not support Chat Completions or the Ganit reply format."
      )
    }
  }
}
