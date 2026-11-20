import Darwin
import Foundation
import Network
import Testing
@testable import ProxyCore

/// The direct link with the real networking stack, as far as one Mac can take it: the phone's side
/// and the Mac's side in one process, over loopback. It shows that the TLS keyed by the pairing
/// code really connects, that another code is turned away, and that the proxy serves what arrives
/// that way. What it can't show is the radio link between two devices.
///
/// Most tests connect by port and leave the phone's Bonjour service unannounced: announcing takes
/// the system's leave to use the local network, and a build machine has nobody to give it. The
/// three that go through the search announce it, and say so when the machine wouldn't let them.
///
/// One at a time: those three would find each other's service.
@Suite(.serialized) struct DirectLinkLoopbackTests {
  private static let code = "K7QM-2XBD-9RTH-W4PN-6CEA"

  @Test func aMacWithTheCodeIsServed() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let server = try await startPhone()
    defer { server.stop() }
    let port = try await linkPort(of: server)

    let mac = try await MacSide.connect(port: port, parameters: DirectLink.parameters(code: Self.code))
    defer { mac.close() }
    let stream = try await mac.openStream()
    try await socksConnect(mac, stream, to: echoPort)

    let message = Data("through the direct link".utf8)
    try await mac.send(message, on: stream)
    #expect(try await mac.receive(message.count, from: stream) == message)

