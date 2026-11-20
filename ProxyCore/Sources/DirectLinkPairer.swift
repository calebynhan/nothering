import Foundation
import Network
import os

/// The Mac's end of pairing (see `DirectLinkPairing`): finds a phone that can be paired with, asks
/// it, and reports the number to show and then the phone's code.
public final class DirectLinkPairer: @unchecked Sendable {
  public enum State: Equatable, Sendable {
    /// Looking for the phone. Its proxy has to be running, and Wi-Fi on, on both.
    case searching
    /// The phone is asking its person. They should see this number there, and tap Allow.
    case confirming(digits: String)
    /// A phone said yes. Whether it was the person's own is theirs to say: only they know whether
    /// it showed this number. Anything in range can answer in its place, with a code of its own,
    /// and would then carry all of this Mac's traffic. `confirm()` or `cancel()` follows.
    case answered(digits: String)
    /// Done: the phone's pairing code.
    case paired(code: String)
    case failed(String)
  }

  /// How long to look for a phone and reach it before giving up.
  private static let searchTimeout: TimeInterval = 45
  private static let retryDelay: TimeInterval = 2

  private let name: String
  private let onState: @Sendable (State) -> Void
  private let queue = DispatchQueue(label: "app.nothering.pairing")
  private let logger = Logger(subsystem: "app.nothering", category: "pairing")
  private var browser: NWBrowser?
  /// The phones found that can be paired with. Usually one.
  private var candidates: [NWEndpoint] = []
  private var nextCandidate = 0
  private var connection: NWConnection?
  private var requester: PairingRequester?
  /// The number shown for the request under way.
  private var digits: String?
  /// What a phone answered, kept back until the person confirms it was theirs.
  private var held: String?
  private var isOver = true

  /// `name` is what the phone shows its person, e.g. this Mac's name. `onState` is called on a
  /// private queue, last with `paired` or `failed`.
  public init(name: String, onState: @escaping @Sendable (State) -> Void) {
    self.name = name
    self.onState = onState
  }

  public func start() {
    queue.async { [self] in
      guard isOver, browser == nil else { return }
      isOver = false
      held = nil
      onState(.searching)
      let browser = NWBrowser(for: .bonjour(type: DirectLinkPairing.serviceType, domain: nil), using: DirectLink.browseParameters)
      browser.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case let .waiting(error), let .failed(error):
          logger.error("pairing browse: \(error.debugDescription, privacy: .public)")
          if DirectLink.isLocalNetworkDenied(error) {
            finish(.failed("Allow Nothering, or the terminal it runs in, to find devices on your local network in System Settings > Privacy & Security > Local Network"))
          } else if case .failed = state {
            finish(.failed("Couldn't look for your iPhone. Check that Wi-Fi is on"))
          }
        default:
          break
        }
      }
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        guard let self else { return }
        candidates = results.map(\.endpoint)
        askNext()
      }
      self.browser = browser
      browser.start(queue: queue)
      // Until the phone has the request. From there the request has its own time limit.
      queue.asyncAfter(deadline: .now() + Self.searchTimeout) { [weak self] in
        guard let self, requester == nil, held == nil else { return }
        finish(.failed("No iPhone found. Open Nothering on it and keep it open. Wi-Fi has to be on, on both"))
      }
    }
  }

  /// The person says the phone that answered was theirs: it showed the number. Reports `paired`.
  public func confirm() {
    queue.async { [self] in
      guard !isOver, let code = held else { return }
      held = nil
      isOver = true
      onState(.paired(code: code))
    }
  }

  /// Gives up without reporting anything more.
  public func cancel() {
    queue.sync {
      guard !isOver else { return }
      isOver = true
      held = nil
      tearDown()
    }
  }

  private func askNext() {
    guard !isOver, held == nil, connection == nil, !candidates.isEmpty else { return }
    let endpoint = candidates[nextCandidate % candidates.count]
    nextCandidate &+= 1
    let connection = NWConnection(to: endpoint, using: DirectLink.pairingParameters)
    self.connection = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.connection === connection else { return }
      switch state {
      case .ready:
        guard self.requester == nil else { return }
        let requester = PairingRequester(
          transport: connection,
          queue: queue,
          name: name,
          onDigits: { [weak self] digits in
            guard let self, !isOver else { return }
            self.digits = digits
            onState(.confirming(digits: digits))
          },
          completion: { [weak self] result in
            switch result {
            case let .success(code): self?.hold(code)
            case .failure(.refused): self?.finish(.failed("Pairing wasn't allowed on your iPhone"))
            case .failure(.failed): self?.finish(.failed("Pairing didn't finish. Keep Nothering open on your iPhone and try again"))
            }
          }
        )
        self.requester = requester
        requester.start()
      case let .waiting(error), let .failed(error):
        // Not the end: the phone may be reachable in a moment, or another way. The search's time
        // limit is what ends it.
        logger.notice("pairing connection: \(error.debugDescription, privacy: .public)")
        guard requester == nil else {
          return finish(.failed("Pairing didn't finish. Keep Nothering open on your iPhone and try again"))
        }
        connection.cancel()
        self.connection = nil
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in self?.askNext() }
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  /// A phone handed over a code. Nothing is done with it before the person confirms.
  private func hold(_ code: String) {
    guard !isOver, let digits else { return finish(.failed("Pairing didn't finish. Try again")) }
    held = code
    tearDown()
    onState(.answered(digits: digits))
  }

  private func finish(_ state: State) {
    guard !isOver else { return }
    isOver = true
    held = nil
    tearDown()
    onState(state)
  }

  private func tearDown() {
    browser?.cancel()
    browser = nil
    candidates = []
    requester?.cancel()
    requester = nil
    connection?.cancel()
    connection = nil
  }
}
