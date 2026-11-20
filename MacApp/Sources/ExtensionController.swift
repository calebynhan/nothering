import AppKit
import Foundation
import NetworkExtension
import Observation
import SystemExtensions

/// Installs the proxy system extension and turns the transparent proxy configuration on and off.
@MainActor
@Observable
final class ExtensionController: NSObject {
  static let extensionIdentifier = "\(Bundle.main.bundleIdentifier ?? "app.nothering.mac").proxy"
  /// The legacy Extensions pane ID still resolves to Login Items & Extensions; `extension-points` scrolls to
  /// Extensions with the By Category tab selected.
  static let approvalSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points")!
  private static let hasTurnedOnKey = "hasTurnedOn"

  private(set) var status = "Off"
  private(set) var isRunning = false
  private(set) var isExtensionInstalled = false
  /// Whether macOS holds the extension until the user allows it in System Settings.
  private(set) var needsApproval = false
  /// Whether capture has been on before, so the user already allowed the proxy configurations macOS asks about.
  private(set) var hasTurnedOn = UserDefaults.standard.bool(forKey: hasTurnedOnKey) {
    didSet { UserDefaults.standard.set(hasTurnedOn, forKey: Self.hasTurnedOnKey) }
  }
  /// Called when capture turns on or off, however that came about. Set by the app.
  @ObservationIgnored var onRunningChange: (@MainActor () -> Void)?
  private var manager: NETransparentProxyManager?
  private var loading: Task<Void, Never>?
  /// The turn-on under way, for whoever asks for one meanwhile. Its value says whether it went
  /// through without an error.
  private var turningOn: Task<Bool, Never>?
  /// What was asked for last, on or off. A turn-on that is still waiting or saving gives way to a
  /// later off.
  private var isOnWanted = false
  /// The last turn-on couldn't save the configuration, most likely because the person said no to
  /// macOS's question.
  private var wasSaveRefused = false
  private var isRemoving = false
  private var propertiesRequest: ObjectIdentifier?
  private var isWatchingApproval = false

