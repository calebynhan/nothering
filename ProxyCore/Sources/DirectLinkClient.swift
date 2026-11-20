import Darwin
import Foundation
import Network
import os

public struct DirectLinkError: LocalizedError {
  public let message: String

  public var errorDescription: String? { message }
}

/// The Mac's end of the direct Wi-Fi link (see `DirectLink`): finds the phone, keeps one connection
/// to it, and opens a stream on it for each connection to the phone's proxy.
///
/// While there is no connection it keeps looking, so the link comes up by itself once the phone's
/// proxy starts and comes back after the phone was out of range.
public final class DirectLinkClient: @unchecked Sendable {
  public enum Status: Equatable, Sendable {
    /// Looking for the phone. Its proxy has to be running, and Wi-Fi on, on both.
    case searching
    /// Found the phone, connecting to it.
    case connecting
    case connected
    /// Can't connect until the user changes something, e.g. lets Nothering use the local network.
    case blocked(String)
  }

  /// A connection that isn't up after this long is given up and tried again. One to a phone that
  /// just left can otherwise stay "connecting" without ever saying that it failed.
  private static let connectTimeout: TimeInterval = 15

  private let code: String
  /// The name this Mac's phone gives its service, see `DirectLink.serviceName`.
  private let serviceName: String
  private let queue = DispatchQueue(label: "app.nothering.direct")
  private let logger = Logger(subsystem: "app.nothering", category: "direct")
  private let onStatusChange: @Sendable (Status) -> Void
  private var browser: NWBrowser?
  /// Where this Mac's phone was found. One service, unless it is reachable in more than one way.
  private var candidates: [NWEndpoint] = []
  private var nextCandidate = 0
  /// Whether the last look found a phone advertising the link under another pairing code.
  private var sawAnotherPhone = false
  private var connection: NWConnection?
  private var mux: Mux?
  private var relays: [ObjectIdentifier: Relay] = [:]
  private var status = Status.searching
  private var isRunning = false
  private var isRetryScheduled = false

  /// `onStatusChange` is called on a private queue each time the status changes.
  public init(code: String, onStatusChange: @escaping @Sendable (Status) -> Void = { _ in }) {
    self.code = code
    serviceName = DirectLink.serviceName(code: code)
    self.onStatusChange = onStatusChange
  }

  public var currentStatus: Status {
    queue.sync { status }
  }

  /// Whether an iPhone with Nothering is in range that has another pairing code, while this Mac's
  /// own wasn't found. If that iPhone is the person's, the Mac has to be paired again.
  public var foundAnotherPhone: Bool {
    queue.sync { sawAnotherPhone && candidates.isEmpty && connection == nil }
  }

  public func start() {
    queue.async { [self] in
      guard !isRunning else { return }
      isRunning = true
      search()
    }
  }

  public func stop() {
    queue.sync {
      isRunning = false
      stopBrowsing()
      candidates = []
      sawAnotherPhone = false
      if let connection { linkEnded(connection) }
      status = .searching
    }
  }

  /// Opens a stream to the phone's proxy and returns a socket that carries it, like the USB and
  /// hotspot links return a connected socket. Not to be called on the client's own queue.
  public func connect() throws -> Int32 {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SocketError("socketpair") }
    for fd in fds {
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      // The default is 8 KB, which would make a download cross this pair in thousands of tiny hops.
      var size = Int32(256 * 1024)
      setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    let isOpen = queue.sync { () -> Bool in
      guard let stream = mux?.openStream() else { return false }
      // The relay owns its end of the pair and closes it when either side is done.
      let relay = Relay(SocketStream(fd: fds[1], queue: queue), stream)
      let id = ObjectIdentifier(relay)
      relays[id] = relay
      relay.start { [weak self] in
        self?.relays[id] = nil
      }
      return true
    }
    guard isOpen else {
      Darwin.close(fds[0])
      Darwin.close(fds[1])
      throw DirectLinkError(message: "iPhone not connected over the direct link")
    }
    return fds[0]
  }

