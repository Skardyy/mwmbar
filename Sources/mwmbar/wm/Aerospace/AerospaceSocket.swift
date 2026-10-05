import Foundation
import Network

/// aerospace wire protocol:
///   handshake: [u32 LE 1] both ways
///   request:   [u32 LE len][utf8 JSON: {"args":[...],"stdin":"",
///                                        "windowId":null,"workspace":null}]
///   response:  [u32 LE len][utf8 JSON: {"exitCode","stdout","stderr",...}]
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

struct AerospaceSocketError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
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
  private var _onFrame: (@Sendable (Data) -> Void)?
  private var _onError: (@Sendable (Error) -> Void)?
  private var connectFired = false

  var onFrame: (@Sendable (Data) -> Void)? {
    get { queue.sync { _onFrame } }
    set { queue.async { self._onFrame = newValue } }
  }
  var onError: (@Sendable (Error) -> Void)? {
    get { queue.sync { _onError } }
    set { queue.async { self._onError = newValue } }
  }

  init(user: String = NSUserName()) {
    self.path = "/tmp/bobko.aerospace-\(user).sock"
  }

  func connect(then: @escaping @Sendable (Error?) -> Void) {
    let endpoint = NWEndpoint.unix(path: path)
    let params = NWParameters.tcp
    let conn = NWConnection(to: endpoint, using: params)
    connection = conn
    queue.async {
      self.pendingConnect = then
      self.connectFired = false
    }
    conn.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        var v: UInt32 = 1
        let bytes = Data(bytes: &v, count: 4)
        conn.send(
          content: bytes,
          completion: .contentProcessed { err in
            if let err {
              Log.socket.error("handshake write failed: \(String(describing: err))")
              self.fireConnect(err)
              return
            }
            self.receive()
            self.fireConnect(nil)
          })
      case .failed(let err):
        Log.socket.error("connection failed: \(String(describing: err))")
        self.fireConnect(err)
        self.failAllPending(err)
        self._onError?(err)
      case .cancelled:
        let err = AerospaceSocketError(message: "connection cancelled")
        self.failAllPending(err)
      default: break
      }
    }
    conn.start(queue: queue)
  }

  private func fireConnect(_ err: Error?) {
    queue.async {
      if self.connectFired { return }
      self.connectFired = true
      self.pendingConnect?(err)
      self.pendingConnect = nil
    }
  }

  private var pendingConnect: (@Sendable (Error?) -> Void)?

  func send(args: [String]) async throws -> AerospaceResponse {
    try await withCheckedThrowingContinuation { cont in
      send(args: args) { result in
        cont.resume(with: result)
      }
    }
  }

  /// responses matched to requests by FIFO order, not by id
  func send(args: [String], reply: @escaping @Sendable (Result<AerospaceResponse, Error>) -> Void) {
    guard let conn = connection else {
      reply(.failure(AerospaceSocketError(message: "not connected")))
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
    let frame = header + payload
    // append + wire write must be one atomic step on the serial queue, or
    // concurrent senders can reorder writes relative to pendingResponses and
    // deliver a reply to the wrong caller.
    queue.async { [self] in
      pendingResponses.append(reply)
      conn.send(
        content: frame,
        completion: .contentProcessed { [self] err in
          guard let err else { return }
          Log.socket.error("send write failed: \(String(describing: err))")
          failAllPending(err)
        })
    }
  }

  private func failAllPending(_ err: Error) {
    queue.async {
      let pending = self.pendingResponses
      self.pendingResponses.removeAll()
      for cb in pending { cb(.failure(err)) }
    }
  }

  private func receive() {
    guard let conn = connection else {
      Log.socket.warning("receive on nil connection; read loop stops.")
      return
    }
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle)
  }

  private func handle(data: Data?, _: NWConnection.ContentContext?, isDone: Bool, err: NWError?) {
    if let err {
      Log.socket.error("receive failed: \(String(describing: err))")
      failAllPending(err)
      _onError?(err)
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
      if let cb = _onFrame {
        cb(payload)
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
