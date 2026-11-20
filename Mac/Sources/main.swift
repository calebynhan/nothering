import Darwin
import Foundation
import PhoneLink
import ProxyCore

let usage = """
  usage: nothering [--via auto|usb|hotspot|direct] [--wake] [--pair] [--code <pairing code>]
                   [--port 11080] [--host <phone address>] [--system-proxy]
         nothering --install-helper | --remove-helper

  Forwards 127.0.0.1:<port> to the Nothering proxy on the iPhone.
    --via           link to the iPhone (auto tries USB first, then hotspot; direct is
                    device-to-device Wi-Fi, with no cable and no hotspot)
    --wake          for the direct link: ask the iPhone over Bluetooth to start its proxy, so it
                    needn't be opened. Works while Nothering wasn't swiped away on it
    --pair          pair with the iPhone again for the direct link. The first time it pairs by
                    itself: the iPhone asks whether to allow this Mac
    --code          pairing code shown in Nothering on the iPhone, instead of pairing
    --host          phone address for the hotspot link (default: the Mac's IPv6 default gateway)
    --system-proxy  point macOS's SOCKS proxy at the forwarder while running
    --install-helper  once, for a Mac with no network of its own (a car, a train): installs the
                    helper that keeps its apps trying while the iPhone is linked. Asks for an
                    administrator's password. --remove-helper takes it out again
  If nothering is killed without cleanup, reset with:
    networksetup -setsocksfirewallproxystate <service> off   (for each service)
  """

setvbuf(stdout, nil, _IOLBF, 0)

var via = "auto"
var port: UInt16 = 11080
var host: String?
var code: String?
var pairAgain = false
var wakesPhone = false
var helperAction: String?
/// Asks the iPhone for its proxy again when the direct link is down, and does nothing while it is
/// up. Set when --wake is given.
var wakePhoneIfDown: (() -> Void)?
/// Drops a request to the iPhone that is under way. Set when --wake is given.
var cancelWake: (() -> Void)?
var useSystemProxy = false

/// The tool is on its way out: the iPhone said its proxy was stopped there or its app closed, or
/// the person stopped the tool. Nothing asks the iPhone again after that. Putting the Mac back
/// takes a moment, and the keepalive runs on a queue of its own meanwhile.
final class Ending: @unchecked Sendable {
  private let lock = NSLock()
  private var isSet = false

  func set() {
    lock.withLock { isSet = true }
  }

  var value: Bool {
    lock.withLock { isSet }
  }
}
let ending = Ending()

/// What to do when the direct link is there again: listen to the iPhone at once. Waiting for the
/// keepalive would leave up to ten seconds in which a Stop tapped on the iPhone goes unheard, and
/// the next keepalive would then wake the iPhone right back. Set once the tool listens.
final class LinkIsBack: @unchecked Sendable {
  private let lock = NSLock()
  private var work: (@Sendable () -> Void)?

  func set(_ work: @escaping @Sendable () -> Void) {
    lock.withLock { self.work = work }
  }

  func run() {
    lock.withLock { work }?()
  }
}
let linkIsBack = LinkIsBack()

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
  switch argument {
  case "--via": via = arguments.next() ?? via
  case "--port": port = arguments.next().flatMap(UInt16.init) ?? port
  case "--host": host = arguments.next()
  case "--code": code = arguments.next()
  case "--pair": pairAgain = true
  case "--wake": wakesPhone = true
  case "--install-helper", "--remove-helper": helperAction = argument
  case "--system-proxy": useSystemProxy = true
  default:
    print(usage)
    exit(argument == "--help" || argument == "-h" ? 0 : 64)
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("nothering: \(message)\n".utf8))
  exit(1)
}

/// Runs a command on this terminal and waits for it, so sudo can ask for the password here. Not
/// with `Process`, which starts the command in a group of its own: the terminal only lets the
/// group in front of it read a password, and sudo would wait for a turn that never comes.
func runOnTerminal(_ executable: String, _ arguments: [String]) -> Bool {
  let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
  let environment: [UnsafeMutablePointer<CChar>?] =
    ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { (argv + environment).forEach { free($0) } }
  var pid = pid_t()
  guard posix_spawn(&pid, executable, nil, nil, argv, environment) == 0 else { return false }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) == -1 {
    guard errno == EINTR else { return false }
  }
  return status == 0
}

