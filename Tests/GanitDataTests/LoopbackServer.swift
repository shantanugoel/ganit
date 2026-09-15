import Foundation
import Network

/// A one-request HTTP server on a loopback port, which keeps the bytes it was
/// sent so a test can read what went over the wire.
final class LoopbackServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackServer")
  private let body: String
  private let contentType: String
  private var received: String?
  private var waiters: [CheckedContinuation<String?, Never>] = []

  var port: UInt16 {
    listener.port?.rawValue ?? 0
  }

  init(body: String = "<ok/>", contentType: String = "text/xml") throws {
    self.body = body
    self.contentType = contentType
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state {
        ready.signal()
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.serve(connection)
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
  }

  func stop() {
    listener.cancel()
  }

  func request() async -> String? {
    await withCheckedContinuation { continuation in
      queue.async {
        if let received = self.received {
          continuation.resume(returning: received)
        } else {
          self.waiters.append(continuation)
        }
      }
    }
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, so: "")
  }

  /// Reads until the request's headers, and the body its `Content-Length`
  /// promises, have arrived; a body may follow its headers in a later packet.
  private func read(_ connection: NWConnection, so far: String) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, _ in
      guard let self else {
        return
      }
      let raw = far + (data.map { String(decoding: $0, as: UTF8.self) } ?? "")
      guard isComplete || isWhole(raw) else {
        return read(connection, so: raw)
      }
      received = raw
      for waiter in waiters {
        waiter.resume(returning: raw)
      }
      waiters = []
      let response =
        "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\n"
        + "Connection: close\r\n\r\n\(body)"
      connection.send(
        content: Data(response.utf8),
        completion: .contentProcessed { _ in
          connection.cancel()
        })
    }
  }

  private func isWhole(_ raw: String) -> Bool {
    guard let separator = raw.range(of: "\r\n\r\n") else {
      return false
    }
    let length = raw[raw.startIndex..<separator.lowerBound]
      .components(separatedBy: "\r\n")
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
    return raw[separator.upperBound...].utf8.count >= (length ?? 0)
  }
}
