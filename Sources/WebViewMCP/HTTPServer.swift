import Foundation
import Network

/// A tiny HTTP server on Network.framework. One request per connection, then close.
final class HTTPServer {
  typealias Handler = (HTTPRequest) async -> HTTPResponse

  private let queue = DispatchQueue(label: "wkwebview-mcp.http")
  private var listener: NWListener?
  private let handler: Handler

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// Binds the first free port in `port..<port + attempts` and reports the bound port.
  func start(
    port: UInt16,
    attempts: Int,
    loopbackOnly: Bool,
    completion: @escaping (Result<UInt16, Error>) -> Void
  ) {
    queue.async {
      self.bind(port: port, attemptsLeft: max(attempts, 1), loopbackOnly: loopbackOnly, completion: completion)
    }
  }

  func stop() {
    queue.async {
      self.listener?.cancel()
      self.listener = nil
    }
  }

  private func bind(
    port: UInt16,
    attemptsLeft: Int,
    loopbackOnly: Bool,
    completion: @escaping (Result<UInt16, Error>) -> Void
  ) {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      completion(.failure(POSIXError(.EINVAL)))
      return
    }

    let listener: NWListener
    do {
      let parameters = NWParameters.tcp
      if loopbackOnly {
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        listener = try NWListener(using: parameters)
      } else {
        listener = try NWListener(using: parameters, on: endpointPort)
      }
    } catch {
      completion(.failure(error))
      return
    }

    let once = Once()
    listener.stateUpdateHandler = { [weak self] state in
      guard let self, !once.done else {
        return
      }
      switch state {
      case .ready:
        once.done = true
        self.listener = listener
        completion(.success(listener.port?.rawValue ?? port))
      case let .failed(error), let .waiting(error):
        once.done = true
        listener.cancel()
        if attemptsLeft > 1 {
          self.bind(port: port + 1, attemptsLeft: attemptsLeft - 1, loopbackOnly: loopbackOnly, completion: completion)
        } else {
          completion(.failure(error))
        }
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var buffer = buffer
      if let data {
        buffer.append(data)
      }

      switch HTTPRequest.parse(buffer) {
      case let .complete(request):
        self.respond(on: connection, to: request)
      case let .invalid(message):
        self.send(.error(400, message), on: connection)
      case .incomplete:
        if isComplete || error != nil {
          connection.cancel()
        } else {
          self.receive(on: connection, buffer: buffer)
        }
      }
    }
  }

  private func respond(on connection: NWConnection, to request: HTTPRequest) {
    let handler = handler
    Task {
      let response = await handler(request)
      self.send(response, on: connection)
    }
  }

  private func send(_ response: HTTPResponse, on connection: NWConnection) {
    connection.send(content: response.serialized(), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}

/// Mutable flag shared by callbacks that all run on the server's serial queue.
private final class Once: @unchecked Sendable {
  var done = false
}
