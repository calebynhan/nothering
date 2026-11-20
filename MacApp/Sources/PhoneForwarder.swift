import Darwin
import Foundation
import Network
import Observation
import PhoneLink
import ProxyCore

/// Owns the link to the iPhone and serves it on 127.0.0.1:11080 for the proxy extension,
/// which is sandboxed and can't reach usbmux or pick a link itself.
@MainActor
@Observable
final class PhoneForwarder {
  enum Link: String, Sendable {
    case usb = "USB"
    case hotspot = "Hotspot"
    case direct = "Direct"
    case none = "Not connected"
  }

  /// Which link to use; `auto` prefers USB and falls back to the hotspot.
  ///
  /// `direct` reaches the phone over device-to-device Wi-Fi, with no cable and no hotspot. It is
  /// never picked by `auto`: with a cable or the hotspot the user connected the phone on purpose,
  /// while a phone merely in range would move a Mac on its usual Wi-Fi onto cellular data.
  enum Preference: String, CaseIterable, Sendable {
    case auto = "Auto"
    case usb = "USB"
    case hotspot = "Hotspot"
    case direct = "Direct"
  }

  private static let preferenceKey = "linkPreference"
  private static let directCodeKey = "directLinkCode"
  private static let autoTurnOnKey = "autoTurnOn"

  static let port: UInt16 = 11080

  /// The link whose Nothering proxy answers; `.none` until the phone's proxy is reachable.
  private(set) var link = Link.none
  /// How the iPhone itself is attached, whether or not its proxy is running.
  private(set) var detected = Link.none
  /// The next thing the user should do when the proxy isn't reachable, e.g. "Tap Start Proxy on your iPhone".
  private(set) var hint: String?
  private(set) var error: String?
  private(set) var stats = LocalForwarder.Stats()
  /// Whether the iPhone's proxy went away without the user stopping it, e.g. its app was swiped
  /// away or killed by iOS. Cleared once the proxy answers again.
  var phoneProxyQuit: Bool { quitDetector.hasQuit }

  func dismissPhoneProxyQuit() {
    quitDetector.dismiss()
  }
  var preference = Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto {
    didSet {
      UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
      route.preference = preference
      refreshLink()
      // Choosing the direct link without a code is asking to pair, so there is nothing more to click.
      if preference == .direct, oldValue != .direct, !isPaired, pairing == nil {
        startPairing()
      }
    }
  }
  /// The pairing code shown in Nothering on the iPhone, for the `direct` link.
  var directCode = UserDefaults.standard.string(forKey: directCodeKey) ?? "" {
    didSet {
      UserDefaults.standard.set(directCode, forKey: Self.directCodeKey)
      route.directCode = directCode
      refreshLink()
    }
  }
  /// Whether this Mac has a pairing code for the direct link, typed or from pairing.
  var isPaired: Bool { DirectLinkCode.isValid(directCode) }
  /// Where a pairing attempt stands, also after it failed. `nil` when none was made or it worked.
  private(set) var pairing: DirectLinkPairer.State?
  @ObservationIgnored private var pairer: DirectLinkPairer?
  /// Tells the current attempt's reports from those of one that was replaced.
  @ObservationIgnored private var pairingAttempt: UUID?

  /// Looks for the iPhone and asks it for its pairing code, so nothing has to be typed: the iPhone
  /// shows the same number as this Mac, and its person taps Allow.
  func startPairing() {
    pairer?.cancel()
    let attempt = UUID()
    pairingAttempt = attempt
    pairing = .searching
    let pairer = DirectLinkPairer(name: Host.current().localizedName ?? "Mac") { [weak self] state in
      Task { @MainActor in
        guard let self, self.pairingAttempt == attempt else { return }
        self.pairingChanged(to: state)
      }
    }
    self.pairer = pairer
    pairer.start()
  }

  func cancelPairing() {
    pairer?.cancel()
    pairer = nil
    pairingAttempt = nil
    pairing = nil
  }

  /// The person says the iPhone that answered was theirs: it showed the number, and they tapped
  /// Allow on it.
  func confirmPairing() {
    pairer?.confirm()
  }

