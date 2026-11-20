import Foundation

/// Keeps the Mac's apps trying when the Mac has no network of its own, e.g. in a car, where the
/// iPhone is the only way out.
///
/// A Mac on no network tells its apps they are offline and has no DNS server to ask. Nothing even
/// tries to connect, so the proxy that would carry it to the iPhone gets nothing to carry. While a
/// link to the iPhone is up, a small helper gives the Mac a network to believe in: a pair of fake
/// Ethernet interfaces with an address, a default route and a DNS server that lead nowhere. The
/// proxy picks connections and lookups up before they would go there.
///
/// That takes root, so the helper is a script installed once, with a sudo rule that lets it run
/// without a password after that. It takes itself down when the process it was brought up for
/// ends, or when a real network comes up.
public enum OfflineNetwork {
  /// Where only root can write, since the sudo rule runs whatever is here as root.
  public static let helperPath = "/Library/PrivilegedHelperTools/nothering-offline-network"
  static let sudoersPath = "/etc/sudoers.d/nothering"
  static let sudoersRule = "%admin ALL=(root) NOPASSWD: \(helperPath)"
  /// The helper's interfaces are named with this, which is how its default route is told apart.
  static let interfacePrefix = "feth"

  public static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: helperPath) && FileManager.default.fileExists(atPath: sudoersPath)
  }

  /// Whether the Mac has a way out of its own: a default route that isn't the helper's.
  public static func macHasNetwork() -> Bool {
    if let interface = defaultRouteInterface(family: "-inet"), !interface.hasPrefix(interfacePrefix) {
      return true
    }
    // Tunnels and the device-to-device Wi-Fi interfaces have IPv6 routes of their own on any Mac.
    if let interface = defaultRouteInterface(family: "-inet6"),
       !["utun", "awdl", "llw", interfacePrefix].contains(where: interface.hasPrefix) {
      return true
    }
    return false
  }

  /// Whether the helper's network is what the Mac is on.
  public static func isUp() -> Bool {
    defaultRouteInterface(family: "-inet")?.hasPrefix(interfacePrefix) == true
  }

  /// Brings the stand-in network up for as long as process `pid` lives. Returns whether it is up.
  ///
  /// With `proxyPort`, the network also carries the system's SOCKS proxy setting, pointed at the
  /// forwarder on that port of this Mac. Apps that follow the setting then reach the iPhone with
  /// nothing else installed. Leave it out where the proxy extension captures connections, so that
  /// its switch stays the one thing that decides.
  @discardableResult
  public static func up(
    following pid: Int32 = ProcessInfo.processInfo.processIdentifier, proxyPort: UInt16? = nil
  ) -> Bool {
    guard isInstalled else { return false }
    if isUp() { return true }
    _ = try? run("/usr/bin/sudo", ["-n", helperPath] + upArguments(following: pid, proxyPort: proxyPort))
    return isUp()
  }

  /// What the helper is asked with: `up <pid>`, and the forwarder's port when apps should use it.
  static func upArguments(following pid: Int32, proxyPort: UInt16?) -> [String] {
    ["up", String(pid)] + (proxyPort.map { [String($0)] } ?? [])
  }

  public static func down() {
    guard isInstalled else { return }
    _ = try? run("/usr/bin/sudo", ["-n", helperPath, "down"])
  }

  /// Writes the helper and its sudo rule to temporary files and returns the shell commands that
  /// put them in place, to be run as root.
  public static func installCommands() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nothering-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptFile = directory.appendingPathComponent("offline-network.sh")
    let rulesFile = directory.appendingPathComponent("sudoers")
    try script.write(to: scriptFile, atomically: true, encoding: .utf8)
    try "\(sudoersRule)\n".write(to: rulesFile, atomically: true, encoding: .utf8)
    return [
      "mkdir -p /Library/PrivilegedHelperTools",
      "install -o root -g wheel -m 755 '\(scriptFile.path)' '\(helperPath)'",
      // A rule that doesn't parse would lock sudo up, so it is checked before it goes in.
      "visudo -cf '\(rulesFile.path)'",
      "install -o root -g wheel -m 440 '\(rulesFile.path)' '\(sudoersPath)'",
    ].joined(separator: " && ")
  }

  /// Takes the network down and removes what `installCommands` put in place. To be run as root.
  public static let removeCommands = "'\(helperPath)' down; rm -f '\(sudoersPath)' '\(helperPath)'"

  /// Installs the helper from an app, with the system's dialog for an administrator's password.
  public static func installWithPasswordDialog() throws {
    let commands = try installCommands()
    try run("/usr/bin/osascript", ["-e", "do shell script \"\(commands)\" with administrator privileges"])
  }

  static func defaultRouteInterface(family: String) -> String? {
    guard let output = try? run("/sbin/route", ["-n", "get", family, "default"]) else { return nil }
    return interface(inRouteOutput: output)
  }

  /// The interface a `route get` answer names, or `nil` when it found no route.
  static func interface(inRouteOutput output: String) -> String? {
    output.split(separator: "\n")
      .first { $0.contains("interface:") }?
      .split(separator: " ").last
      .map(String.init)
  }

  /// The helper. Plain `sh`, with a fixed PATH and no input but its arguments, because it runs as
  /// root for anyone in the admin group.
  public static let script = #"""
    #!/bin/sh
    # Nothering's stand-in network, see OfflineNetwork.swift. Installed by `nothering --install-helper`
    # and run as root through sudo.
    #
    #   up <pid> [<port>]   bring it up, and take it down again when process <pid> ends or a real
    #                       network appears. With <port>, the Mac's apps are also told to use the SOCKS
    #                       proxy on 127.0.0.1:<port>, as long as it is up
    #   down                take it down
    #   status              say whether it is up
    PATH=/sbin:/usr/sbin:/bin:/usr/bin
    export PATH

    NEAR=feth5478
    FAR=feth5479
    SERVICE=NOTHERING-OFFLINE
    # From the range set aside for testing, so no real network is shadowed.
    ADDRESS=198.18.0.2
    ROUTER=198.18.0.1
    OWNER_FILE=/var/run/nothering-offline-network.owner
    WATCHER_FILE=/var/run/nothering-offline-network.watcher

    # Another IPv4 service in the system's network state means the Mac got a real network.
    other_network() {
      echo "list State:/Network/Service/[^/]+/IPv4" | scutil | grep "State:/Network/Service/" | grep -v "/$SERVICE/" >/dev/null
    }

    is_up() {
      ifconfig "$NEAR" >/dev/null 2>&1
    }

    teardown() {
      scutil >/dev/null 2>&1 <<EOF
    remove State:/Network/Service/$SERVICE/IPv4
    remove State:/Network/Service/$SERVICE/DNS
    remove State:/Network/Service/$SERVICE/Proxies
    EOF
      route -n delete default "$ROUTER" >/dev/null 2>&1
      ifconfig "$NEAR" destroy >/dev/null 2>&1
      ifconfig "$FAR" destroy >/dev/null 2>&1
      rm -f "$OWNER_FILE"
    }

    down() {
      if [ -f "$WATCHER_FILE" ]; then
        kill "$(cat "$WATCHER_FILE")" >/dev/null 2>&1
        rm -f "$WATCHER_FILE"
      fi
      teardown
    }

    up() {
      owner=$1
      proxy_port=$2
      case "$owner" in
        '' | *[!0-9]*)
          echo "up needs the ID of the process to follow" >&2
          exit 64
          ;;
      esac
      # A port and nothing else: it ends up in the system's settings, written by root.
      case "$proxy_port" in
        '' | [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9]) ;;
        6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-2][0-9] | 6553[0-5]) ;;
        *)
          echo "the proxy's port is a number from 1 to 65535" >&2
          exit 64
          ;;
      esac
      if ! kill -0 "$owner" 2>/dev/null; then
        echo "no process $owner" >&2
        exit 64
      fi
      if other_network; then
        echo "this Mac has a network of its own"
        exit 0
      fi
      # Already up for this process: nothing to do, and nothing to interrupt.
      if is_up && [ -f "$OWNER_FILE" ] && [ "$(cat "$OWNER_FILE")" = "$owner" ]; then
        exit 0
      fi
      down
      ifconfig "$NEAR" create || exit 1
      if ! ifconfig "$FAR" create; then
        ifconfig "$NEAR" destroy
        exit 1
      fi
      ifconfig "$NEAR" peer "$FAR"
      ifconfig "$FAR" up
      ifconfig "$NEAR" inet "$ADDRESS" netmask 255.255.255.0 up
      # What tells macOS this is a network: a service with an address, a router and a DNS server.
      scutil >/dev/null <<EOF
    d.init
    d.add Addresses * $ADDRESS
    d.add SubnetMasks * 255.255.255.0
    d.add InterfaceName $NEAR
    d.add Router $ROUTER
    set State:/Network/Service/$SERVICE/IPv4
    d.init
    d.add ServerAddresses * $ROUTER
    set State:/Network/Service/$SERVICE/DNS
    EOF
      # Most apps follow the system's proxy setting. On this network it sends them to the forwarder on
      # this Mac, which reaches the iPhone, and it is the forwarder's side that looks names up.
      if [ -n "$proxy_port" ]; then
        scutil >/dev/null <<EOF
    d.init
    d.add SOCKSEnable # 1
    d.add SOCKSProxy 127.0.0.1
    d.add SOCKSPort # $proxy_port
    d.add ExceptionsList * *.local 169.254/16
    set State:/Network/Service/$SERVICE/Proxies
    EOF
      fi
      # macOS adds the default route for a service with a router. In case it didn't.
      route -n add default "$ROUTER" >/dev/null 2>&1
      echo "$owner" > "$OWNER_FILE"
      # Takes it all down again without being asked, so a Mac is never left on a network that
      # leads nowhere after the process it was for is gone.
      (
        trap '' HUP INT
        while kill -0 "$owner" 2>/dev/null && ! other_network; do
          sleep 2
        done
        rm -f "$WATCHER_FILE"
        teardown
      ) </dev/null >/dev/null 2>&1 &
      echo $! > "$WATCHER_FILE"
    }

    case "${1:-}" in
      up) up "${2:-}" "${3:-}" ;;
      down) down ;;
      status) if is_up; then echo up; else echo down; fi ;;
      *)
        echo "usage: $0 up <pid> [<port>] | down | status" >&2
        exit 64
        ;;
    esac
    """#
}
