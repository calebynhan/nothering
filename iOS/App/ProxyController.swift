import Foundation
import Observation
import ProxyCore
import UIKit
import UserNotifications

/// Runs the SOCKS5 server in the app process, kept alive in the background by `BackgroundKeeper`.
///
/// A packet tunnel extension can't be used here: iOS only lets it accept connections on the
/// primary interface, so Personal Hotspot and USB clients never reach it.
@MainActor
@Observable
final class ProxyController {
  /// One for the app, so the Mac's Bluetooth wake reaches it with no window on screen.
  static let shared = ProxyController()

  private(set) var isRunning = false
  private(set) var stats = ProxyServer.Stats()
  private(set) var lastError: String?
  private(set) var startedAt: Date?
  /// Per-second throughput for the last `sampleWindow` seconds, oldest first.
  private(set) var samples: [ThroughputSample] = []
  /// Links the Mac had a connection on within the last `linkTimeout`.
  private(set) var macLinks: Set<ProxyServer.Link> = []
  /// Lifetime traffic, kept across launches.
  private(set) var usage = ProxyController.loadUsage()
  /// Bytes relayed in the last session that carried any, kept across launches so it stays visible.
  private(set) var sessionUsage = UInt64(max(0, UserDefaults.standard.integer(forKey: ProxyController.sessionUsageKey)))
  /// The proxy runs and has carried nothing yet, so `sessionUsage` is still the session before.
  /// Opening the app starts the proxy, and would otherwise wipe the very figure it was opened for.
  private(set) var isSessionNew = false
  /// The pairing code for the direct Wi-Fi link. Made once and kept, so the Mac is paired once,
  /// until the person asks for a new one.
  private(set) var directLinkCode = ProxyController.loadDirectLinkCode()
  /// Why a Mac can't use the direct Wi-Fi link right now, e.g. Local Network access is off.
  private(set) var directLinkProblem: String?
  /// Bluetooth is off for the app, so a paired Mac can't start the proxy from afar.
  private(set) var isWakeDenied = false
  /// A Mac asking to be paired, for the person to allow or not.
  private(set) var pairingPrompt: PairingPrompt?
  /// A Mac has the pairing code. From then on nobody may ask for it unless the person opens
  /// pairing: a question out of nowhere, in that Mac's name, is what a stranger in range would send.
  private(set) var hasPairedMac = UserDefaults.standard.bool(forKey: ProxyController.hasPairedMacKey) {
    didSet { UserDefaults.standard.set(hasPairedMac, forKey: Self.hasPairedMacKey) }
  }
  /// Until when another Mac may ask, after the person said so.
  private(set) var pairingOpenUntil = Date.distantPast
  /// When the person last allowed a Mac to pair. That Mac connects some seconds later, once it
  /// was confirmed on the Mac too.
  @ObservationIgnored private var pairingAllowedAt = Date.distantPast
  @ObservationIgnored private var pairingAnswer: (@Sendable (Bool) -> Void)?
  /// The person stopped the proxy since the app last came to the front, so coming to the front
  /// again doesn't start it right back.
  @ObservationIgnored private var wasStoppedByHand = false
  /// Opening the app started the proxy, not a tap on Start.
  @ObservationIgnored private var wasStartedByOpening = false
  /// A paired Mac started the proxy over Bluetooth, with the app in the background.
  @ObservationIgnored private var wasStartedByWake = false
  /// The start under way, for whoever asks for one meanwhile.
  @ObservationIgnored private var starting: Task<Void, Never>?
  /// What the running proxy was started for.
  @ObservationIgnored private var startReason = StartReason.hand
  /// The running proxy's wait for the Mac that asked last has had its look at the 20-second mark.
  @ObservationIgnored private var didAskToOpen = false
  /// The person was asked to open the app for a Mac, and neither opened it nor did a Mac get
  /// through since. One notification per such wait. Kept across launches, with `lastWokenAt`: iOS
  /// ends a suspended app, and the Mac's next request, or a tap on the notification, launches it
  /// anew.
  @ObservationIgnored private var isMacWaiting = UserDefaults.standard.bool(forKey: ProxyController.isMacWaitingKey) {
    didSet { UserDefaults.standard.set(isMacWaiting, forKey: Self.isMacWaitingKey) }
  }
  /// When a paired Mac last asked over Bluetooth, see `macSilenceEndsWait`.
  @ObservationIgnored private var lastWokenAt =
    UserDefaults.standard.object(forKey: ProxyController.lastWokenAtKey) as? Date ?? .distantPast {
    didSet { UserDefaults.standard.set(lastWokenAt, forKey: Self.lastWokenAtKey) }
  }
  /// When a paired Mac last asked the running proxy to be there, until one gets through or the
  /// proxy stops.
  @ObservationIgnored private var macAskedAt: Date?
  @ObservationIgnored private var hadMacLink = false
  /// Since when the running proxy has waited for a Mac: its start, or the moment the person
  /// opened the app for one a Mac had woken.
  @ObservationIgnored private var waitingSince = Date.distantPast
  /// Lets a paired Mac start the proxy over Bluetooth, see `DirectLinkWake`.
  @ObservationIgnored private var wakeBeacon: DirectLinkWakeBeacon?
  /// The person has the app in front of them.
  @ObservationIgnored private var isInFront = false
  /// The person was asked to open the app for a Mac that is still asking, and did. Until the app
  /// leaves the front that counts like "Start when opened", see `ContentView.opened()`.
  @ObservationIgnored private(set) var wasOpenedForMac = false

