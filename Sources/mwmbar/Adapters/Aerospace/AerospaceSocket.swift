import Foundation
import Network

/// aerospace wire protocol:
///   handshake: [u32 LE 1] both ways
///   request:   [u32 LE len][utf-8 JSON: {"args":[...],"stdin":"",
///                                        "windowId":null,"workspace":null}]
///   response:  [u32 LE len][utf-8 JSON: {"exitCode","stdout","stderr",...}]
///   subscribe: normal request; server keeps pushing framed ServerEvent JSON
struct AerospaceResponse: Decodable, Sendable {
  let exitCode: Int
  let stdout: String
  let stderr: String
}

struct AerospaceServerEvent: Decodable, Sendable {
  let event: String
  private enum CodingKeys: String, CodingKey { case event = "_event" }
}

/// @unchecked because the serial queue is the sync primitive for every mutable
/// field; the compiler cannot see that invariant.
final class AerospaceSocket: @unchecked Sendable {
  private let path: String
  private let queue = DispatchQueue(label: "aerospace.socket")
  private var connection: NWConnection?
  private var buffer = Data()
  private var handshakeDone = false
  private var pendingResponses: [@Sendable (Result<AerospaceResponse, Error>) -> Void] = []

  /// when set, framed payloads bypass pendingResponses and go here (subscribe mode)
  var onFrame: (@Sendable (Data) -> Void)?
  var onError: (@Sendable (Error) -> Void)?

  init(user: String = NSUserName()) {
    self.path = "/tmp/bobko.aerospace-\(user).sock"
  }

  func connect(then: @escaping @Sendable (Error?) -> Void) {
    let endpoint = NWEndpoint.unix(path: path)
    let params = NWParameters.tcp  // no unix-stream preset exists; .tcp gives byte-stream semantics
    let conn = NWConnection(to: endpoint, using: params)
    connection = conn
    conn.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        var v: UInt32 = 1
        let bytes = Data(bytes: &v, count: 4)
        conn.send(content: bytes, completion: .contentProcessed { _ in })
        self.receive()
        then(nil)
      case .failed(let err):
        then(err)
        self.onError?(err)
      default: break
      }
    }
    conn.start(queue: queue)
  }

  func send(args: [String]) async throws -> AerospaceResponse {
    try await withCheckedThrowingContinuation { cont in
      send(args: args) { result in
        cont.resume(with: result)
      }
    }
  }

  /// responses are matched to requests by FIFO order, not by id
  func send(args: [String], reply: @escaping @Sendable (Result<AerospaceResponse, Error>) -> Void) {
    guard let conn = connection else {
      reply(
        .failure(
          NSError(
            domain: "aerospace", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "not connected"])))
      return
    }
    guard let argsJson = try? JSONSerialization.data(withJSONObject: args) else {
      preconditionFailure("aerospace args are program constructed [String], encode cannot fail")
    }
    let payload =
      Data(#"{"args":"#.utf8) + argsJson
      + Data(#","stdin":"","windowId":null,"workspace":null}"#.utf8)
    var len = UInt32(payload.count).littleEndian
    let header = Data(bytes: &len, count: 4)
    queue.async { self.pendingResponses.append(reply) }
    conn.send(content: header + payload, completion: .contentProcessed { _ in })
  }

  private func receive() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle)
  }

  private func handle(data: Data?, _: NWConnection.ContentContext?, isDone: Bool, err: NWError?) {
    if let err {
      onError?(err)
      return
    }
    if let data {
      buffer.append(data)
      drain()
    }
    if !isDone { receive() }
  }

  private func drain() {
    while true {
      if !handshakeDone {
        guard buffer.count >= 4 else { return }
        buffer.removeFirst(4)
        handshakeDone = true
        continue
      }
      guard buffer.count >= 4 else { return }
      let len = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
      guard buffer.count >= 4 + Int(len) else { return }
      // removeFirst advances buffer.startIndex, so slice indices must be
      // anchored on startIndex rather than 0.
      let base = buffer.startIndex
      let payload = Data(buffer[(base + 4)..<(base + 4 + Int(len))])
      buffer.removeFirst(4 + Int(len))
      if let onFrame {
        onFrame(payload)
      } else if let cb = pendingResponses.first {
        pendingResponses.removeFirst()
        do {
          let resp = try JSONDecoder().decode(AerospaceResponse.self, from: payload)
          cb(.success(resp))
        } catch {
          cb(.failure(error))
        }
      }
    }
  }
}