  override init() {
    super.init()
    NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStatus() }
    }
    loading = Task { await load() }
  }

  func installExtension() {
    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Turns capture off, deletes both proxy configurations, and uninstalls the system extension.
  func removeExtension() async {
    isOnWanted = false
    await loading?.value
    status = "Removing extension…"
    manager?.connection.stopVPNTunnel()
    try? await manager?.removeFromPreferences()
    manager = nil
    let dnsProxy = NEDNSProxyManager.shared()
    try? await dnsProxy.loadFromPreferences()
    try? await dnsProxy.removeFromPreferences()
    isRemoving = true
    let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Looks up the extension's state without activating it, so launching never triggers the system's approval alert.
  /// An already approved extension is re-activated to pick up a newer bundled version, which macOS does silently.
  func checkExtension() {
    let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    propertiesRequest = ObjectIdentifier(request)
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Starts approval: activates the extension if it was never submitted (macOS then asks for approval),
  /// otherwise opens the Login Items & Extensions pane with step-by-step instructions beside it.
  func approveExtension() {
    if needsApproval {
      openApprovalSettings()
    } else {
      installExtension()
    }
  }

  private func openApprovalSettings() {
    ApprovalGuide.openSettings()
    ApprovalGuide.show()
    // Approving an extension that was already waiting doesn't call back any request, so watch for it.
    guard !isWatchingApproval else { return }
    isWatchingApproval = true
    checkExtension()
  }

  private func foundProperties(_ properties: [OSSystemExtensionProperties]) {
    let current = properties.filter { !$0.isUninstalling }
    if current.contains(where: \.isEnabled) {
      let wasApproving = needsApproval || isWatchingApproval
      isWatchingApproval = false
      needsApproval = false
      guard !isExtensionInstalled else { return }
      if wasApproving {
        isExtensionInstalled = true
        ApprovalGuide.close(approved: true)
      } else {
        installExtension()
      }
    } else {
      needsApproval = current.contains(where: \.isAwaitingUserApproval)
      if isWatchingApproval {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkExtension() }
      }
    }
  }

  func toggle() async {
    if isRunning {
      turnOff()
    } else {
      await turnOn()
    }
  }

  func turnOff() {
    isOnWanted = false
    manager?.connection.stopVPNTunnel()
    if manager == nil {
      // Asked before the saved configuration was loaded, e.g. by nothering://off opening the app:
      // there was nothing to stop yet. Once it is there, unless on was asked for meanwhile.
      Task {
        await loading?.value
        if !isOnWanted { manager?.connection.stopVPNTunnel() }
      }
    }
    Task { try? await setDNSProxyEnabled(false) }
  }

  /// The off of "Turn on and off with iPhone proxy": capture that is on, and a turn-on still under
  /// way, which gives way to it. Nothing else: turnOff() saves the DNS proxy's configuration, and a
  /// Mac that never had capture on would be asked to allow it.
  func turnOffAutomatically() {
    guard isRunning || turningOn != nil else { return }
    turnOff()
  }

  /// Asks once more for a switch-on by hand that left capture off, e.g. one made while the Mac had
  /// no network at all. Not after the configuration couldn't be saved: that is where macOS asks, and
  /// a person who just said no isn't asked again by the app. A start that failed is tried again.
  func turnOnAgain() async {
    guard !isRunning, !wasSaveRefused else { return }
    await turnOn()
  }

  /// A DNS proxy has no start/stop; it runs whenever its (system-wide, single) configuration is enabled.
  private func setDNSProxyEnabled(_ enabled: Bool) async throws {
    let manager = NEDNSProxyManager.shared()
    try await manager.loadFromPreferences()
    let configuration = NEDNSProxyProviderProtocol()
    configuration.providerBundleIdentifier = Self.extensionIdentifier
    manager.providerProtocol = configuration
    manager.localizedDescription = "Nothering DNS"
    manager.isEnabled = enabled
    try await manager.saveToPreferences()
  }

  /// Turns capture on for the auto turn-on option. Skipped until the user has turned it on by hand once,
  /// since the first time macOS asks to allow the proxy configurations.
  func turnOnAutomatically() async {
    await loading?.value
    guard hasTurnedOn, !isRunning else { return }
    await turnOn()
  }

  /// One at a time. Capture only shows as on once it has started, so a second request can come
  /// while the first is still saving the configuration, and two that save at once leave two
  /// configurations. A request that finds one under way waits for it, and goes itself only if that
  /// one went through and still left capture off.
  func turnOn() async {
    isOnWanted = true
    while let turningOn {
      let wentThrough = await turningOn.value
      if isRunning || !wentThrough || !isOnWanted { return }
    }
    let task = Task<Bool, Never> {
      let wentThrough = await turnOnNow()
      turningOn = nil
      return wentThrough
    }
    turningOn = task
    _ = await task.value
  }

  /// Returns whether capture was started without an error.
  private func turnOnNow() async -> Bool {
    // Waiting for the saved configuration keeps an early turn-on from saving a duplicate one.
    await loading?.value
    wasSaveRefused = false
    let manager: NETransparentProxyManager
    do {
      manager = try await configuredManager()
    } catch {
      status = "Error: \(error.localizedDescription)"
      wasSaveRefused = true
      return false
    }
    // Switched off while the configuration was being saved.
    guard isOnWanted else { return false }
    do {
      try manager.connection.startVPNTunnel()
      try await setDNSProxyEnabled(true)
    } catch {
      status = "Error: \(error.localizedDescription)"
      return false
    }
    // Switched off while the DNS proxy's configuration was being saved: its save may have come
    // before this one, so it is saved off once more, after it.
    if !isOnWanted {
      manager.connection.stopVPNTunnel()
      try? await setDNSProxyEnabled(false)
      return false
    }
    return true
  }

  private func load() async {
    let managers = (try? await NETransparentProxyManager.loadAllFromPreferences()) ?? []
    for stale in managers where Self.providerIdentifier(of: stale) != Self.extensionIdentifier {
      try? await stale.removeFromPreferences()
    }
    manager = managers.first { Self.providerIdentifier(of: $0) == Self.extensionIdentifier }
    refreshStatus()
  }

  private static func providerIdentifier(of manager: NETransparentProxyManager) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
  }

  private func configuredManager() async throws -> NETransparentProxyManager {
    let manager = manager ?? NETransparentProxyManager()
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = Self.extensionIdentifier
    configuration.serverAddress = "iPhone"
    manager.protocolConfiguration = configuration
    manager.localizedDescription = "Nothering"
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    self.manager = manager
    return manager
  }

  private func refreshStatus() {
    let connectionStatus = manager?.connection.status ?? .invalid
    let wasRunning = isRunning
    isRunning = connectionStatus == .connected || connectionStatus == .connecting
    if isRunning != wasRunning {
      onRunningChange?()
    }
    switch connectionStatus {
    case .connected:
      status = "On"
      hasTurnedOn = true
    case .connecting: status = "Turning on…"
    case .disconnecting: status = "Turning off…"
    default: if !status.hasPrefix("Error"), !status.hasPrefix("Install") { status = "Off" }
    }
  }
}

extension ExtensionController: OSSystemExtensionRequestDelegate {
  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    Task { @MainActor in
      needsApproval = true
      openApprovalSettings()
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
    Task { @MainActor in foundProperties(properties) }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    let id = ObjectIdentifier(request)
    Task { @MainActor in
      guard id != propertiesRequest else { return }
      isExtensionInstalled = !isRemoving && result == .completed
      isRemoving = false
      needsApproval = false
      isWatchingApproval = false
      refreshStatus()
      ApprovalGuide.close(approved: isExtensionInstalled)
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    let id = ObjectIdentifier(request)
    Task { @MainActor in
      guard id != propertiesRequest else { return }
      // A failed removal leaves the extension installed.
      isExtensionInstalled = isRemoving
      isRemoving = false
      isWatchingApproval = false
      needsApproval = false
      status = "Error: \(error.localizedDescription)"
      ApprovalGuide.close(approved: false)
    }
  }
}