    let stats = server.currentStats()
    #expect(stats.totalDirectConnections == 1)
    #expect(stats.activeDirectConnections == 1)
    #expect(stats.bytesUp == UInt64(message.count))
    #expect(stats.bytesDown == UInt64(message.count))
  }

  /// The two sides offer two ways to encrypt, and settle on the first both have. This says which
  /// ones this system really has, by offering one at a time from the Mac's side.
  @Test func eachWayOfEncryptingThatConnectsIsNamed() async throws {
    let server = try await startPhone()
    defer { server.stop() }
    let port = try await linkPort(of: server)
    var connected: [DirectLink.CipherSuite] = []
    for suite in DirectLink.CipherSuite.allCases {
      if let mac = try? await MacSide.connect(port: port, parameters: DirectLink.parameters(code: Self.code, suites: [suite])) {
        connected.append(suite)
        mac.close()
      }
    }
    print("NOTE DirectLinkLoopbackTests: the link connects with \(connected), of \(DirectLink.CipherSuite.allCases)")
    // The one Apple's sample uses has to be there. The forward-secret one is a gain where it is.
    #expect(connected.contains(.plain))
  }

  /// A page load: many connections at once, each a stream on the one connection.
  @Test func manyStreamsShareOneConnection() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let server = try await startPhone()
    defer { server.stop() }
    let port = try await linkPort(of: server)
    let mac = try await MacSide.connect(port: port, parameters: DirectLink.parameters(code: Self.code))
    defer { mac.close() }

    try await withThrowingTaskGroup(of: Bool.self) { group in
      for index in 0..<24 {
        group.addTask {
          let stream = try await mac.openStream()
          try await socksConnect(mac, stream, to: echoPort)
          // Past one window for some, so credit has to come back over the real connection.
          let sent = payload(40_000 + index * 30_000, seed: UInt64(index))
          async let received = mac.receive(sent.count, from: stream)
          try await mac.send(sent, on: stream)
          return try await received == sent
        }
      }
      for try await intact in group {
        #expect(intact)
      }
    }
    #expect(server.currentStats().totalDirectConnections == 24)
  }

  /// The Mac's side never tries a phone with another code: it tells by the service's name. Should
  /// one be tried anyway, the handshake is what keeps it out.
  @Test func aMacWithAnotherCodeIsTurnedAway() async throws {
    let server = try await startPhone()
    defer { server.stop() }
    let port = try await linkPort(of: server)
    do {
      let mac = try await MacSide.connect(port: port, parameters: DirectLink.parameters(code: "AAAA-AAAA-AAAA-AAAA-AAAA"))
      mac.close()
      Issue.record("a Mac with another pairing code got a connection")
    } catch let error as NWError {
      if case .tls = error {} else {
        print("NOTE DirectLinkLoopbackTests: a wrong code was turned away with \(error), not a TLS error")
      }
    }
    #expect(server.currentStats().totalDirectConnections == 0)
  }

  /// The phone tells the Mac that it was stopped by hand and closes in the same breath. The Mac
  /// has to hear it, or it would wake the phone right back.
  @Test func thePhonesLastWordArrives() async throws {
    let server = try await startPhone()
    let port = try await linkPort(of: server)
    let mac = try await MacSide.connect(port: port, parameters: DirectLink.parameters(code: Self.code))
    defer { mac.close() }
    let stream = try await mac.openStream()
    try await mac.send(Data([0x05, 0x01, 0x00]), on: stream)
    #expect(try await mac.receive(2, from: stream) == Data([0x05, 0x00]))
    // The event stream: Nothering's own command, with an address nobody reads.
    try await mac.send(Data([0x05, ProxyEvent.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), on: stream)
    let reply = try await mac.receive(10, from: stream)
    #expect(reply.count == 10 && reply[1] == 0x00)

    // The Mac's side is waiting for the next event, as its relay always is.
    async let event = mac.receive(1, from: stream)
    try await Task.sleep(nanoseconds: 300_000_000)
    server.send(.stopped)
    server.stop()
    #expect(try await event == Data([ProxyEvent.stopped.rawValue]))
  }

  /// A phone that never finishes the handshake doesn't keep the Mac waiting for it for ever: the
  /// names differ, so the Mac's side doesn't even start, and it says that another phone is there.
  @Test func theMacLeavesAPhoneWithAnotherCodeAlone() async throws {
    let server = try await startPhone(announces: true)
    defer { server.stop() }
    guard await isListening(server) else { return }

    let client = DirectLinkClient(code: "AAAA-AAAA-AAAA-AAAA-AAAA")
    client.start()
    defer { client.stop() }
    let noticed = await until(20) { client.foundAnotherPhone }
    guard noticed else {
      print("NOTE DirectLinkLoopbackTests: the Mac's side didn't find the phone's service (\(client.currentStatus)). The search wasn't tested here.")
      return
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(client.currentStatus == .searching)
    #expect(server.currentStats().totalDirectConnections == 0)
  }

  /// Without the key there is nothing to talk to: no TLS, no proxy.
  @Test func aPlainConnectionGetsNothing() async throws {
    let server = try await startPhone()
    defer { server.stop() }
    let port = try await linkPort(of: server)
    let plain = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    try await plain.startAndWaitReady()
    defer { plain.cancel() }
    // A SOCKS greeting and then some: enough bytes for the phone's side to see that this is no
    // handshake, instead of waiting for the rest of one.
    try? await plain.sendAsync(Data([0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x00, 0x00]))
    let reply = try? await plain.receiveExactly(2)
    // The phone's TLS may answer a stranger with an alert record (0x15 0x03 ...) before it hangs
    // up. What it must never send is a proxy's answer, which starts with the SOCKS version.
    #expect(reply?.first != 0x05)
    #expect(server.currentStats().totalDirectConnections == 0)
  }

  /// Pairing over a real connection: the Mac learns the phone's code once the person allows it.
  @Test func pairingGivesTheMacThePhonesCode() async throws {
    let requests = Locked<[DirectLinkPairingRequest]>([])
    let server = try await startPhone { request in
      if let request { requests.update { $0.append(request) } }
    }
    defer { server.stop() }
    let port = try await pairingPort(of: server)

    let mac = try await MacSide.connect(port: port, parameters: DirectLink.pairingParameters, muxed: false)
    defer { mac.close() }
    let digits = Locked<String?>(nil)
    let result = Locked<Result<String, DirectLinkPairingError>?>(nil)
    let requester = PairingRequester(
      transport: mac.connection, queue: mac.queue, name: "Test Mac",
      onDigits: { shown in digits.update { $0 = shown } },
      completion: { outcome in result.update { $0 = outcome } }
    )
    mac.queue.async { requester.start() }

    #expect(await until { !requests.value.isEmpty })
    let request = try #require(requests.value.first)
    #expect(request.name == "Test Mac")
    #expect(await until { digits.value != nil })
    #expect(request.digits == digits.value)

    request.answer(true)
    #expect(await until { result.value != nil })
    #expect(result.value == .success(Self.code))
  }

  /// The whole of the Mac's side: finds the phone's service, connects with the code, and hands
  /// out a socket that reaches the proxy. Finding a service needs the system's leave to use the
  /// local network, which a build machine may not give. Then this says so and tests nothing: the
  /// tests above cover everything but the finding.
  @Test func theMacFindsThePhoneAndHandsOutASocket() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let server = try await startPhone(announces: true)
    defer { server.stop() }
    guard await isListening(server) else { return }

    let client = DirectLinkClient(code: Self.code)
    client.start()
    defer { client.stop() }
    let found = await until(20) {
      let status = client.currentStatus
      if case .blocked = status { return true }
      return status == .connected
    }
    guard found, client.currentStatus == .connected else {
      print("NOTE DirectLinkLoopbackTests: the Mac's side didn't find the phone's (\(client.currentStatus)). The search wasn't tested here.")
      return
    }

    let socket = try client.connect()
    defer { Darwin.close(socket) }
    // So a broken link fails the test instead of hanging it.
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let message = Data("through a socket".utf8)
    let reply = await onThread { () -> Data? in
      guard writeAll(socket, Data([0x05, 0x01, 0x00])), readExactly(socket, 2) == Data([0x05, 0x00]),
            writeAll(socket, Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]) + portBytes(echoPort)),
            readExactly(socket, 10)?[1] == 0x00,
            writeAll(socket, message)
      else { return nil }
      return readExactly(socket, message.count)
    }
    #expect(reply == message)
    #expect(server.currentStats().totalDirectConnections >= 1)
  }

  /// The whole of pairing from the Mac's side, with the same caveat about finding the service.
  @Test func theMacFindsThePhoneToPairWith() async throws {
    let requests = Locked<[DirectLinkPairingRequest]>([])
    let server = try await startPhone(announces: true) { request in
      if let request { requests.update { $0.append(request) } }
    }
    defer { server.stop() }
    guard await isListening(server, forPairing: true) else { return }

    let states = Locked<[DirectLinkPairer.State]>([])
    let pairer = DirectLinkPairer(name: "Test Mac") { state in states.update { $0.append(state) } }
    pairer.start()
    defer { pairer.cancel() }
    let asked = await until(20) {
      !requests.value.isEmpty || states.value.contains { if case .failed = $0 { true } else { false } }
    }
    guard asked, let request = requests.value.first else {
      print("NOTE DirectLinkLoopbackTests: the Mac's side didn't find a phone to pair with (\(states.value)). The search wasn't tested here.")
      return
    }
    #expect(await until { states.value.contains { if case .confirming = $0 { true } else { false } } })
    #expect(states.value.contains(.confirming(digits: request.digits)))
    request.answer(true)
    // The phone said yes. That alone pairs nothing: the person has to say it was their phone.
    #expect(await until { states.value.contains(.answered(digits: request.digits)) })
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(!states.value.contains(.paired(code: Self.code)))
    pairer.confirm()
    #expect(await until { states.value.contains(.paired(code: Self.code)) })
  }

  // MARK: The phone's side

  private func startPhone(
    announces: Bool = false, onPairingRequest: (@Sendable (DirectLinkPairingRequest?) -> Void)? = nil
  ) async throws -> ProxyServer {
    let server = ProxyServer(configuration: .init(
      port: .any, requiredInterfaceType: nil, directLinkCode: Self.code, onPairingRequest: onPairingRequest,
      announcesDirectLink: announces
    ))
    _ = try await server.start()
    // As with the app in front of its person.
    server.setAcceptsPairing(onPairingRequest != nil)
    return server
  }

  /// The listeners take a moment to get their ports.
  private func linkPort(of server: ProxyServer) async throws -> UInt16 {
    #expect(await until { server.directLinkPorts().link != nil }, "the direct link isn't listening: \(server.directLinkProblem() ?? "no reason given")")
    return try #require(server.directLinkPorts().link)
  }

  private func pairingPort(of server: ProxyServer) async throws -> UInt16 {
    #expect(await until { server.directLinkPorts().pairing != nil }, "pairing isn't listening")
    return try #require(server.directLinkPorts().pairing)
  }

  /// For the tests that go through the search. With its service announced, the phone's side may
  /// not come up at all where the local network may not be used. That is said, and not a failure.
  private func isListening(_ server: ProxyServer, forPairing: Bool = false) async -> Bool {
    let isUp = await until {
      let ports = server.directLinkPorts()
      return (forPairing ? ports.pairing : ports.link) != nil
    }
    if !isUp {
      print("NOTE DirectLinkLoopbackTests: the phone's side didn't come up with its service announced (\(server.directLinkProblem() ?? "no reason given")). The search wasn't tested here.")
    }
    return isUp
  }
}