if helperAction == "--install-helper" {
  print("nothering: installing the helper for a Mac with no network of its own. sudo asks for your password")
  guard runOnTerminal("/usr/bin/sudo", ["/bin/sh", "-c", OfflineNetwork.installCommands]), OfflineNetwork.isInstalled else {
    fail("the helper wasn't installed")
  }
  print("nothering: installed at \(OfflineNetwork.helperPath)")
  exit(0)
} else if helperAction == "--remove-helper" {
  guard runOnTerminal("/usr/bin/sudo", ["/bin/sh", "-c", OfflineNetwork.removeCommands]) else {
    fail("the helper wasn't removed")
  }
  print("nothering: helper removed")
  exit(0)
}

/// Told once that the helper is missing, not on every check.
var didExplainHelper = false
var didAnnounceStandIn = false

/// A Mac with no network of its own tells its apps they are offline, and they don't try. While the
/// iPhone is linked, the helper gives it a network to believe in, see `OfflineNetwork`.
func keepMacOnline(isLinked: Bool) {
  guard isLinked else {
    if OfflineNetwork.isUp() { OfflineNetwork.down() }
    return
  }
  guard !OfflineNetwork.macHasNetwork() else { return }
  guard OfflineNetwork.isInstalled else {
    if !didExplainHelper {
      didExplainHelper = true
      print("nothering: this Mac has no network of its own, so its apps won't try to connect. Run `nothering --install-helper` once, then start again")
    }
    return
  }
  // With --system-proxy the stand-in carries that setting too: the Mac's own network services,
  // where SystemProxy puts it, aren't in use while the Mac is on none of them.
  if OfflineNetwork.up(proxyPort: useSystemProxy ? port : nil) {
    if !didAnnounceStandIn {
      didAnnounceStandIn = true
      print("nothering: this Mac has no network of its own, so it is given a stand-in while the iPhone is linked")
    }
  } else if !didExplainHelper {
    didExplainHelper = true
    // The same request the tool makes, port and all: run by hand, it must not leave a stand-in
    // other than the one the tool asks for.
    let asked = OfflineNetwork.upArguments(following: getpid(), proxyPort: useSystemProxy ? port : nil)
    print("nothering: this Mac has no network of its own, and the helper didn't give it a stand-in, so its apps won't try to connect. This says why: sudo -n \(OfflineNetwork.helperPath) \(asked.joined(separator: " "))")
  }
}

let remotePort: UInt16 = 11080
let connectUpstream: () throws -> Int32

/// Asks the iPhone for its pairing code and waits for its person to allow it there and confirm it
/// here.
func pair() -> String {
  final class Answer: @unchecked Sendable {
    var digits = ""
    var code = ""
  }
  let answer = Answer()
  let answered = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  let pairer = DirectLinkPairer(name: computerName()) { state in
    switch state {
    case .searching:
      print("nothering: looking for the iPhone to pair with. Open Nothering on it and keep it open")
    case let .confirming(digits):
      print("nothering: the iPhone asks to allow this Mac. Tap Allow there if it shows \(digits)")
    case let .answered(digits):
      answer.digits = digits
      answered.signal()
    case let .paired(code):
      answer.code = code
      done.signal()
    case let .failed(message):
      fail(message)
    }
  }
  pairer.start()
  answered.wait()
  // Only the person knows whether it was their iPhone that answered. Another device in range can
  // answer in its place with a code of its own, and would then carry everything this Mac sends.
  // What was typed before the question was asked is no answer to it.
  tcflush(STDIN_FILENO, TCIFLUSH)
  print("nothering: an iPhone allowed this Mac. Did yours show \(answer.digits), and did you tap Allow on it? [y/N] ", terminator: "")
  fflush(stdout)
  let reply = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
  guard reply == "y" || reply == "yes" else {
    pairer.cancel()
    fail("not paired. If your iPhone showed nothing, something else answered in its place. Try again with Nothering open on your iPhone")
  }
  pairer.confirm()
  done.wait()
  return answer.code
}

