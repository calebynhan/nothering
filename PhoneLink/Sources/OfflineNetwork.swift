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
  /// The helper's network, as the system's network state names it, and the interface it is on.
  static let serviceID = "NOTHERING-OFFLINE"
  static let interfaceName = "feth5478"

  public static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: helperPath) && FileManager.default.fileExists(atPath: sudoersPath)
  }

  /// Whether the Mac has a way out of its own: a network service other than the helper's is the
  /// one it is on. A service with no router never is, e.g. a tunnel that only takes its own
  /// addresses. The helper asks the same, so the two never disagree about bringing it up.
  public static func macHasNetwork() -> Bool {
    if let primary = primaryService(family: "IPv4"), primary != serviceID {
      return true
    }
    // The helper's network has no IPv6.
    return primaryService(family: "IPv6") != nil
  }

  /// Whether the helper's network is there.
  public static func isUp() -> Bool {
    if_nametoindex(interfaceName) != 0
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

  /// The line a here-document with the helper in it ends on. Not a line of the helper.
  static let scriptEnd = "NOTHERING_HELPER_END"

  /// The shell commands that put the helper and its sudo rule in place, to be run as root.
  ///
  /// Both travel inside the commands. Root must not install what it reads from a place the
  /// person's other programs can write to while the password is being typed, least of all a
  /// script that then runs as root with no password. So nothing is read from a file that isn't
  /// root's own: each is first written where only root can write, and moved into place from there.
  public static let installCommands = """
    set -e
    umask 022
    mkdir -p /Library/PrivilegedHelperTools
    cat > '\(helperPath).new' <<'\(scriptEnd)'
    \(script)
    \(scriptEnd)
    chown root:wheel '\(helperPath).new'
    chmod 755 '\(helperPath).new'
    mv -f '\(helperPath).new' '\(helperPath)'
    printf '%s\\n' '\(sudoersRule)' > '\(helperPath).rule'
    # A rule that doesn't parse would lock sudo up, so it is checked before it goes in.
    visudo -cf '\(helperPath).rule'
    chown root:wheel '\(helperPath).rule'
    chmod 440 '\(helperPath).rule'
    mv -f '\(helperPath).rule' '\(sudoersPath)'
    """

  /// Takes the network down and removes what `installCommands` put in place. To be run as root.
  public static let removeCommands = "'\(helperPath)' down; rm -f '\(sudoersPath)' '\(helperPath)'"

  /// Installs the helper from an app, with the system's dialog for an administrator's password.
  public static func installWithPasswordDialog() throws {
    // Handed over as an argument, so nothing in the commands has to be quoted for AppleScript.
    try run("/usr/bin/osascript", [
      "-e", "on run argv",
      "-e", "do shell script (item 1 of argv) with administrator privileges",
      "-e", "end run",
      installCommands,
    ])
  }

  static func primaryService(family: String) -> String? {
    let question = "echo show State:/Network/Global/\(family) | /usr/sbin/scutil"
    guard let answer = try? run("/bin/sh", ["-c", question]) else { return nil }
    return primaryService(inScutilOutput: answer)
  }

  /// The service a `show State:/Network/Global/IPv4` answer names as the one the Mac is on, or
  /// `nil` when it is on none.
  static func primaryService(inScutilOutput output: String) -> String? {
    for line in output.split(separator: "\n") {
      let words = line.split(separator: " ")
      if words.count == 3, words[0] == "PrimaryService", words[1] == ":" {
        return String(words[2])
      }
    }
    return nil
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

    # The service the Mac is on for IPv4 or IPv6, as the system's network state names it. Empty when
    # it is on none.
    primary_service() {
      echo "show State:/Network/Global/$1" | scutil | awk '$1 == "PrimaryService" { print $3 }'
    }

    # The Mac has a way out of its own: a service other than the stand-in is the one it is on. A
    # service with no router never is, e.g. a tunnel that only takes its own addresses, so a Mac on
    # nothing but those still gets the stand-in. The stand-in has no IPv6, so a service the Mac is on
    # for IPv6 is always another one. OfflineNetwork.macHasNetwork() asks the same.
    other_network() {
      primary=$(primary_service IPv4)
      if [ -n "$primary" ] && [ "$primary" != "$SERVICE" ]; then
        return 0
      fi
      [ -n "$(primary_service IPv6)" ]
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
      # No "route delete default" here: it takes the default route of whatever network the Mac is on
      # by then, whichever router it names. Destroying the interface takes its own routes with it.
      ifconfig "$NEAR" destroy >/dev/null 2>&1
      ifconfig "$FAR" destroy >/dev/null 2>&1
      rm -f "$OWNER_FILE"
    }

    down() {
      if [ -f "$WATCHER_FILE" ]; then
        watcher=$(cat "$WATCHER_FILE")
        rm -f "$WATCHER_FILE"
        # A watcher that was ended any other way leaves its number behind, and by now the number may
        # be any process's. Only this script is ended. Not with a signal it could be ignoring: what
        # started it may ignore the usual one, and a shell can't take that back.
        case "$watcher" in
          '' | *[!0-9]*) ;;
          *)
            case "$(ps -ww -o command= -p "$watcher" 2>/dev/null)" in
              *"${0##*/}"*) kill -KILL "$watcher" >/dev/null 2>&1 ;;
            esac
            ;;
        esac
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
