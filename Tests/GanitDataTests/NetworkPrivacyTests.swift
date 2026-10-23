import Foundation
import Network
import Testing

@testable import GanitData

@Suite
struct NetworkPrivacyTests {
  /// Sends the downloader's request to a loopback server and inspects the
  /// bytes that reach the wire, including headers the system adds.
  @Test
  func requestOnTheWireCarriesNoUserContentOrIdentifiers() async throws {
    let server = try LoopbackServer()
    defer { server.stop() }
    var request = RateDownloader.request
    request.url = URL(string: "http://127.0.0.1:\(server.port)\(RateSnapshot.sourceURL.path())")

    _ = try await RateDownloader().fetch(request)
    let raw = try #require(await server.request())
    let lines = raw.components(separatedBy: "\r\n")

    #expect(lines.first == "GET /stats/eurofxref/eurofxref-daily.xml HTTP/1.1")
    let headers = Dictionary(
      lines.dropFirst().prefix { !$0.isEmpty }.map { line -> (String, String) in
        let parts = line.split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        return (parts[0].lowercased(), parts.count > 1 ? parts[1] : "")
      },
      uniquingKeysWith: { first, _ in first }
    )
    #expect(
      Set(headers.keys).isSubset(
        of: ["host", "accept", "user-agent", "accept-language", "accept-encoding", "connection"]),
      "\(headers.keys.sorted())")
    #expect(headers["accept"] == "text/xml")
    #expect(headers["user-agent"] == "Ganit")
    #expect(headers["accept-language"] == "*")
    #expect(raw.hasSuffix("\r\n\r\n"), "The request has no body")
    for identifier in [
      NSUserName(), ProcessInfo.processInfo.hostName,
      ProcessInfo.processInfo.operatingSystemVersionString,
      "Darwin", "CFNetwork", Locale.current.identifier,
    ] where identifier.count > 2 {
      #expect(!raw.localizedCaseInsensitiveContains(identifier), "\(identifier)")
    }
  }

  /// The provider receives the exact disclosed context and no machine details.
  @Test(arguments: [false, true], [false, true])
  func askSendsOnlyTheDisclosedBodyAndRequiredHeaders(
    allowsExplanation: Bool, allowsAnswer: Bool
  ) async throws {
    let content = "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"Missing input\"}"
    let completion = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": content]]]
    ])
    let server = try LoopbackServer(
      body: String(decoding: completion, as: UTF8.self), contentType: "application/json")
    defer { server.stop() }
    let settings = AssistantSettings(
      isEnabled: true,
      endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
      model: "a-model", apiKey: "a-key", effort: .high)
    let context = Data(
      "{\"target\":{\"source\":\"bill + fee\"},\"dependencySources\":[{\"source\":\"bill = 20\"},{\"source\":\"fee = 5\"}],\"notes\":[{\"source\":\"// Task: explain this\"}]}"
        .utf8)
    let wire = try SuggestionWireRequest(
      settings: settings, context: context, allowsExplanation: allowsExplanation,
      allowsAnswer: allowsAnswer)

    _ = try await ProviderSuggestionTransport().send(wire)
    let raw = try #require(await server.request())
    #expect(await server.requestCount() == 1)
    let lines = raw.components(separatedBy: "\r\n")
    #expect(lines.first == "POST /v1/chat/completions HTTP/1.1")
    let headers = Dictionary(
      lines.dropFirst().prefix { !$0.isEmpty }.map { line -> (String, String) in
        let parts = line.split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        return (parts[0].lowercased(), parts.count > 1 ? parts[1] : "")
      },
      uniquingKeysWith: { first, _ in first })
    #expect(
      Set(headers.keys).isSubset(of: [
        "host", "accept", "user-agent", "accept-language", "accept-encoding", "connection",
        "authorization", "content-type", "content-length",
      ]), "\(headers.keys.sorted())")
    #expect(headers["user-agent"] == "Ganit")
    #expect(headers["accept-language"] == "*")
    #expect(headers["authorization"] == "Bearer a-key")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "application/json")

    let body = try #require(raw.components(separatedBy: "\r\n\r\n").last)
    #expect(Data(body.utf8) == wire.body)
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    #expect(
      Set(json.keys) == ["model", "messages", "stream", "response_format", "reasoning_effort"],
      "\(json.keys.sorted())")
    #expect(json["model"] as? String == "a-model")
    #expect(json["reasoning_effort"] as? String == "high")
    #expect(json["stream"] as? Bool == false)
    let format = try #require(json["response_format"] as? [String: String])
    #expect(format == ["type": "json_object"])
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages.count == 2)
    #expect(messages.allSatisfy { Set($0.keys) == ["role", "content"] })
    #expect(messages.map { $0["role"] } == ["system", "user"])
    #expect(messages[1]["content"] == String(decoding: context, as: UTF8.self))
    #expect(messages[0]["content"]?.contains("Response schema:") == true)
    #expect(
      messages[0]["content"]?.contains("The user explicitly requested an explanation")
        == allowsExplanation)
    #expect(
      messages[0]["content"]?.contains("You may return kind answer with text only")
        == allowsAnswer)
    #expect(!body.contains("a-key"))
    for identifier in [
      NSUserName(), ProcessInfo.processInfo.hostName,
      ProcessInfo.processInfo.operatingSystemVersionString,
      "Darwin", "CFNetwork", Locale.current.identifier,
    ] where identifier.count > 2 {
      #expect(!raw.localizedCaseInsensitiveContains(identifier), "\(identifier)")
    }
  }

  /// Off and format fallback omit optional fields without changing the context.
  @Test(arguments: [false, true], [false, true])
  func askOmitsOptionalFieldsWhenRequested(structured: Bool, effort: Bool) throws {
    let context = Data("{\"target\":\"bill + fee\"}".utf8)
    let settings = AssistantSettings(
      isEnabled: true, endpoint: URL(string: "https://example.test/v1")!,
      model: "a-model", apiKey: "", effort: .off)
    let wire = try SuggestionWireRequest(
      settings: settings, context: context, structured: structured, effort: effort)
    let json = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
    var keys: Set<String> = ["model", "messages", "stream"]
    if structured { keys.insert("response_format") }
    #expect(Set(json.keys) == keys)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages[1]["content"] == String(decoding: context, as: UTF8.self))
  }

}