// MARK: - The Mac's side, by hand

/// A connection to the phone's listener, with the mux on it unless told otherwise. Everything of
/// the connection and the mux runs on `queue`.
private final class MacSide: @unchecked Sendable {
  let queue = DispatchQueue(label: "DirectLinkLoopbackTests.mac")
  let connection: NWConnection
  private var mux: Mux?

  private init(connection: NWConnection) {
    self.connection = connection
  }

  static func connect(port: UInt16, parameters: NWParameters, muxed: Bool = true) async throws -> MacSide {
    let side = MacSide(connection: NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: parameters))
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        side.queue.async {
          let waiting = Waiting(continuation, on: side.queue, for: "connecting to the phone's side")
          side.connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
              side.connection.stateUpdateHandler = nil
              if muxed {
                let mux = Mux(transport: side.connection, role: .client)
                side.mux = mux
                mux.start()
              }
              waiting.finish(.success(()))
            case let .failed(error), let .waiting(error):
              side.connection.stateUpdateHandler = nil
              waiting.finish(.failure(error))
            default:
              break
            }
          }
          side.connection.start(queue: side.queue)
        }
      }
    } catch {
      side.close()
      throw error
    }
    return side
  }

  func close() {
    queue.async { [self] in
      if let mux {
        mux.close()
      } else {
        connection.cancel()
      }
    }
  }

  func openStream() async throws -> MuxStream {
    let stream = await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: mux?.openStream()) }
    }
    return try #require(stream, "the connection is gone")
  }

  func send(_ data: Data, on stream: MuxStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [queue] in
        let waiting = Waiting(continuation, on: queue, for: "sending \(data.count) bytes")
        // In pieces a stream takes at once, each after the one before, like a relay does.
        var offset = 0
        func next() {
          guard offset < data.count else { return waiting.finish(.success(())) }
          let piece = data.subdata(in: offset..<min(offset + 64 * 1024, data.count))
          offset += piece.count
          stream.write(piece) { error in
            if let error { return waiting.finish(.failure(error)) }
            next()
          }
        }
        next()
      }
    }
  }

  func receive(_ count: Int, from stream: MuxStream) async throws -> Data {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
      queue.async { [queue] in
        let waiting = Waiting(continuation, on: queue, for: "receiving \(count) bytes")
        var received = Data()
        func next() {
          stream.read(minimum: 1, maximum: min(64 * 1024, count - received.count)) { data, isComplete, error in
            if let data { received.append(data) }
            if let error { return waiting.finish(.failure(error)) }
            if received.count == count || isComplete || data == nil {
              return waiting.finish(.success(received))
            }
            next()
          }
        }
        next()
      }
    }
  }
}