  private func pairingChanged(to state: DirectLinkPairer.State) {
    switch state {
    case let .paired(code):
      pairer = nil
      pairingAttempt = nil
      pairing = nil
      // From here it is the same as a code typed in.
      directCode = code
      preference = .direct
    case .failed:
      pairer = nil
      pairingAttempt = nil
      pairing = state
    case .searching, .confirming, .answered:
      pairing = state
    }
  }

  // MARK: Waking the iPhone

  /// How often the iPhone is asked again while it is wanted and not connected.
  private static let wakeInterval: TimeInterval = 20
  /// How long the Mac stays off the direct link after capture is switched off. The iPhone's proxy
  /// stops once no Mac has connected for a while, which it never would with this one still there.
  private static let releasePause: TimeInterval = 60

  /// Whether capture is on, as the switch shows it. Set by the app.
  @ObservationIgnored var isCaptureOn: @MainActor () -> Bool = { false }
  /// Why the iPhone can't be woken, e.g. Bluetooth is off on this Mac.
  private(set) var wakeProblem: String?
  @ObservationIgnored private var waker: (code: String, waker: DirectLinkWaker)?
  @ObservationIgnored private var lastWakeAt = Date.distantPast
  /// When the person last switched capture on, which takes a moment to show in `isCaptureOn`.
  @ObservationIgnored private var switchedOnAt = Date.distantPast
  /// The person stopped the proxy on the iPhone. It isn't woken again until they use the switch here.
  @ObservationIgnored private var isWakeHeld = false

  /// The person used the capture switch. On has the iPhone start its proxy over Bluetooth, so
  /// nobody has to pick it up. Off lets the iPhone go, so its proxy stops by itself.
  func captureSwitched(on: Bool) {
    isWakeHeld = false
    if on {
      switchedOnAt = .now
      route.resumeDirect()
      refreshLink()
      wakePhoneIfWanted()
    } else {
      switchedOnAt = .distantPast
      waker?.waker.cancel()
      if preference == .direct {
        route.pauseDirect(for: Self.releasePause)
        refreshLink()
      }
    }
  }

  /// Capture is on, or about to be, so the person wants the iPhone's connection now.
  private var wantsPhone: Bool {
    isCaptureOn() || Date.now.timeIntervalSince(switchedOnAt) < Self.wakeInterval
  }

  /// Asks the iPhone to start its proxy when the direct link is wanted and not there. Only then: a
  /// Mac that woke the iPhone whenever it was near would put itself on cellular data unasked.
  private func wakePhoneIfWanted() {
    guard preference == .direct, isPaired, link == .none, pairing == nil, !isWakeHeld, wantsPhone,
          Date.now.timeIntervalSince(lastWakeAt) >= Self.wakeInterval
    else { return }
    lastWakeAt = .now
    let code = DirectLinkCode.normalized(directCode)
    if waker?.code != code {
      waker?.waker.cancel()
      waker = (code, DirectLinkWaker(code: code))
    }
    waker?.waker.wake { [weak self] outcome in
      Task { @MainActor in self?.wakeFinished(outcome) }
    }
  }

  private func wakeFinished(_ outcome: DirectLinkWaker.Outcome) {
    switch outcome {
    case .woke, .notFound:
      // Found or not, the direct link's own search picks the iPhone up once its proxy runs.
      wakeProblem = nil
    case .refused:
      wakeProblem = "An iPhone with Nothering is nearby, but it has another pairing code. If it is yours, pair again."
    case let .unavailable(reason):
      wakeProblem = reason
    }
  }

  // MARK: A Mac with no network of its own

  /// The Mac has no network of its own, and the helper that stands in for one isn't installed,
  /// see `OfflineNetwork`. Its apps won't try to connect until it is.
  private(set) var needsOfflineHelper = false

