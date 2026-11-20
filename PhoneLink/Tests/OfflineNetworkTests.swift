import Foundation
import Testing
@testable import PhoneLink

@Suite struct OfflineNetworkTests {
  @Test func readsTheInterfaceOfARoute() {
    let answer = """
         route to: default
      destination: default
             mask: default
          gateway: 192.168.1.1
        interface: en0
            flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
       recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
             0         0         0         0         0         0      1500         0
      """
    #expect(OfflineNetwork.interface(inRouteOutput: answer) == "en0")
  }

  @Test func aRouteThatWasNotFoundNamesNoInterface() {
    #expect(OfflineNetwork.interface(inRouteOutput: "route: writing to routing socket: not in table\n") == nil)
    #expect(OfflineNetwork.interface(inRouteOutput: "") == nil)
  }

  /// The helper's own route is told apart by its interface, so it never counts as the Mac's network.
  @Test func theHelpersRouteIsToldByItsInterface() {
    let answer = "   route to: default\n    gateway: 198.18.0.1\n  interface: feth5478\n"
    let interface = OfflineNetwork.interface(inRouteOutput: answer)
    #expect(interface?.hasPrefix(OfflineNetwork.interfacePrefix) == true)
    #expect(OfflineNetwork.script.contains("NEAR=\(interface ?? "")"))
  }

  /// The script is a string in the source. A here-document only ends on a line that is exactly its
  /// marker, so the source's indentation must not survive into it.
  @Test func theHelperScriptIsWellFormed() {
    let lines = OfflineNetwork.script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first == "#!/bin/sh")
    #expect(lines.filter { $0.hasSuffix("<<EOF") }.count == 3)
    #expect(lines.filter { $0 == "EOF" }.count == 3)
    // Runs as root for anyone in the admin group: only its own fixed PATH, and no shell beyond sh.
    #expect(lines.contains("PATH=/sbin:/usr/sbin:/bin:/usr/bin"))
    #expect(!OfflineNetwork.script.contains("eval"))
  }

  /// The forwarder's port is passed only when apps should be pointed at it.
  @Test func theHelperIsAskedWithThePortOnlyWhenGiven() {
    #expect(OfflineNetwork.upArguments(following: 4321, proxyPort: nil) == ["up", "4321"])
    #expect(OfflineNetwork.upArguments(following: 4321, proxyPort: 11080) == ["up", "4321", "11080"])
  }

  /// sudo runs exactly the installed helper without a password, and nothing else.
  @Test func theSudoRuleNamesOnlyTheHelper() {
    #expect(OfflineNetwork.sudoersRule == "%admin ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/nothering-offline-network")
    #expect(OfflineNetwork.helperPath.hasPrefix("/Library/PrivilegedHelperTools/"))
  }
}
