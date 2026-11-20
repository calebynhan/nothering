import Foundation
import Network
import os

/// The phone's end of pairing (see `DirectLinkPairing`): advertises that it can be paired with,
/// and puts a Mac's request to the person.
///
/// It runs only while the person has the app in front of them, see `ProxyServer.setAcceptsPairing`:
/// what it accepts comes from anyone in range, before any key is shared.
///
/// One question at a time. A Mac asking meanwhile is turned away, so nobody can stack questions on
/// the screen, and after a question that wasn't allowed the next one has to wait. All state is
/// confined to `queue`.
final class DirectLinkPairingListener {
  /// One connection from a Mac can arrive as several, one per way it can reach the phone, and the
  /// Mac keeps whichever it likes. So all are taken, up to this many, and the one that asks first
  /// gets the question.
  private static let maxAttempts = 8
  /// How long a connection has to get as far as its question.
  private static let helloTimeout: TimeInterval = 10
  /// How long nobody may ask after a question that wasn't allowed, doubling each time up to the
  /// longest. Keeps a stranger from holding the alert on the screen.
  private static let firstPause: TimeInterval = 30
  private static let longestPause: TimeInterval = 8 * 60

  private let listener: NWListener
  private let queue: DispatchQueue
  private let code: String
  private let onRequest: (DirectLinkPairingRequest?) -> Void
  private let logger = Logger(subsystem: "app.nothering", category: "pairing")
  private var attempts: [ObjectIdentifier: (connection: NWConnection, responder: PairingResponder?)] = [:]
  /// The attempt whose question is on the screen.
  private var asking: ObjectIdentifier?
  private var pause: TimeInterval = 0
  private var pausedUntil = Date.distantPast

  /// `onRequest` gets a request to show, and `nil` when the request it last got is over without an
  /// answer, e.g. the Mac gave up.
  init(code: String, queue: DispatchQueue, onRequest: @escaping (DirectLinkPairingRequest?) -> Void) throws {
    self.queue = queue
    self.code = code
    self.onRequest = onRequest
    listener = try NWListener(using: DirectLink.pairingParameters)
    listener.service = NWListener.Service(type: DirectLinkPairing.serviceType)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.stateUpdateHandler = { [logger] state in
      switch state {
      case let .waiting(error), let .failed(error):
        logger.error("pairing listener: \(error.debugDescription, privacy: .public)")
      default:
        break
      }
    }
    listener.start(queue: queue)
  }

  /// Where it listens, once it does. The Mac finds it by its Bonjour service, so only tests ask.
  var port: UInt16? {
    listener.port?.rawValue
  }

  func cancel() {
    listener.newConnectionHandler = nil
    listener.stateUpdateHandler = nil
    listener.cancel()
    for id in Array(attempts.keys) {
      end(id)
    }
  }

  private func accept(_ connection: NWConnection) {
    guard attempts.count < Self.maxAttempts else { return connection.cancel() }
    let id = ObjectIdentifier(connection)
    attempts[id] = (connection, nil)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, let attempt = attempts[id], attempt.connection === connection else { return }
      switch state {
      case .ready:
        guard attempt.responder == nil else { return }
        let responder = PairingResponder(
          transport: connection,
          queue: queue,
          code: code,
          ask: { [weak self, weak connection] request in
            guard let self, let connection, attempts[id]?.connection === connection else { return }
            ask(request, for: id)
          },
          onEnd: { [weak self, weak connection] ending in
            guard let self, let connection, attempts[id]?.connection === connection else { return }
            ended(id, ending)
          }
        )
        attempts[id] = (connection, responder)
        responder.start()
      case .waiting, .failed, .cancelled:
        end(id)
      default:
        break
      }
    }
    connection.start(queue: queue)
    // An identifier is used again once its connection is gone, hence the look at which connection
    // it names.
    queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self, weak connection] in
      guard let self, let connection, attempts[id]?.connection === connection, asking != id else { return }
      end(id)
    }
  }

  private func ask(_ request: DirectLinkPairingRequest, for id: ObjectIdentifier) {
    guard asking == nil, Date() >= pausedUntil else {
      logger.notice("a Mac asks to pair while it can't be asked")
      return end(id)
    }
    logger.info("a Mac asks to pair")
    asking = id
    onRequest(request)
  }

  private func ended(_ id: ObjectIdentifier, _ ending: PairingResponder.Ending) {
    attempts[id] = nil
    guard asking == id else { return }
    asking = nil
    switch ending {
    case .allowed:
      pause = 0
    case .refused, .leftAsking:
      pause = min(max(pause * 2, Self.firstPause), Self.longestPause)
      pausedUntil = Date().addingTimeInterval(pause)
    case .notAsked:
      break
    }
    if ending == .leftAsking { onRequest(nil) }
  }

  /// Ends an attempt, whatever it got to.
  private func end(_ id: ObjectIdentifier) {
    guard let attempt = attempts[id] else { return }
    if let responder = attempt.responder {
      // Also cancels the connection, and reports back through `ended`.
      responder.cancel()
    } else {
      attempts[id] = nil
      attempt.connection.cancel()
    }
  }
}