  /// Gives the Mac a stand-in network while the iPhone is linked and the Mac has none, e.g. in a
  /// car, and takes it away with the link, so the Mac never believes in a network that leads nowhere.
  private func keepMacOnline() {
    let isLinked = link != .none
    Task.detached {
      var needsHelper = false
      if isLinked {
        if !OfflineNetwork.macHasNetwork() {
          if OfflineNetwork.isInstalled {
            OfflineNetwork.up()
          } else {
            needsHelper = true
          }
        }
      } else if OfflineNetwork.isUp() {
        OfflineNetwork.down()
      }
      let result = needsHelper
      await MainActor.run { self.needsOfflineHelper = result }
    }
  }

  /// Installs the helper, with the system's dialog for an administrator's password.
  func installOfflineHelper() {
    Task.detached {
      try? OfflineNetwork.installWithPasswordDialog()
      await MainActor.run { self.refreshLink() }
    }
  }

  var autoTurnOn = UserDefaults.standard.bool(forKey: autoTurnOnKey) {
    didSet { UserDefaults.standard.set(autoTurnOn, forKey: Self.autoTurnOnKey) }
  }
  /// Called with `true` when the iPhone's proxy becomes reachable and `false` when it goes away, while
  /// `autoTurnOn` is set. Fires only on transitions, so a manual toggle sticks until the next one.
  @ObservationIgnored var onAutoTurnOn: ((Bool) -> Void)?
  private var forwarder: LocalForwarder?
  private var monitor: Timer?
  private var statsTimer: Timer?
  private let route = PhoneRoute()
  private let pathMonitor = NWPathMonitor()
  private let events = PhoneEventListener()
  private var quitDetector = PhoneQuitDetector()

  func start() {
    route.preference = preference
    route.directCode = directCode
    // The direct link connects and drops on its own schedule, not on the 10 second refresh.
    route.onDirectStatusChange = { [weak self] in
      Task { @MainActor in self?.refreshLink() }
    }
    let route = route
    // A browser alone opens more connections than a process may hold by default.
    raiseOpenFileLimit()
    let forwarder = LocalForwarder(port: Self.port) { try route.connect() }
    do {
      _ = try forwarder.start()
      self.forwarder = forwarder
    } catch {
      self.error = "Forwarder: \(error.localizedDescription)"
    }
    refreshLink()
    monitor = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLink() }
    }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let forwarder = self.forwarder else { return }
        self.stats = forwarder.currentStats()
      }
    }
    pathMonitor.pathUpdateHandler = { [weak self, route] path in
      // macOS marks an iPhone's Personal Hotspot as expensive, which identifies it even on IPv6-only
      // hotspots that hand out no 172.20.10.x address.
      route.isOnExpensiveWiFi = path.isExpensive && path.usesInterfaceType(.wifi)
      Task { @MainActor in self?.refreshLink() }
    }
    pathMonitor.start(queue: .global())
  }

  /// Re-detects the link. Probing the hotspot also serves as the keepalive iOS needs to not drop
  /// idle hotspot clients while the phone is locked.
  private func refreshLink() {
    let route = route
    Task.detached {
      let result = route.refresh()
      await MainActor.run {
        let previousLink = self.link
        let wasReachable = previousLink != .none
        let isReachable = result.link != .none
        self.link = result.link
        self.detected = result.detected
        self.hint = result.hint
        self.trackPhoneProxy(previousLink: previousLink)
        if self.autoTurnOn, wasReachable != isReachable {
          self.onAutoTurnOn?(isReachable)
        }
        self.wakePhoneIfWanted()
        self.keepMacOnline()
      }
    }
  }

  private func trackPhoneProxy(previousLink: Link) {
    quitDetector.linkChanged(
      wasReachable: previousLink != .none,
      isReachable: link != .none,
      isPhoneAttached: detected != .none
    )
    // Moves the stream off a link that's gone or no longer selected. Its `.closed` refreshes again,
    // which opens the replacement on the current link.
    if link != previousLink {
      events.stop()
    }
    guard link != .none else { return }
    let route = route
    events.listen(connect: { try route.connect() }) { [weak self] update in
      // The main queue keeps updates in order, so an old stream's events never land after the
      // `.opened` of its replacement.
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(update) }
      }
    }
  }

  private func handle(_ update: PhoneEventListener.Update) {
    quitDetector.handle(update)
    if update == .event(.stopped) {
      // Stopped by hand on the iPhone. Waking it right back would undo that.
      isWakeHeld = true
    }
    if update == .closed {
      refreshLink()
    }
  }
}