  struct PairingPrompt: Identifiable {
    let id = UUID()
    let name: String
    let digits: String
  }

  struct ThroughputSample: Identifiable {
    let id: Int
    let up: Double
    let down: Double
  }

  static let sampleWindow = 60
  /// The Mac keeps connections open only while traffic flows and probes the phone every 10 seconds,
  /// so a link stays connected for a while after its last connection.
  private static let linkTimeout: Duration = .seconds(15)
  /// The direct link takes about ten seconds to notice that its connection is gone and a few more
  /// to be found and connected again, so its Mac gets longer to come back before the proxy stops.
  /// Shorter than the Mac's own pause after it lets the iPhone go.
  private static let directLinkTimeout: Duration = .seconds(45)
  /// How long a proxy that opening the app started waits for a Mac. Past it the proxy stops, or
  /// it would play silence until the battery is empty.
  private static let openedWithoutMacTimeout: TimeInterval = 10 * 60
  /// The same for a proxy the Mac woke. That Mac is right there and connects within seconds.
  private static let wokenWithoutMacTimeout: TimeInterval = 2 * 60
  /// How long after a wake the Mac may take to connect before the person is asked to open the app.
  private static let askToOpenAfter: TimeInterval = 20
  /// A Mac that hasn't asked for this long has given up, and the next one to ask starts a new
  /// wait with a notification of its own. Longer than two of a Mac's longest pauses between
  /// requests, which are ten minutes each, since one request can go unheard: it keeps asking for as
  /// long as it is switched on, and a notification for each request would ring all night.
  private static let macSilenceEndsWait: TimeInterval = 25 * 60
  private static let askToOpenIdentifier = "wake"

  private var server: ProxyServer?
  private var sampleIndex = 0
  private var lastSampledAt = ContinuousClock.now
  private var linkSeenAt: [ProxyServer.Link: ContinuousClock.Instant] = [:]
  private let keeper = BackgroundKeeper()
  private let terminationAlert = TerminationAlert()
  private var statsTimer: Timer?

