import Foundation

public enum ProviderErrorCategory: String, Sendable {
  case authentication, model, parameter, rateLimit, server, contextLimit, request, unknown
}

public enum ProviderOptionalParameter: String, Sendable {
  case responseFormat = "response_format"
  case reasoningEffort = "reasoning_effort"
}

/// Keep structured error details. Do not retain or display the server message.
public struct ProviderFailure: Error, Equatable, Sendable {
  public let status: Int?
  public let code: String?
  public let type: String?
  public let parameter: String?
  public let category: ProviderErrorCategory
  private let rejectedParameter: ProviderOptionalParameter?

  public init(status: Int?, category: ProviderErrorCategory) {
    self.status = status
    self.category = category
    code = nil
    type = nil
    parameter = nil
    rejectedParameter = nil
  }

  private init(status: Int, error: Any?) {
    let fields = error as? [String: Any] ?? [:]
    func text(_ value: Any?) -> String? {
      if let string = value as? String { return String(string.prefix(256)) }
      if let number = value as? NSNumber { return number.stringValue }
      return nil
    }
    self.status = status
    code = text(fields["code"])
    type = text(fields["type"])
    let message = (fields["message"] as? String ?? error as? String ?? "").lowercased()
    parameter = text(fields["param"] ?? fields["parameter"]) ?? Self.parameter(in: message)
    let tags = [code, type].compactMap { $0?.lowercased() }
    let tag = tags.joined(separator: " ")
    let effectiveStatus = Int(code ?? "") ?? status
    let identifiedParameter = parameter
    let field = ProviderOptionalParameter.all.first { candidate in
      identifiedParameter == candidate.rawValue
        || identifiedParameter?.hasPrefix(candidate.rawValue + ".") == true
        || identifiedParameter?.hasPrefix(candidate.rawValue + "[") == true
        || (identifiedParameter == nil && Self.mentions(candidate.rawValue, in: message))
    }
    let rejection =
      [
        "unsupported", "not supported", "does not support", "invalid", "unknown", "unrecognized",
        "not allowed", "not permitted",
      ].contains { message.contains($0) }
      || [
        "unsupported_parameter", "unsupported_value", "invalid_parameter", "invalid_value",
        "unknown_parameter", "invalid_request_error",
      ].contains { tags.contains($0) }

    // Known unrelated failures take priority over field names in messages.
    if [401, 403].contains(status) || [401, 403].contains(effectiveStatus)
      || ["auth", "api_key", "permission_denied", "access_denied"].contains(where: tag.contains)
    {
      category = .authentication
    } else if status == 429 || effectiveStatus == 429
      || ["rate_limit", "insufficient_quota", "insufficient_credits", "spend_limit", "usage_limit"]
        .contains(where: tag.contains)
    {
      category = .rateLimit
    } else if [
      "context_length", "context_limit", "token_limit", "max_tokens", "too_many_tokens",
      "prompt_too_long",
    ].contains(where: tag.contains) {
      category = .contextLimit
    } else if [
      "model_not_found", "model_unavailable", "invalid_model", "model_not_available",
      "no_available_model", "no_endpoints", "model_not_supported",
    ].contains(where: tag.contains) || parameter == "model" {
      category = .model
    } else if status >= 500 || effectiveStatus >= 500
      || ["server_error", "service_unavailable", "server_is_overloaded", "provider_error"].contains(
        where: tag.contains)
    {
      category = .server
    } else if [
      "content_policy", "content_filter", "moderation", "guardrail", "insufficient_credit",
    ].contains(where: tag.contains) || effectiveStatus == 402 {
      category = .request
    } else if field != nil && rejection {
      category = .parameter
    } else if parameter != nil || field != nil {
      category = .request
    } else if message.contains("model")
      && ["not found", "does not exist", "unavailable", "no endpoints"].contains(
        where: message.contains)
    {
      category = .model
    } else if ["context length", "context window", "too many tokens"].contains(
      where: message.contains)
    {
      category = .contextLimit
    } else {
      category = .unknown
    }
    rejectedParameter = category == .parameter ? field : nil
  }

  /// Apply only to fields that were present in this rejected wire request.
  public func fallback(structured: Bool, effort: Bool) -> (structured: Bool, effort: Bool)? {
    guard let status, [400, 422].contains(status) else { return nil }
    switch (category, rejectedParameter) {
    case (.parameter, .responseFormat?) where structured: return (false, effort)
    case (.parameter, .reasoningEffort?) where effort: return (structured, false)
    case (.unknown, nil) where parameter == nil && (structured || effort): return (false, false)
    default: return nil
    }
  }

  static func decode(_ data: Data, status: Int, requireError: Bool = false) -> ProviderFailure? {
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if let error = root?["error"], !(error is NSNull) {
      return ProviderFailure(status: status, error: error)
    }
    if let choices = root?["choices"] as? [[String: Any]] {
      for choice in choices {
        if let error = choice["error"], !(error is NSNull) {
          return ProviderFailure(status: status, error: error)
        }
        if choice["finish_reason"] as? String == "error" {
          return ProviderFailure(status: status, category: .server)
        }
      }
    }
    return requireError
      ? ProviderFailure(
        status: status, error: root == nil ? String(data: data, encoding: .utf8) : nil)
      : nil
  }

  private static func parameter(in message: String) -> String? {
    // Accept explicit field labels. Do not guess from general error prose.
    let pattern = #"\b(?:parameter|argument|field)\s*[:=]\s*[`'"]?([a-z_][a-z0-9_.\[\]]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
      let range = Range(match.range(at: 1), in: message)
    else { return nil }
    return String(message[range].prefix(256))
  }

  private static func mentions(_ field: String, in message: String) -> Bool {
    message.components(
      separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
    ).contains(field)
  }
}

extension ProviderOptionalParameter {
  fileprivate static let all: [Self] = [.responseFormat, .reasoningEffort]
}