/// The current way to reach the phone, cached so each forwarded connection doesn't re-detect it
/// (running `route` per connection is too slow when a browser opens hundreds at once).
final class PhoneRoute: @unchecked Sendable {
  struct RefreshResult: Sendable {
    let link: PhoneForwarder.Link
    let detected: PhoneForwarder.Link
    let hint: String?
  }

  private static let phonePort: UInt16 = 11080
  private let lock = NSLock()
  private var usbDeviceID: Int?
  private var hotspotGateway: String?
  private var storedPreference = PhoneForwarder.Preference.auto
  private var storedIsOnExpensiveWiFi = false
  private var storedDirectCode = ""
  private var storedOnDirectStatusChange: (@Sendable () -> Void)?
  /// The direct link is left alone until then, see `pauseDirect`.
  private var directPausedUntil = Date.distantPast
  /// The direct link's client, kept while `direct` is selected with the code it was made for.
  private var direct: (code: String, client: DirectLinkClient)?

  var preference: PhoneForwarder.Preference {
    get { lock.withLock { storedPreference } }
    set { lock.withLock { storedPreference = newValue } }
  }

  var isOnExpensiveWiFi: Bool {
    get { lock.withLock { storedIsOnExpensiveWiFi } }
    set { lock.withLock { storedIsOnExpensiveWiFi = newValue } }
  }

  var directCode: String {
    get { lock.withLock { storedDirectCode } }
    set { lock.withLock { storedDirectCode = newValue } }
  }

  /// Keeps this Mac off the direct link for a while, so the iPhone sees it leave.
  func pauseDirect(for interval: TimeInterval) {
    lock.withLock { directPausedUntil = Date().addingTimeInterval(interval) }
  }

  func resumeDirect() {
    lock.withLock { directPausedUntil = .distantPast }
  }

  /// Called, on no particular queue, when the direct link connects or drops.
  var onDirectStatusChange: (@Sendable () -> Void)? {
    get { lock.withLock { storedOnDirectStatusChange } }
    set { lock.withLock { storedOnDirectStatusChange = newValue } }
  }

  @discardableResult
  func refresh() -> RefreshResult {
    let preference = preference
    guard preference != .direct else { return refreshDirect() }
    stopDirect()
    let (usb, deviceID) = preference == .hotspot ? (.notFound, nil) : probeUSB()
    let shouldProbeHotspot = preference != .usb && !usb.answers
    let (hotspot, gateway) = shouldProbeHotspot ? probeHotspot() : (.notFound, nil)
    let diagnosis = PhoneLinkDiagnosis.evaluate(
      preference: preference.diagnosisPreference,
      usb: usb,
      hotspot: hotspot
    )
    let link = diagnosis.link.forwarderLink
    let detected = diagnosis.detected.forwarderLink
    lock.withLock {
      usbDeviceID = link == .usb ? deviceID : nil
      hotspotGateway = link == .hotspot ? gateway : nil
    }
    return RefreshResult(link: link, detected: detected, hint: diagnosis.hint)
  }

  /// The direct link has nothing to detect before it connects: the phone is found or it isn't.
  private func refreshDirect() -> RefreshResult {
    lock.withLock {
      usbDeviceID = nil
      hotspotGateway = nil
    }
    let code = directCode
    guard DirectLinkCode.isValid(code) else {
      stopDirect()
      return RefreshResult(link: .none, detected: .none, hint: "Type the pairing code shown in Nothering on your iPhone")
    }
    guard lock.withLock({ directPausedUntil <= Date() }) else {
      stopDirect()
      return RefreshResult(link: .none, detected: .none, hint: "Switch Nothering on to use your iPhone's connection again")
    }
    let client = directClient(code: DirectLinkCode.normalized(code))
    switch client.currentStatus {
    case .connected:
      // Also the sign of life the phone's app waits for: it stops its proxy once no Mac has
      // connected for a while, and with capture off nothing else opens a stream.
      if let fd = try? client.connect() { close(fd) }
      return RefreshResult(link: .direct, detected: .direct, hint: nil)
    case .searching, .connecting:
      if client.foundAnotherPhone {
        return RefreshResult(link: .none, detected: .none, hint: "An iPhone with Nothering is nearby, but it has another pairing code. If it is yours, pair again")
      }
      return RefreshResult(link: .none, detected: .none, hint: "Open Nothering on your iPhone and tap Start Proxy. Wi-Fi has to be on, on both")
    case let .blocked(reason):
      return RefreshResult(link: .none, detected: .none, hint: reason)
    }
  }