let savedCodeKey = "directLinkCode"

if via == "direct" {
  if let code, !DirectLinkCode.isValid(code) {
    fail("--code is not a pairing code as Nothering shows it on the iPhone, like K7QM-2XBD-9RTH-W4PN-6CEA")
  }
  var pairingCode = code ?? (pairAgain ? nil : UserDefaults.standard.string(forKey: savedCodeKey))
  if pairingCode.map(DirectLinkCode.isValid) != true {
    // Nothing to type: the iPhone shows the same number as this Mac and its person taps Allow.
    pairingCode = pair()
    print("nothering: paired")
  }
  let linkCode = DirectLinkCode.normalized(pairingCode ?? "")
  // Kept for the next run. A code from pairing, or the one kept before, right away. One that was
  // typed only once it has connected: a slip of the finger shouldn't replace the code that works.
  let wasTyped = code != nil
  if !wasTyped {
    UserDefaults.standard.set(DirectLinkCode.format(linkCode), forKey: savedCodeKey)
  }
  let client = DirectLinkClient(code: linkCode, onStatusChange: { status in
    if status == .connected { linkIsBack.run() }
  })
  client.start()
  if wakesPhone {
    let waker = DirectLinkWaker(code: linkCode)
    // Not more often than an attempt takes, however often the link is found down.
    let shortestWait: TimeInterval = 20
    /// Touched from the keepalive's queue and the waker's. Under the lock.
    final class Asking: @unchecked Sendable {
      let lock = NSLock()
      var wait: TimeInterval = 0
      var lastWake = Date.distantPast
      var lastSaid = ""
    }
    let asking = Asking()
    asking.wait = shortestWait
    let say: @Sendable (String) -> Void = { message in
      // Once, not every time the same thing happens again.
      let isNew = asking.lock.withLock {
        defer { asking.lastSaid = message }
        return asking.lastSaid != message
      }
      if isNew { print("nothering: \(message)") }
    }
    let wake = {
      guard !ending.value else { return }
      let isConnected = client.currentStatus == .connected
      let isDue = asking.lock.withLock {
        if isConnected {
          // The link is there. The next time it is lost, the iPhone is asked at once again.
          asking.wait = shortestWait
          asking.lastSaid = ""
          return false
        }
        guard Date().timeIntervalSince(asking.lastWake) >= asking.wait else { return false }
        asking.lastWake = Date()
        return true
      }
      guard isDue else { return }
      waker.wake { outcome in
        switch outcome {
        case .woke:
          // Heard, and still no link: asking as often won't change that, and each time starts the
          // iPhone's proxy and its notification over. So every time it waits twice as long.
          asking.lock.withLock { asking.wait = min(asking.wait * 2, 600) }
          say("the iPhone is starting its proxy")
        case .refused: say("an iPhone with Nothering is in range, but it has another pairing code. If it is yours, run with --pair")
        case .notFound: say("iPhone not found over Bluetooth. Is Nothering still open in its app switcher?")
        case let .unavailable(reason): say(reason)
        }
      }
    }
    print("nothering: waking the iPhone over Bluetooth")
    wake()
    wakePhoneIfDown = wake
    cancelWake = { waker.cancel() }
  }
  print("nothering: looking for the iPhone over Wi-Fi")
  // A woken iPhone needs to be found over Bluetooth and to start its proxy first.
  let deadline = Date().addingTimeInterval(wakesPhone ? 60 : 30)
  var status = client.currentStatus
  while status != .connected {
    if case let .blocked(reason) = status {
      fail(reason)
    }
    if Date() > deadline {
      fail(client.foundAnotherPhone
        ? "an iPhone with Nothering is in range, but it has another pairing code. If it is yours, run with --pair"
        : "iPhone not found over Wi-Fi. Open Nothering on it and tap Start Proxy. Wi-Fi has to be on, on both")
    }
    // One attempt can pass unheard: an iPhone whose app is in the background answers less often,
    // and the first time macOS asks whether Bluetooth may be used. Not more often than it is due.
    wakePhoneIfDown?()
    usleep(200_000)
    status = client.currentStatus
  }
  if wasTyped {
    UserDefaults.standard.set(DirectLinkCode.format(linkCode), forKey: savedCodeKey)
  }
  // The client keeps the link, and finds the phone again by itself after it was out of range.
  connectUpstream = { try client.connect() }
} else if via == "usb" || (via == "auto" && host == nil), let deviceID = try? USBMux.firstUSBDeviceID() {
  via = "usb"
  connectUpstream = { try USBMux.connect(deviceID: deviceID, port: remotePort) }
} else if via == "usb" {
  fail("no iPhone connected over USB")
} else {
  via = "hotspot"
  let phone: String
  do {
    phone = try host ?? Hotspot.gatewayAddress()
  } catch {
    fail(error.localizedDescription)
  }
  connectUpstream = { try TCP.connect(host: phone, port: remotePort) }
}