/// Sparkle is the third thing that can reach the network, and it is a
/// framework rather than a file here, so the test below cannot see it. What
/// keeps it honest is that it asks nothing until the reader asks.
@Test
func onlyTheRatesAndTheAssistantReachTheNetworkFromGanitsOwnCode() throws {
  let sources = repositoryRoot.appending(path: "Sources")
  let files = try #require(
    FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
  let networking = try files.filter { file in
    let source = try String(contentsOf: file, encoding: .utf8)
    return ["URLSession", "import Network", "NWConnection", "CFStream", "WKWebView"].contains {
      source.contains($0)
    }
  }
  #expect(
    Set(networking.map(\.lastPathComponent))
      == ["RateDownloader.swift", "SuggestionTransport.swift"])
  #expect(networking.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "GanitData" })
}

/// The updater's settings are the whole of its privacy promise: it looks for
/// a new version only when asked, tells the server nothing about the Mac it
/// runs on, and takes an update only from Ganit's own releases.
@Test
func theUpdaterAsksNothingUntilItIsAsked() throws {
  let information = try #require(
    NSDictionary(contentsOf: repositoryRoot.appending(path: "App/Info.plist"))
      as? [String: Any])

  #expect(information["SUEnableAutomaticChecks"] as? Bool == false)
  #expect(information["SUEnableSystemProfiling"] as? Bool == false)
  #expect(information["SUEnableInstallerLauncherService"] as? Bool == true)
  #expect(
    information["SUFeedURL"] as? String
      == "https://github.com/shantanugoel/ganit/releases/latest/download/appcast.xml")
  #expect((information["SUPublicEDKey"] as? String)?.isEmpty == false)
  // Sparkle compares CFBundleVersion, so it has to move with the version a
  // reader sees, or a release offers itself to the people already running it.
  #expect(
    information["CFBundleVersion"] as? String
      == information["CFBundleShortVersionString"] as? String
  )
  #expect(information["CFBundleIconFile"] as? String == "AppIcon")
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