  /// Whether the user left the proxy on, so a relaunch after iOS terminated the app starts it again.
  private static let wasRunningKey = "wasRunning"
  private static let usageKey = "usageLog"
  private static let sessionUsageKey = "sessionUsage"
  private static let directLinkCodeKey = "directLinkCode"
  private static let hasPairedMacKey = "hasPairedMac"
  private static let isMacWaitingKey = "isMacWaiting"
  private static let lastWokenAtKey = "lastWokenAt"
  /// How long pairing stays open after the person asked for it.
  private static let pairingWindow: TimeInterval = 2 * 60
  /// Saving every tick would rewrite defaults each second; a crash loses at most this many seconds.
  private static let usageSaveInterval = 10
  private var unsavedUsageTicks = 0

  private static func loadDirectLinkCode() -> String {
    if let code = UserDefaults.standard.string(forKey: directLinkCodeKey), DirectLinkCode.isValid(code) {
      return DirectLinkCode.format(code)
    }
    let code = DirectLinkCode.generate()
    UserDefaults.standard.set(code, forKey: directLinkCodeKey)
    return code
  }

  private static func loadUsage() -> UsageLog {
    guard let data = UserDefaults.standard.data(forKey: usageKey) else { return UsageLog() }
    return (try? JSONDecoder().decode(UsageLog.self, from: data)) ?? UsageLog()
  }

  private func saveUsage() {
    unsavedUsageTicks = 0
    guard let data = try? JSONEncoder().encode(usage) else { return }
    UserDefaults.standard.set(data, forKey: Self.usageKey)
    UserDefaults.standard.set(Int(clamping: sessionUsage), forKey: Self.sessionUsageKey)
  }

  private func record(up: UInt64, down: UInt64) {
    guard up > 0 || down > 0 else { return }
    if isSessionNew {
      // The session's first traffic is where its figure starts over.
      isSessionNew = false
      sessionUsage = 0
    }
    usage.record(up: up, down: down)
    sessionUsage &+= up &+ down
  }

  var shouldRestore: Bool {
    UserDefaults.standard.bool(forKey: Self.wasRunningKey)
  }