/// Resumes a continuation once: with what happened, or with an error when nothing did in time. A
/// wait with no end would hold up the whole run instead of failing one test. Used on one queue.
private final class Waiting<Value>: @unchecked Sendable {
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>, on queue: DispatchQueue, for what: String, within seconds: Int = 30) {
    self.continuation = continuation
    queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
      finish(.failure(TimedOut(what: what, seconds: seconds)))
    }
  }

  func finish(_ result: Result<Value, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

private struct TimedOut: Error, CustomStringConvertible {
  let what: String
  let seconds: Int

  var description: String {
    "\(what): nothing happened in \(seconds) s"
  }
}

/// The SOCKS5 greeting and a CONNECT to this machine, over a stream.
private func socksConnect(_ mac: MacSide, _ stream: MuxStream, to port: NWEndpoint.Port) async throws {
  try await mac.send(Data([0x05, 0x01, 0x00]), on: stream)
  #expect(try await mac.receive(2, from: stream) == Data([0x05, 0x00]))
  try await mac.send(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]) + portBytes(port), on: stream)
  let reply = try await mac.receive(10, from: stream)
  #expect(reply.count == 10 && reply[1] == 0x00)
}

private func portBytes(_ port: NWEndpoint.Port) -> Data {
  Data([UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)])
}

/// A value the test and callbacks on other queues both touch.
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    lock.withLock { stored }
  }

  func update(_ change: (inout Value) -> Void) {
    lock.withLock { change(&stored) }
  }
}

/// Waits for `condition`, for at most `seconds`. Returns whether it came true.
private func until(_ seconds: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() {
    if Date() > deadline { return false }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }
  return true
}

/// Runs blocking socket calls off the tests' own threads.
private func onThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
  await withCheckedContinuation { continuation in
    Thread.detachNewThread { continuation.resume(returning: body()) }
  }
}

private func writeAll(_ socket: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let count = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
      guard count > 0 else { return false }
      offset += count
    }
    return true
  }
}

private func readExactly(_ socket: Int32, _ count: Int) -> Data? {
  var data = Data(count: count)
  var offset = 0
  while offset < count {
    let received = data.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + offset, count - offset) }
    guard received > 0 else { return nil }
    offset += received
  }
  return data
}
