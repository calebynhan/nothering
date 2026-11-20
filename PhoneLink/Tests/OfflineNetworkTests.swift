import Foundation
import Testing
@testable import PhoneLink

@Suite struct OfflineNetworkTests {
  @Test func readsTheServiceTheMacIsOn() {
    let answer = """
      <dictionary> {
        PrimaryInterface : en0
        PrimaryService : 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9
        Router : 192.168.1.1
      }
      """
    #expect(OfflineNetwork.primaryService(inScutilOutput: answer) == "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
  }

  @Test func aMacOnNoNetworkNamesNoService() {
    #expect(OfflineNetwork.primaryService(inScutilOutput: "  No such key\n") == nil)
    #expect(OfflineNetwork.primaryService(inScutilOutput: "") == nil)
    // A router alone is no service.
    #expect(OfflineNetwork.primaryService(inScutilOutput: "<dictionary> {\n  Router : 192.168.1.1\n}\n") == nil)
  }

  /// The helper's own network is told apart by its name, so it never counts as the Mac's.
  @Test func theHelpersNetworkIsToldByItsName() {
    let answer = "<dictionary> {\n  PrimaryInterface : feth5478\n  PrimaryService : NOTHERING-OFFLINE\n  Router : 198.18.0.1\n}\n"
    #expect(OfflineNetwork.primaryService(inScutilOutput: answer) == OfflineNetwork.serviceID)
    let lines = OfflineNetwork.script.split(separator: "\n").map(String.init)
    #expect(lines.contains("SERVICE=\(OfflineNetwork.serviceID)"))
    #expect(lines.contains("NEAR=\(OfflineNetwork.interfaceName)"))
    #expect(lines.contains("LOCK_FILE=\(OfflineNetwork.lockPath)"))
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
    // Deleting a default route takes the one of whatever network the Mac is on by then.
    #expect(!lines.contains { $0.contains("route") && $0.contains("delete") && !$0.hasPrefix("  #") })
    // Its watcher outlives the signal that comes with the end of what asked for it.
    #expect(lines.contains("    trap '' HUP INT TERM"))
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

  /// Root installs only what the commands themselves carry: nothing is read from a file that the
  /// person's other programs could change while the password is being typed.
  @Test func theInstallCommandsCarryWhatTheyInstall() {
    let commands = OfflineNetwork.installCommands
    #expect(commands.contains(OfflineNetwork.script))
    #expect(commands.contains(OfflineNetwork.sudoersRule))
    #expect(!commands.contains("/tmp"))
    #expect(!commands.contains("/var/folders"))
    // The helper's text ends where its here-document says, and nowhere before.
    #expect(!OfflineNetwork.script.split(separator: "\n").contains { $0 == OfflineNetwork.scriptEnd })
  }

  /// sudo hands root the caller's PATH. What root installs and removes with must be the system's
  /// own tools, not whatever a directory earlier in that PATH has under their names.
  @Test func rootUsesTheSystemsOwnTools() {
    #expect(OfflineNetwork.systemPath.split(separator: ":").allSatisfy { ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains($0) })
    #expect(OfflineNetwork.installCommands.hasPrefix("set -e\nPATH=\(OfflineNetwork.systemPath)\nexport PATH\n"))
    #expect(OfflineNetwork.removeCommands.hasPrefix("PATH=\(OfflineNetwork.systemPath); export PATH; "))
    // The lock goes with the rest.
    #expect(OfflineNetwork.removeCommands.hasSuffix("'\(OfflineNetwork.lockPath)'"))
    // And the stand-in goes before the helper, even if a stuck call keeps "down" from its turn.
    #expect(OfflineNetwork.removeCommands.contains("; \(OfflineNetwork.downEvenIfStuck); rm -f "))
    #expect(OfflineNetwork.downEvenIfStuck.contains(" || NOTHERING_OFFLINE_LOCKED=1 "))
  }

  /// The install commands as root runs them, with the system's places moved under a temporary
  /// directory and stand-ins for the two steps that need root or sudo's own tools.
  @Test func theInstallCommandsPutTheHelperAndItsRuleInPlace() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("nothering-install-\(UUID().uuidString)")
    let tools = root.appendingPathComponent("bin")
    let helpers = root.appendingPathComponent("PrivilegedHelperTools")
    let rules = root.appendingPathComponent("sudoers.d")
    try files.createDirectory(at: tools, withIntermediateDirectories: true)
    try files.createDirectory(at: rules, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    for tool in ["chown", "visudo"] {
      let file = tools.appendingPathComponent(tool)
      try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
      try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    // The commands look nowhere but in the system's places, so the stand-ins are put in there.
    let path = "PATH=\(OfflineNetwork.systemPath)\n"
    let commands = OfflineNetwork.installCommands
      .replacingOccurrences(of: "/Library/PrivilegedHelperTools", with: helpers.path)
      .replacingOccurrences(of: "/etc/sudoers.d", with: rules.path)
      .replacingOccurrences(of: path, with: "PATH=\(tools.path):\(OfflineNetwork.systemPath)\n")

    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", commands]
    try shell.run()
    shell.waitUntilExit()
    #expect(shell.terminationStatus == 0)

    // The helper doesn't name the places that were moved. Its rule names the helper.
    let helper = helpers.appendingPathComponent("nothering-offline-network")
    #expect(try String(contentsOf: helper, encoding: .utf8) == OfflineNetwork.script + "\n")
    #expect(files.isExecutableFile(atPath: helper.path))
    let rule = rules.appendingPathComponent("nothering")
    #expect(try String(contentsOf: rule, encoding: .utf8) == "%admin ALL=(root) NOPASSWD: \(helper.path)\n")
    let mode = try files.attributesOfItem(atPath: rule.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o440)
    // Nothing is left where it was put together.
    #expect(try files.contentsOfDirectory(atPath: helpers.path) == ["nothering-offline-network"])
  }
}