  private func directClient(code: String) -> DirectLinkClient {
    let (client, replaced): (DirectLinkClient, DirectLinkClient?) = lock.withLock {
      if let direct, direct.code == code { return (direct.client, nil) }
      let replaced = direct?.client
      let onStatusChange = storedOnDirectStatusChange
      let client = DirectLinkClient(code: code, onStatusChange: { _ in onStatusChange?() })
      direct = (code, client)
      return (client, replaced)
    }
    replaced?.stop()
    // Does nothing when it is already running.
    client.start()
    return client
  }

  /// Stops looking for the phone over Wi-Fi once another link is selected, or the code is gone.
  private func stopDirect() {
    let client = lock.withLock { () -> DirectLinkClient? in
      defer { direct = nil }
      return direct?.client
    }
    client?.stop()
  }

  private func probeUSB() -> (PhoneLinkDiagnosis.USBState, Int?) {
    do {
      let deviceID = try USBMux.firstUSBDeviceID()
      do {
        close(try USBMux.connect(deviceID: deviceID, port: Self.phonePort))
        return (.found(proxyAnswers: true), deviceID)
      } catch {
        return (.found(proxyAnswers: false), deviceID)
      }
    } catch let error as LinkError where error.kind == .noUSBDevice {
      return (.notFound, nil)
    } catch {
      return (.unavailable, nil)
    }
  }

  private func probeHotspot() -> (PhoneLinkDiagnosis.HotspotState, String?) {
    do {
      let gateway = try Hotspot.gatewayAddress()
      var proxyAnswers = false
      if let fd = try? TCP.connect(host: gateway, port: Self.phonePort, timeout: 1) {
        close(fd)
        proxyAnswers = true
      }
      let state = PhoneLinkDiagnosis.hotspot(
        proxyAnswers: proxyAnswers,
        isIPhoneHotspot: Hotspot.isIPhoneHotspot(),
        isOnExpensiveWiFi: isOnExpensiveWiFi
      )
      return (state, gateway)
    } catch {
      return (.notFound, nil)
    }
  }

  func connect() throws -> Int32 {
    do {
      return try connectUsingCache()
    } catch {
      refresh()
      return try connectUsingCache()
    }
  }

  private func connectUsingCache() throws -> Int32 {
    let (deviceID, gateway, directClient) = lock.withLock {
      (usbDeviceID, hotspotGateway, storedPreference == .direct ? direct?.client : nil)
    }
    if let directClient {
      return try directClient.connect()
    }
    if let deviceID {
      return try USBMux.connect(deviceID: deviceID, port: Self.phonePort)
    }
    if let gateway {
      return try TCP.connect(host: gateway, port: Self.phonePort, timeout: 3)
    }
    throw LinkError("iPhone not connected")
  }
}

private extension PhoneForwarder.Preference {
  var diagnosisPreference: PhoneLinkDiagnosis.Preference {
    switch self {
    // The direct link is handled before the diagnosis, which only knows the other two links.
    case .auto, .direct: .auto
    case .usb: .usb
    case .hotspot: .hotspot
    }
  }
}

private extension PhoneLinkDiagnosis.Transport {
  var forwarderLink: PhoneForwarder.Link {
    switch self {
    case .none: .none
    case .usb: .usb
    case .hotspot: .hotspot
    }
  }
}

private extension PhoneLinkDiagnosis.USBState {
  var answers: Bool {
    if case .found(proxyAnswers: true) = self { true } else { false }
  }
}