  init() {
    NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        // The process is gone a moment after this returns. A Mac on the direct link gets that
        // moment to take the event.
        self?.server?.send(.terminating, waitingUpTo: 0.5)
        self?.recordUsage()
        self?.saveUsage()
        self?.terminationAlert.fireNow()
      }
    }
    #if !targetEnvironment(simulator)
      wakeBeacon = DirectLinkWakeBeacon(code: directLinkCode) { [weak self] in
        Task { @MainActor in await self?.startBecauseWoken() }
      }
    #endif
  }

  /// Called when the app becomes active, in case the keeper stopped while the app was suspended.
  func resumeKeeper() {
    guard isRunning else { return }
    keeper.resume()
  }

  /// Called when the app becomes active. A Mac may ask to be paired while the person is looking,
  /// and only then. It is also the one moment the wake's Bluetooth service can be put back for
  /// certain after Bluetooth was off, and when a change in Settings shows.
  func cameToFront() {
    isInFront = true
    if isMacWaiting, 0...Self.macSilenceEndsWait ~= Date.now.timeIntervalSince(lastWokenAt) {
      // Asked to open the app for a Mac, and here it is: that is asking for the proxy, whatever
      // "Start when opened" says. The view starts it, after a proxy left on had its turn.
      wasOpenedForMac = true
    }
    waitForMacIsOver()
    if isRunning, wasStartedByWake || wasStartedByOpening, !hadMacLink {
      // Opened again with a proxy no Mac has come for, e.g. for the Mac that woke it. From here it
      // waits as long as one this opening had started, and not for what is left of the time it had.
      waitsAsOpened()
    } else if !isRunning, let starting {
      // Opened while a wake is still starting the proxy, which then gets the same.
      Task { [weak self] in
        await starting.value
        guard let self, isInFront, isRunning, wasStartedByWake, !hadMacLink else { return }
        waitsAsOpened()
      }
    }
    updatePairing()
    #if !targetEnvironment(simulator)
      wakeBeacon?.refresh()
      isWakeDenied = DirectLinkWakeBeacon.isDenied
    #endif
  }

  /// The running proxy waits for a Mac like one that opening the app started, counted from now.
  private func waitsAsOpened() {
    wasStartedByWake = false
    wasStartedByOpening = true
    startReason = .opened
    waitingSince = .now
  }

  /// Whether a Mac may ask to be paired right now: only while the person is looking, and once a
  /// Mac is paired only for a while after they said another one may.
  var isPairingOpen: Bool {
    isInFront && (!hasPairedMac || pairingOpenUntil > .now)
  }

  private func updatePairing() {
    server?.setAcceptsPairing(isPairingOpen)
  }

  /// The person wants to pair one more Mac.
  func pairAnotherMac() async {
    // Pairing is served by the proxy, so it has to run. Like one that opening the app started, it
    // stops by itself if no Mac comes.
    if !isRunning {
      await start(.opened)
    }
    guard isRunning else { return }
    if startReason != .hand, !hadMacLink {
      // One that is already running, with no Mac yet, counts its time from here.
      waitsAsOpened()
    }
    let until = Date.now.addingTimeInterval(Self.pairingWindow)
    pairingOpenUntil = until
    // Anew: what paired the last Mac lets nobody ask again.
    server?.setAcceptsPairing(false)
    updatePairing()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.pairingWindow))
      guard let self, pairingOpenUntil == until else { return }
      pairingOpenUntil = .distantPast
      updatePairing()
    }
  }

  /// Replaces the pairing code. Macs paired with the old one are let go, and have to pair again.
  func newPairingCode() async {
    // A start under way was given the old code, and would go on serving it. Once it is done it
    // is stopped like any other.
    while let starting {
      await starting.value
    }
    let wasRunning = isRunning
    let reason = startReason
    if wasRunning { stop() }
    directLinkCode = DirectLinkCode.generate()
    UserDefaults.standard.set(directLinkCode, forKey: Self.directLinkCodeKey)
    wakeBeacon?.use(code: directLinkCode)
    hasPairedMac = false
    pairingOpenUntil = .distantPast
    // As what it was, with its time limit. A proxy the Mac woke comes back as one that opening
    // started: that Mac was just let go, and nobody is waiting.
    if wasRunning { await start(reason == .woken ? .opened : reason) }
  }

  func setFocusSound(_ sound: FocusSound) {
    keeper.sound = sound
  }

  /// Asks for notification permission when turning on, and reports whether it ended up on.
  func setNotifiesOnTermination(_ enabled: Bool) async -> Bool {
    var enabled = enabled
    if enabled {
      enabled = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    UserDefaults.standard.set(enabled, forKey: TerminationAlert.enabledKey)
    if isRunning {
      terminationAlert.arm()
    } else {
      terminationAlert.disarm()
    }
    return enabled
  }

  func toggle() async {
    if isRunning {
      wasStoppedByHand = true
      stop()
    } else {
      await start()
    }
  }

  /// Opening the app is asking for the proxy, so with "Start when opened" there is nothing to tap.
  func startBecauseOpened() async {
    guard !isRunning, !wasStoppedByHand else { return }
    await start(.opened)
  }

  func didEnterBackground() {
    wasStoppedByHand = false
    wasOpenedForMac = false
    isInFront = false
    pairingOpenUntil = .distantPast
    updatePairing()
  }

  /// A paired Mac asked for the proxy over Bluetooth, so nobody has to pick up the iPhone.
  func startBecauseWoken() async {
    // A saved time later than now, after the clock was set back, is as stale as an old one.
    if !(0...Self.macSilenceEndsWait ~= Date.now.timeIntervalSince(lastWokenAt)) {
      isMacWaiting = false
    }
    lastWokenAt = .now
    guard !isRunning else {
      // The proxy is there already, but the Mac that asks still has to find it. Its wait starts
      // here, as it would for a proxy this request had started. A link the iPhone still counts may
      // be the very one this Mac lost.
      macAskedAt = .now
      didAskToOpen = false
      return
    }
    // A proxy the person had left on, which iOS ended with the app, comes back as theirs.
    await start(shouldRestore ? .hand : .woken)
    if isRunning {
      macAskedAt = .now
    } else if starting == nil, !isInFront {
      // iOS didn't let the proxy start in the background. A tap on the notification opens the
      // app, which starts it. A proxy that is being started over is no failed start. With the app
      // in front there is nothing to open: the Mac's next request gets its own look.
      askToOpen()
    }
  }

  /// The person opened the app, or the Mac got through: the notification that asked for the app
  /// to be opened has nothing left to say, and the next wait may ask again.
  private func waitForMacIsOver() {
    isMacWaiting = false
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.askToOpenIdentifier])
  }

  /// The fallback when a wake isn't enough. Shows only if notifications are allowed. Once per
  /// wait, however often the Mac asks.
  private func askToOpen() {
    guard !isMacWaiting else { return }
    isMacWaiting = true
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Your Mac is waiting")
    content.body = String(localized: "Open Nothering to let your Mac use this iPhone's connection.")
    content.sound = .default
    let request = UNNotificationRequest(identifier: Self.askToOpenIdentifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  /// The person's answer to the question `id`, or to whichever is open when the question goes
  /// away unanswered. An alert that still shows an earlier request allows nothing: its number
  /// isn't the one that would be allowed.
  func answerPairing(_ allowed: Bool, for id: UUID? = nil) {
    let isAllowed = allowed && pairingPrompt != nil && (id == nil || id == pairingPrompt?.id)
    pairingAnswer?(isAllowed)
    pairingAnswer = nil
    pairingPrompt = nil
    if isAllowed {
      // Pairing is closed from here on. Not by taking it down this instant, which could cut off
      // the code on its way to the Mac: after a yes it lets nobody ask again by itself.
      hasPairedMac = true
      pairingOpenUntil = .distantPast
      pairingAllowedAt = .now
    }
  }

  private func showPairing(_ request: DirectLinkPairingRequest?) {
    guard let request else {
      // The request is over: the Mac gave up, or it has its answer. After a yes this is where
      // pairing is taken down, now that the code has gone out. Left up, it would keep the radio
      // busy announcing what nobody may ask for.
      pairingAnswer = nil
      pairingPrompt = nil
      updatePairing()
      return
    }
    pairingAnswer = request.answer
    pairingPrompt = PairingPrompt(name: request.name, digits: request.digits)
  }

  /// What a start was for. It decides how long the proxy waits for a Mac, and whether it comes
  /// back after iOS ended the app.
  enum StartReason {
    /// A tap on Start.
    case hand
    /// The app was opened, with "Start when opened" on.
    case opened
    /// A paired Mac asked over Bluetooth.
    case woken
  }

  /// Starts the proxy. Asked again while a start is under way, it waits for that one: the app's
  /// first moments ask twice, and a second start would fail on the port the first one holds, and
  /// take the first one's keeper down with it.
  func start(_ reason: StartReason = .hand) async {
    if let starting {
      await starting.value
      // The start that was under way may have been for less. A tap on Start makes the proxy the
      // person's: no time limit, and back after iOS ended the app. Opening the app gives one a
      // Mac woke the time an opened one gets.
      if isRunning, reason == .hand, startReason != .hand {
        startReason = .hand
        wasStartedByOpening = false
        wasStartedByWake = false
        UserDefaults.standard.set(true, forKey: Self.wasRunningKey)
      } else if isRunning, reason == .opened, startReason == .woken, !hadMacLink {
        startReason = .opened
        wasStartedByOpening = true
        wasStartedByWake = false
        waitingSince = .now
      }
      return
    }
    guard !isRunning else { return }
    let task = Task {
      await startNow(reason)
      starting = nil
    }
    starting = task
    await task.value
  }

  private func startNow(_ reason: StartReason) async {
    lastError = nil
    #if targetEnvironment(simulator)
      // The simulator has no cellular, and shares the Mac's ports with the menu bar app's forwarder.
      let server = ProxyServer(configuration: .init(port: 11081, requiredInterfaceType: nil))
    #else
      let server = ProxyServer(configuration: .init(
        directLinkCode: directLinkCode,
        onPairingRequest: { [weak self] request in
          Task { @MainActor in self?.showPairing(request) }
        }
      ))
    #endif
    do {
      try await server.start()
      try keeper.start()
    } catch {
      server.stop()
      keeper.stop()
      lastError = error.localizedDescription
      return
    }
    self.server = server
    updatePairing()
    stats = ProxyServer.Stats()
    samples = []
    macLinks = []
    linkSeenAt = [:]
    isSessionNew = true
    startReason = reason
    wasStartedByOpening = reason == .opened
    wasStartedByWake = reason == .woken
    didAskToOpen = false
    hadMacLink = false
    macAskedAt = nil
    saveUsage()
    let startedAt = Date.now
    self.startedAt = startedAt
    waitingSince = startedAt
    lastSampledAt = .now
    isRunning = true
    // Only a proxy the person started comes back as one after iOS ended the app. One that opening
    // or a wake started would come back with no time limit, and play silence until the battery
    // is empty.
    UserDefaults.standard.set(reason == .hand, forKey: Self.wasRunningKey)
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStats() }
    }
    RunLoop.main.add(timer, forMode: .common)
    statsTimer = timer
    terminationAlert.arm()
  }

  func stop() {
    recordUsage()
    saveUsage()
    statsTimer?.invalidate()
    statsTimer = nil
    server?.send(.stopped)
    server?.stop()
    server = nil
    keeper.stop()
    terminationAlert.disarm()
    startedAt = nil
    directLinkProblem = nil
    answerPairing(false)
    pairingOpenUntil = .distantPast
    pairingAllowedAt = .distantPast
    macAskedAt = nil
    isSessionNew = false
    isRunning = false
    UserDefaults.standard.set(false, forKey: Self.wasRunningKey)
  }

  private func refreshStats() {
    guard let server else { return }
    keeper.resume()
    terminationAlert.refresh()
    let previous = stats
    stats = server.currentStats()
    directLinkProblem = server.directLinkProblem()
    record(up: stats.bytesUp &- previous.bytesUp, down: stats.bytesDown &- previous.bytesDown)
    unsavedUsageTicks += 1
    if unsavedUsageTicks >= Self.usageSaveInterval {
      saveUsage()
    }
    let now = ContinuousClock.now
    let elapsed = max((now - lastSampledAt) / .seconds(1), 0.001)
    lastSampledAt = now
    samples.append(ThroughputSample(
      id: sampleIndex,
      up: Double(stats.bytesUp &- previous.bytesUp) / elapsed,
      down: Double(stats.bytesDown &- previous.bytesDown) / elapsed
    ))
    sampleIndex += 1
    if samples.count > Self.sampleWindow {
      samples.removeFirst(samples.count - Self.sampleWindow)
    }
    refreshMacLinks(previous: previous, now: now)
  }

  /// How long a proxy that nobody tapped Start for waits for a Mac, or `nil` for one started by hand.
  private var unattendedTimeout: TimeInterval? {
    if wasStartedByWake { return Self.wokenWithoutMacTimeout }
    if wasStartedByOpening { return Self.openedWithoutMacTimeout }
    return nil
  }

  /// Adds traffic since the last refresh, so stopping doesn't drop the final second.
  private func recordUsage() {
    guard let server else { return }
    let latest = server.currentStats()
    record(up: latest.bytesUp &- stats.bytesUp, down: latest.bytesDown &- stats.bytesDown)
    stats = latest
  }

  /// Counts only connections opened since the last refresh, not open ones: a Mac that vanished without
  /// a FIN leaves its event stream open forever, while a live Mac opens a probe every 10 seconds.
  private func refreshMacLinks(previous: ProxyServer.Stats, now: ContinuousClock.Instant) {
    if stats.totalUSBConnections > previous.totalUSBConnections {
      linkSeenAt[.usb] = now
    }
    if stats.totalHotspotConnections > previous.totalHotspotConnections {
      linkSeenAt[.hotspot] = now
    }
    if stats.totalDirectConnections > previous.totalDirectConnections {
      // A Mac that wasn't on the direct link is now: the one just allowed has connected. Links are
      // counted by kind, not by Mac, so one that was already on it hides this, and the window runs out.
      if !macLinks.contains(.direct) { pairingAllowedAt = .distantPast }
      linkSeenAt[.direct] = now
      // A Mac has the code, also one it was typed into.
      if !hasPairedMac {
        hasPairedMac = true
        updatePairing()
      }
    }
    let hadLinks = !macLinks.isEmpty
    let gotConnection = stats.totalConnections > previous.totalConnections
    macLinks = Set(linkSeenAt.filter {
      now - $0.value < ($0.key == .direct ? Self.directLinkTimeout : Self.linkTimeout)
    }.keys)
    if !hadMacLink, !macLinks.isEmpty {
      hadMacLink = true
      waitForMacIsOver()
    }
    // A Mac got through. Only a new connection says so: a link stays counted for a while after
    // its last one. That ends a wait for it too, also one that began while the link it had lost
    // was still counted.
    if gotConnection, !macLinks.isEmpty {
      macAskedAt = nil
      if isMacWaiting { waitForMacIsOver() }
    }
    // Keeping the silent audio running with no client drains the battery, so turn off once the last Mac leaves.
    if hadLinks, macLinks.isEmpty {
      if pairingOpenUntil > .now || pairingPrompt != nil
        || 0...Self.pairingWindow ~= Date.now.timeIntervalSince(pairingAllowedAt) {
        // Unless the person is pairing a Mac, which needs it: pairing is open, a Mac is asking, or
        // one was allowed in the last two minutes and hasn't come on the direct link yet. From here
        // it waits like a proxy that opening the app started.
        hadMacLink = false
        waitsAsOpened()
      } else if let macAskedAt, Date.now.timeIntervalSince(macAskedAt) < Self.wokenWithoutMacTimeout {
        // Or a Mac asked for it since that one went, over Bluetooth. From here it waits for that
        // Mac like a proxy its request had started, counted from the request.
        hadMacLink = false
        startReason = .woken
        wasStartedByWake = true
        wasStartedByOpening = false
        waitingSince = macAskedAt
      } else {
        stop()
        return
      }
      // Either way it is no longer one the person left on, to come back after iOS ended the app.
      UserDefaults.standard.set(false, forKey: Self.wasRunningKey)
    }
    if let macAskedAt, !didAskToOpen, Date.now.timeIntervalSince(macAskedAt) > Self.askToOpenAfter {
      // The Mac that asked can't find the proxy, whatever it was started for. From the background
      // it may not be able to, and opening the app fixes that.
      didAskToOpen = true
      // With the app in front there is nothing to open, and that doesn't count as having asked:
      // the Mac's next request gets its own look.
      if !isInFront {
        askToOpen()
      }
    }
    if !hadMacLink, let limit = unattendedTimeout {
      // Nobody tapped Start for this one, and no Mac came for it. It waits its own time, and
      // never less than the wake's from a Mac's last request.
      var end = waitingSince.addingTimeInterval(limit)
      if let macAskedAt {
        end = max(end, macAskedAt.addingTimeInterval(Self.wokenWithoutMacTimeout))
      }
      if Date.now > end {
        stop()
      }
    }
  }
}
