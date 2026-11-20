import ProxyCore
import ServiceManagement
import Sparkle
import SwiftUI

/// The window shown from the menu bar icon: capture switch, setup steps, the iPhone link, and options.
struct MenuBarPanel: View {
  let controller: ExtensionController
  @Bindable var forwarder: PhoneForwarder
  let updater: SPUUpdater
  let updateNudge: UpdateNudge
  @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      let setup = SetupChecklist(controller: controller, forwarder: forwarder)
      if !setup.isComplete {
        Divider()
        setup
      }
      Divider()
      settings
      Divider()
      HStack {
        if let version = updateNudge.availableVersion {
          Button { updater.checkForUpdates() } label: {
            Label("Nothering \(version) is available", systemImage: "arrow.down.circle.fill")
              .font(.subheadline)
          }
          .buttonStyle(.link)
        } else {
          Text("Made with ♥ in Seoul")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          Text("Nothering \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
          Button("Check for Updates…") { updater.checkForUpdates() }
          Divider()
          Link("GitHub", destination: URL(string: "https://github.com/devxoul/nothering")!)
          Divider()
          Button("Quit Nothering") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
      }
    }
    .padding(14)
    .frame(width: 300)
    .onDisappear { forwarder.dismissPhoneProxyQuit() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Nothering").font(.headline)
          Text(subtitle)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(controller.status.hasPrefix("Error") ? .red : .secondary)
            .lineLimit(3)
        }
        Spacer()
        Toggle("Nothering", isOn: Binding(get: { controller.isRunning }, set: { isOn in
          // On also wakes the iPhone, and off lets it go, so it needn't be touched for either.
          forwarder.captureSwitched(on: isOn)
          Task { await controller.toggle() }
        }))
          .toggleStyle(.switch)
          .labelsHidden()
      }
      if let error = forwarder.error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      if forwarder.phoneProxyQuit {
        Label("Nothering was closed on your iPhone. Open it again to reconnect.", systemImage: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if forwarder.needsOfflineHelper {
        Text("This Mac has no network of its own, so its apps won't try to connect. A small helper fixes that while the iPhone is linked. It asks for your password once.")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        Button("Install Helper…") { forwarder.installOfflineHelper() }
      }
      if !controller.hasTurnedOn {
        Text("macOS will ask twice to add proxies — allow both")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var subtitle: String {
    guard controller.isRunning, forwarder.link != .none else { return controller.status }
    return "\(controller.status) via \(forwarder.link.rawValue) · \(Self.describe(forwarder.stats))"
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Connect iPhone via")
        Spacer()
        Picker("Connect iPhone via", selection: $forwarder.preference) {
          ForEach(PhoneForwarder.Preference.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      if forwarder.preference == .direct || forwarder.pairing != nil {
        directLink
      }
      Toggle("Turn on and off with iPhone proxy", isOn: $forwarder.autoTurnOn)
      Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchesAtLogin))
    }
    .toggleStyle(.checkbox)
  }

  /// Pairing for the direct link: its progress while it runs, and a way to start it otherwise.
  @ViewBuilder private var directLink: some View {
    switch forwarder.pairing {
    case .searching:
      caption("Looking for your iPhone. Open Nothering on it and tap Start Proxy. Wi-Fi has to be on, on both.")
      Button("Cancel") { forwarder.cancelPairing() }
    case let .confirming(digits):
      Text(digits)
        .font(.title2.monospacedDigit().bold())
      caption("Your iPhone asks to allow this Mac. Tap Allow there if it shows this number.")
      Button("Cancel") { forwarder.cancelPairing() }
    case let .answered(digits):
      Text(digits)
        .font(.title2.monospacedDigit().bold())
      // Only the person knows whether it was their iPhone that answered. Another device in range
      // can answer in its place, and would then carry everything this Mac sends.
      caption("An iPhone allowed this Mac. Did yours show this number, and did you tap Allow on it?")
      HStack {
        Button("Yes, Pair") { forwarder.confirmPairing() }
        Button("No") { forwarder.cancelPairing() }
      }
    case let .failed(message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try Again") { forwarder.startPairing() }
    case .paired, nil:
      if forwarder.isPaired {
        HStack {
          caption("Paired with your iPhone. Switching Nothering on wakes it over Bluetooth, so there is nothing to do on it.")
          Spacer()
          Button("Pair Again") { forwarder.startPairing() }
            .buttonStyle(.link)
            .font(.caption)
        }
        if let problem = forwarder.wakeProblem {
          Text(problem)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Button("Pair with iPhone") { forwarder.startPairing() }
        TextField("or type the pairing code shown on it", text: $forwarder.directCode)
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())
          .autocorrectionDisabled()
      }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func setLaunchesAtLogin(_ enabled: Bool) {
    // Re-reading the status afterwards reflects a failed (un)registration in the toggle.
    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    launchesAtLogin = SMAppService.mainApp.status == .enabled
  }

  private static func describe(_ stats: LocalForwarder.Stats) -> String {
    let up = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesUp), countStyle: .file)
    let down = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesDown), countStyle: .file)
    return "↑ \(up) ↓ \(down)"
  }
}
