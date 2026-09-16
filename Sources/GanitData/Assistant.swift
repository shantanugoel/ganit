import Foundation

public enum AssistantError: Error, Equatable, Sendable {
  case disallowedURL
  case unexpectedStatus(Int)
  case payloadTooLarge(Int)
  case malformedPayload
}

/// Asks a model about a line Ganit could not work out, such as
/// `10 kg of water in ml`.
///
/// One request carries one line: the text of that line, and nothing else from
/// the sheet, the library, or this Mac. An assistant is used for one request
/// and then finished with, so no connection outlives an answer.
public final class Assistant: NSObject, URLSessionTaskDelegate {
  /// What the model is asked to do. The answer column only has room for a
  /// value, so the instruction asks for JSON and forbids working.
  static let instruction = """
    You convert one calculator line into a single value. \
    Reply with JSON only, of the form {"value":"<amount and unit>"}. \
    The value must be something a calculator can parse, such as 10000 ml, 32 C, or 3.14. \
    No markdown, no working, no sentence, no extra keys. \
    If there is no such answer, {"value":"UNKNOWN"}.
    """

  /// Longer lines are prose, not questions, and are never sent.
  static let maximumLine = 500
  /// A reply longer than this, after cleanup, is an explanation, not a value.
  static let maximumAnswer = 120
  static let maximumPayload = 256 * 1_024
  /// Local models may still be loading; a short timeout looks like a wrong
  /// answer. The sheet stays editable while this runs.
  static let requestTimeout: TimeInterval = 120
  static let resourceTimeout: TimeInterval = 180

  private let settings: AssistantSettings
  private let session: URLSession

  public init(settings: AssistantSettings) {
    self.settings = settings
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = Self.requestTimeout
    configuration.timeoutIntervalForResource = Self.resourceTimeout
    // Replace the system defaults, which name the OS version and the
    // user's preferred languages.
    configuration.httpAdditionalHeaders = ["User-Agent": "Ganit", "Accept-Language": "*"]
    session = URLSession(configuration: configuration)
    super.init()
  }

  /// OpenAI-compatible servers, including llama-swap, name a base such as
  /// `https://host/v1`. The request is a POST to `chat/completions` under
  /// that base. An address that already ends there is left alone.
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

  /// The answer to a line, or `nil` when the model has none.
  public func answer(to line: String) async throws -> String? {
    defer { session.finishTasksAndInvalidate() }
    let asked = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !asked.isEmpty, asked.count <= Self.maximumLine else {
      return nil
    }
    var structured = true
    while true {
      let (data, response) = try await session.data(
        for: try request(for: asked, structured: structured), delegate: self)
      guard let status = (response as? HTTPURLResponse)?.statusCode else {
        throw AssistantError.malformedPayload
      }
      if status == 400 || status == 422, structured {
        structured = false
        continue
      }
      guard status == 200 else {
        throw AssistantError.unexpectedStatus(status)
      }
      guard data.count <= Self.maximumPayload else {
        throw AssistantError.payloadTooLarge(data.count)
      }
      guard let reply = try? JSONDecoder().decode(ChatCompletion.self, from: data) else {
        throw AssistantError.malformedPayload
      }
      return AssistantReply.value(
        content: reply.choices.first?.message.content,
        reasoning: reply.choices.first?.message.reasoningContent
      )
    }
  }

  /// The only request Ganit sends for a line.
  func request(for line: String, structured: Bool = true) throws -> URLRequest {
    guard Self.isAllowed(settings.endpoint) else {
      throw AssistantError.disallowedURL
    }
    var request = URLRequest(url: Self.chatCompletionsURL(settings.endpoint))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // A model on this Mac usually wants no key at all.
    if !settings.apiKey.isEmpty {
      request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(
      ChatRequest(
        model: settings.model,
        messages: [
          ChatRequest.Message(role: "system", content: Self.instruction),
          ChatRequest.Message(role: "user", content: line),
        ],
        structured: structured
      )
    )
    return request
  }

  /// A redirect to anywhere else would carry the line, and the key, somewhere
  /// the settings never named.
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

private struct ChatRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct ResponseFormat: Encodable {
    let type: String
  }

  let model: String
  let messages: [Message]
  let structured: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(false, forKey: .stream)
    if structured {
      try container.encode(ResponseFormat(type: "json_object"), forKey: .responseFormat)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case responseFormat = "response_format"
  }
}

private struct ChatCompletion: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
      let reasoningContent: String?

      enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        if let text = try? container.decode(String.self, forKey: .content) {
          content = text
        } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
          content = parts.compactMap(\.text).joined()
        } else {
          content = nil
        }
      }
    }

    struct ContentPart: Decodable {
      let text: String?
    }

    let message: Message
  }

  let choices: [Choice]
}