  // MARK: Finding the phone (on `queue`)

  private func search() {
    guard isRunning, browser == nil, connection == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: DirectLink.serviceType, domain: nil), using: DirectLink.browseParameters)
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      guard let self, let browser, self.browser === browser else { return }
      switch state {
      case .ready:
        // Browsing works (again), so a Local Network warning from before no longer holds.
        if case .blocked = status { setStatus(.searching) }
      case let .waiting(error), let .failed(error):
        logger.error("direct link browse: \(error.debugDescription, privacy: .public)")
        if DirectLink.isLocalNetworkDenied(error) {
          setStatus(.blocked("Allow Nothering to find devices on your local network in System Settings > Privacy & Security > Local Network"))
        }
        if case .failed = state {
          stopBrowsing()
          retryLater()
        }
      default:
        break
      }
    }
    browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
      guard let self, let browser, self.browser === browser else { return }
      // Only the phone this Mac is paired with. Another one would turn it down, and may not even
      // say so: a handshake with the wrong key can hang instead of failing.
      let serviceName = serviceName
      let own = results.map(\.endpoint).filter { endpoint in
        if case let .service(name, _, _, _) = endpoint { return name == serviceName }
        return false
      }
      sawAnotherPhone = results.count > own.count
      candidates = own
      connectToNextCandidate()
    }
    self.browser = browser
    browser.start(queue: queue)
  }

  private func stopBrowsing() {
    browser?.cancel()
    browser = nil
  }

  private func connectToNextCandidate() {
    guard isRunning, connection == nil, !candidates.isEmpty else { return }
    let endpoint = candidates[nextCandidate % candidates.count]
    nextCandidate &+= 1
    // Looking around over device-to-device Wi-Fi keeps the radio hopping channels, which slows
    // the connection it is about to carry. The phone is found, so the looking ends here.
    stopBrowsing()
    candidates = []
    if case .blocked = status {} else { setStatus(.connecting) }
    let connection = NWConnection(to: endpoint, using: DirectLink.parameters(code: code))
    self.connection = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.connection === connection else { return }
      switch state {
      case .ready:
        guard self.mux == nil else { return }
        logger.info("direct link connected")
        let mux = Mux(transport: connection, role: .client, onClose: { [weak self, weak connection] _ in
          if let connection { self?.linkEnded(connection) }
        })
        self.mux = mux
        mux.start()
        setStatus(.connected)
      case let .waiting(error), let .failed(error):
        logger.notice("direct link: \(error.debugDescription, privacy: .public)")
        linkEnded(connection)
      case .cancelled:
        linkEnded(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self, weak connection] in
      guard let self, let connection, self.connection === connection, mux == nil else { return }
      logger.notice("direct link: not connected after \(Int(Self.connectTimeout)) s, trying again")
      linkEnded(connection)
    }
  }

  /// Drops the connection and looks for the phone again after a moment.
  private func linkEnded(_ ended: NWConnection) {
    guard connection === ended else { return }
    connection = nil
    let endedMux = self.mux
    self.mux = nil
    // Fails every stream on it, which closes their relays.
    endedMux?.close()
    ended.cancel()
    let open = Array(relays.values)
    relays.removeAll()
    for relay in open {
      relay.close()
    }
    if status == .connected || status == .connecting { setStatus(.searching) }
    retryLater()
  }

  /// Not right away, so a phone that can't take the connection just now isn't hammered.
  private func retryLater() {
    guard isRunning, !isRetryScheduled else { return }
    isRetryScheduled = true
    queue.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self else { return }
      isRetryScheduled = false
      guard isRunning, connection == nil else { return }
      if browser == nil {
        search()
      } else {
        connectToNextCandidate()
      }
    }
  }

  private func setStatus(_ status: Status) {
    guard self.status != status else { return }
    self.status = status
    onStatusChange(status)
  }
}
