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
  /// What the model is asked to do. A calculator's answer column has room for
  /// a value, not for reasoning, so anything else is thrown away.
  static let instruction = """
    You answer lines from a calculator that could not work them out. \
    Reply with the resulting value and its unit, and nothing else: no working, \
    no sentence, no restatement of the question. \
    If the line has no such answer, reply with exactly UNKNOWN.
    """

  /// Longer lines are prose, not questions, and are never sent.
  static let maximumLine = 500
  /// A reply longer than this is an explanation, not an answer.
  static let maximumAnswer = 120
  static let maximumPayload = 64 * 1_024

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
    configuration.timeoutIntervalForRequest = 30
    // Replace the system defaults, which name the OS version and the
    // user's preferred languages.
    configuration.httpAdditionalHeaders = ["User-Agent": "Ganit", "Accept-Language": "*"]
    session = URLSession(configuration: configuration)
    super.init()
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
    let (data, response) = try await session.data(for: try request(for: asked), delegate: self)
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw AssistantError.malformedPayload
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
    let answer = (reply.choices.first?.message.content ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty, answer != "UNKNOWN", answer.count <= Self.maximumAnswer else {
      return nil
    }
    return answer
  }

  /// The only request Ganit sends for a line.
  func request(for line: String) throws -> URLRequest {
    guard Self.isAllowed(settings.endpoint) else {
      throw AssistantError.disallowedURL
    }
    var request = URLRequest(url: settings.endpoint)
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
        ]
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

  let model: String
  let messages: [Message]
}

private struct ChatCompletion: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
    }

    let message: Message
  }

  let choices: [Choice]
}
