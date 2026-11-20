import Foundation
import Network
import os

/// The phone's end of the direct Wi-Fi link (see `DirectLink`): advertises the service, accepts the
/// Mac's connection, and hands each stream the Mac opens on it to the proxy.
///
/// All state is confined to `queue`, the proxy server's own, so a stream is served like a socket.
final class DirectLinkListener {
  /// A connection is accepted before its handshake, which only a Mac with the pairing code gets
  /// through. One that doesn't finish it in this time is dropped, and no more than this many may
  /// be at it at once, so strangers can't fill the phone's memory with connections that say nothing.
  private static let handshakeTimeout: TimeInterval = 10
  private static let maxHandshakes = 16
  /// How long after the listener is up its service should be registered. Longer means it isn't.
  private static let advertisingTimeout: TimeInterval = 5

  private let code: String
  private let queue: DispatchQueue
  /// Whether the service is announced at all, see `ProxyServer.Configuration.announcesDirectLink`.
  private let announces: Bool
  private let onStream: (MuxStream) -> Void
  private let logger = Logger(subsystem: "app.nothering", category: "direct")
  private var listener: NWListener?
  private var isCancelled = false
  /// Whether the service is registered, so a Mac can find the phone.
  private var isAdvertised = false
  /// Told apart from a listener made later, whose callbacks may still be on their way.
  private var generation = 0
  /// The Macs connected, each with its mux once the handshake is done.
  private var links: [ObjectIdentifier: (connection: NWConnection, mux: Mux?)] = [:]
  /// Why the Mac can't find the phone, e.g. Local Network access is off. `nil` while it can.
  private(set) var problem: String?

  init(code: String, queue: DispatchQueue, announces: Bool = true, onStream: @escaping (MuxStream) -> Void) throws {
    self.code = code
    self.queue = queue
    self.announces = announces
    self.onStream = onStream
    try listen()
  }

  /// Where it listens, once it does. The Mac finds it by its Bonjour service, so only tests ask.
  var port: UInt16? {
    // A listener that isn't ready yet says 0, not nothing.
    guard let port = listener?.port?.rawValue, port != 0 else { return nil }
    return port
  }

  /// Ends the link. A Mac that is connected is first told what the proxy last had to say, e.g.
  /// that it was stopped by hand.
  func cancel() {
    isCancelled = true
    stopListening()
    let open = Array(links.values)
    links.removeAll()
    for link in open {
      if let mux = link.mux {
        mux.closeAfterFlush(on: queue)
      } else {
        link.connection.cancel()
      }
    }
  }

  // MARK: Listening

  private func listen() throws {
    generation += 1
    let current = generation
    let listener = try NWListener(using: DirectLink.parameters(code: code))
    listener.newConnectionHandler = { [weak self] connection in
      guard let self, generation == current else { return connection.cancel() }
      accept(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self, generation == current else { return }
      listenerChanged(to: state)
    }
    // The listener's state is about its socket. Whether a Mac can find it is told here.
    listener.serviceRegistrationUpdateHandler = { [weak self] change in
      guard let self, generation == current else { return }
      if case .add = change {
        isAdvertised = true
        problem = nil
        logger.info("direct link advertised")
      }
    }
    self.listener = listener
    isAdvertised = false
    advertise(!hasLink)
    listener.start(queue: queue)
  }

  private func stopListening() {
    generation += 1
    listener?.cancel()
    listener = nil
  }

  private var hasLink: Bool {
    links.values.contains { $0.mux != nil }
  }

  /// The service is only advertised while no Mac is connected. Advertising over device-to-device
  /// Wi-Fi keeps the radio busy looking around, which slows the very connection it led to.
  private func advertise(_ on: Bool) {
    guard announces else { return }
    listener?.service = on
      ? NWListener.Service(name: DirectLink.serviceName(code: code), type: DirectLink.serviceType)
      : nil
    if !on { isAdvertised = false }
  }

  private func listenerChanged(to state: NWListener.State) {
    switch state {
    case .ready:
      // With Local Network access off the listener comes up all the same, and only the service
      // never appears.
      let current = generation
      queue.asyncAfter(deadline: .now() + Self.advertisingTimeout) { [weak self] in
        guard let self, announces, generation == current, !isAdvertised, !hasLink else { return }
        problem = "Your Mac can't find this iPhone. Allow Nothering to use the local network in Settings > Privacy & Security > Local Network."
        logger.error("direct link: the service wasn't registered")
      }
    case let .waiting(error):
      note(error)
    case let .failed(error):
      note(error)
      // A failed listener stays failed, e.g. after the app was suspended for long. A new one
      // takes its place.
      stopListening()
      queue.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self, !isCancelled, listener == nil else { return }
        do {
          try listen()
        } catch {
          logger.error("direct link listener didn't come back: \(error.localizedDescription, privacy: .public)")
        }
      }
    default:
      break
    }
  }

  private func note(_ error: NWError) {
    problem = DirectLink.isLocalNetworkDenied(error)
      ? "Allow Nothering to use the local network in Settings > Privacy & Security > Local Network."
      : error.localizedDescription
    logger.error("direct link listener: \(error.debugDescription, privacy: .public)")
  }

  // MARK: The Mac's connection

  private func accept(_ connection: NWConnection) {
    guard links.values.filter({ $0.mux == nil }).count < Self.maxHandshakes else {
      return connection.cancel()
    }
    let id = ObjectIdentifier(connection)
    links[id] = (connection, nil)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, let link = links[id], link.connection === connection else { return }
      switch state {
      case .ready:
        guard link.mux == nil else { return }
        logger.info("Mac connected over the direct link")
        let mux = Mux(
          transport: connection,
          role: .server,
          onStream: onStream,
          onClose: { [weak self, weak connection] _ in
            guard let self, let connection, links[id]?.connection === connection else { return }
            links[id] = nil
            if !hasLink, !isCancelled { advertise(true) }
          }
        )
        links[id] = (connection, mux)
        advertise(false)
        mux.start()
      case .waiting, .failed, .cancelled:
        // A Mac with another pairing code ends here: its TLS handshake fails.
        links[id] = nil
        close(link)
        if !hasLink, !isCancelled { advertise(true) }
      default:
        break
      }
    }
    connection.start(queue: queue)
    // An identifier is used again once its connection is gone, hence the second look at which
    // connection it names.
    queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self, weak connection] in
      guard let self, let connection, let link = links[id], link.connection === connection, link.mux == nil else { return }
      links[id] = nil
      connection.cancel()
    }
  }

  private func close(_ link: (connection: NWConnection, mux: Mux?)) {
    if let mux = link.mux {
      // Also cancels the connection and fails the streams on it.
      mux.close()
    } else {
      link.connection.cancel()
    }
  }
}