do {
  Darwin.close(try connectUpstream())
} catch {
  fail("cannot reach Nothering on the iPhone via \(via): \(error.localizedDescription)")
}

// A browser alone opens more connections than a process may hold by default.
raiseOpenFileLimit()

let forwarder = LocalForwarder(port: port, connectUpstream: connectUpstream)
do {
  port = try forwarder.start()
} catch {
  fail("cannot listen on 127.0.0.1:\(port): \(error.localizedDescription). If the Nothering app is running, quit it from its menu: it uses the same port")
}
print("nothering: 127.0.0.1:\(port) -> iPhone via \(via)")
keepMacOnline(isLinked: true)

var systemProxy: SystemProxy?
if useSystemProxy {
  do {
    let proxy = try SystemProxy()
    try proxy.enable(port: port)
    systemProxy = proxy
    print("nothering: system SOCKS proxy enabled on \(proxy.services.joined(separator: ", "))")
  } catch {
    fail("cannot set system proxy: \(error.localizedDescription)")
  }
}

/// Puts the Mac back as it was and ends. On the main queue.
func stop(_ message: String) -> Never {
  ending.set()
  cancelWake?()
  systemProxy?.restore()
  forwarder.stop()
  keepMacOnline(isLinked: false)
  print("\nnothering: \(message)\(systemProxy == nil ? "" : ", system proxy restored")")
  exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
  signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler { stop("stopped") }
  source.resume()
  signalSources.append(source)
}

// The iPhone says when its person stops the proxy there, or closes the app. Going on would undo
// that: the keepalive below would ask the iPhone to start again, and get its way. So the end is
// marked here, where the word arrives, and not only once the main queue gets to it.
let phoneEvents = PhoneEventListener()
func listenToPhone() {
  phoneEvents.listen(connect: { try connectUpstream() }) { update in
    switch update {
    case .event(.stopped):
      ending.set()
      DispatchQueue.main.async { stop("the proxy was stopped on the iPhone") }
    case .event(.terminating):
      ending.set()
      DispatchQueue.main.async { stop("Nothering was closed on the iPhone. Open it there to connect again") }
    case .opened, .closed:
      break
    }
  }
}
listenToPhone()
linkIsBack.set { listenToPhone() }

// iOS drops idle hotspot clients while the phone is locked, and the phone's app stops its proxy
// once no client has connected for a while; periodic connects keep both alive.
let keepalive = DispatchSource.makeTimerSource(queue: .global())
keepalive.schedule(deadline: .now() + 10, repeating: 10)
keepalive.setEventHandler {
  guard !ending.value else { return }
  do {
    Darwin.close(try connectUpstream())
    keepMacOnline(isLinked: true)
    // Again after the link was away. Does nothing while it is listening.
    listenToPhone()
  } catch {
    FileHandle.standardError.write(Data("nothering: keepalive failed: \(error.localizedDescription)\n".utf8))
    // A link that went without a word leaves the event stream's read waiting for ever, and no new
    // stream is opened while that one counts as open. Ending it lets the next one be heard.
    phoneEvents.stop()
    // Without the iPhone the stand-in network leads nowhere, and the Mac shouldn't think otherwise.
    keepMacOnline(isLinked: false)
  }
  wakePhoneIfDown?()
}
keepalive.resume()

dispatchMain()
