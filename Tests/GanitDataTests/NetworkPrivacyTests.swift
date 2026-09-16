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

  /// The assistant carries one line, on purpose. This checks that it carries
  /// nothing else, since the line is the whole of what someone agreed to send.
  @Test
  func theAssistantSendsTheLineAndNothingAboutTheMachineItWasTypedOn() async throws {
    let server = try LoopbackServer(body: "{\"choices\":[]}", contentType: "application/json")
    defer { server.stop() }
    let settings = AssistantSettings(
      isEnabled: true,
      endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!,
      model: "a-model",
      apiKey: "a-key"
    )

    _ = try await Assistant(settings: settings).answer(to: "10 kg of water in ml")
    let raw = try #require(await server.request())
    let lines = raw.components(separatedBy: "\r\n")

    #expect(lines.first == "POST /v1/chat/completions HTTP/1.1")
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
        of: [
          "host", "accept", "user-agent", "accept-language", "accept-encoding", "connection",
          "authorization", "content-type", "content-length",
        ]),
      "\(headers.keys.sorted())")
    #expect(headers["user-agent"] == "Ganit")
    #expect(headers["accept-language"] == "*")
    #expect(headers["authorization"] == "Bearer a-key")

    let body = try #require(raw.components(separatedBy: "\r\n\r\n").last)
    #expect(body.contains("10 kg of water in ml"))
    #expect(body.contains("a-model"))
    for identifier in [
      NSUserName(), ProcessInfo.processInfo.hostName,
      ProcessInfo.processInfo.operatingSystemVersionString,
      "Darwin", "CFNetwork", Locale.current.identifier,
    ] where identifier.count > 2 {
      #expect(!raw.localizedCaseInsensitiveContains(identifier), "\(identifier)")
    }
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
  #expect(Set(networking.map(\.lastPathComponent)) == ["RateDownloader.swift", "Assistant.swift"])
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
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
