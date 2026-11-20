import Darwin
import Foundation
import Testing
@testable import ProxyCore

/// On the Mac, each stream of the direct link is handed out as a socket, joined to the stream by a
/// `Relay` (see `DirectLinkClient.connect`). These run that pairing with real sockets on both ends.
@Suite struct MuxSocketRelayTests {
  /// More than a window each way, then the end of the stream each way.
  @Test func carriesASocketOverAStreamAndBack() async {
    let link = SocketLink()
    let socket = link.connect()
    let sent = payload(3 * 1024 * 1024, seed: 42)
    let received = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        writeAll(socket, sent)
        shutdown(socket, Int32(SHUT_WR))
      }
      Thread.detachNewThread {
        continuation.resume(returning: readToEOF(socket))
      }
    }
    #expect(received == sent)
    Darwin.close(socket)
    await link.waitUntilIdle()
  }

  @Test func keepsSocketsApart() async {
    let link = SocketLink()
    await withTaskGroup(of: Bool.self) { group in
      for index in 0..<16 {
        group.addTask {
          let socket = link.connect()
          let sent = payload(100_000 + index * 37_000, seed: UInt64(index))
          let received = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
              writeAll(socket, sent)
              shutdown(socket, Int32(SHUT_WR))
            }
            Thread.detachNewThread {
              continuation.resume(returning: readToEOF(socket))
            }
          }
          Darwin.close(socket)
          return received == sent
        }
      }
      for await intact in group {
        #expect(intact)
      }
    }
    await link.waitUntilIdle()
  }

  /// A relay comes back to read after it cancelled a socket, when a write it had started on the
  /// other stream completes late. On a socket that had stopped reading, that used to resume its
  /// dispatch source one time too many, which ends the process.
  @Test func readingACancelledSocketIsHarmless() async {
    let queue = DispatchQueue(label: "MuxSocketRelayTests.cancelled")
    let (inner, outer) = makeSocketPair()
    let stream = SocketStream(fd: inner, queue: queue)
    // As much as the stream holds, so it stops reading from the socket.
    let filled = 256 * 1024
    Thread.detachNewThread { writeAll(outer, payload(filled, seed: 9)) }
    try? await Task.sleep(nanoseconds: 500_000_000)
    // Taken out in pieces that are all there, which leaves the stream parked.
    let taken = Box(0)
    for _ in 0..<4 {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async {
          stream.read(minimum: 64 * 1024, maximum: 64 * 1024) { data, _, _ in
            taken.value += data?.count ?? 0
            continuation.resume()
          }
        }
      }
    }
    #expect(await onQueue(queue) { taken.value } == filled)

    let completedAfterCancel = Box(false)
    queue.async {
      stream.cancel()
      stream.read(minimum: 1, maximum: 1024) { _, _, _ in completedAfterCancel.value = true }
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await onQueue(queue) { !completedAfterCancel.value })
    Darwin.close(outer)
  }

  /// An app that closes its connection mid-transfer takes the stream and the far socket with it.
  @Test func closingTheSocketEndsTheStream() async {
    let link = SocketLink()
    let socket = link.connect()
    writeAll(socket, payload(200_000, seed: 3))
    Darwin.close(socket)
    await link.waitUntilIdle()
  }
}

/// A client and a server mux, the server relaying each stream to a socket that echoes, like the
/// phone's proxy relaying to the internet.
private final class SocketLink: @unchecked Sendable {
  private let queue = DispatchQueue(label: "MuxSocketRelayTests")
  private var client: Mux!
  private var server: Mux!
  private var relays: [ObjectIdentifier: Relay] = [:]

  init() {
    // Linux has no per-socket switch for this; on a Mac `SocketStream` sets one.
    signal(SIGPIPE, SIG_IGN)
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1400)
    client = Mux(transport: near, role: .client)
    server = Mux(transport: far, role: .server, onStream: { [weak self] stream in
      // A stream that arrives after its test is over has nobody to serve it.
      guard let self else { return stream.cancel() }
      let (inner, outer) = makeSocketPair()
      Thread.detachNewThread { echoUntilEOF(outer) }
      relay(inner, stream)
    })
    queue.sync {
      client.start()
      server.start()
    }
  }

  /// A socket carried by a new stream, as `DirectLinkClient.connect` returns it.
  func connect() -> Int32 {
    let (mine, relayed) = makeSocketPair()
    // So a relay that stalls fails the test instead of hanging it.
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(mine, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(mine, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    queue.sync { relay(relayed, client.openStream()!) }
    return mine
  }

  /// Every stream ended on both sides and every relay closed its socket.
  func waitUntilIdle() async {
    await waitUntil(on: queue) { [self] in
      client.streamCount == 0 && server.streamCount == 0 && relays.isEmpty
    }
  }

  private func relay(_ fd: Int32, _ stream: MuxStream) {
    let relay = Relay(SocketStream(fd: fd, queue: queue), stream)
    let id = ObjectIdentifier(relay)
    relays[id] = relay
    relay.start { [weak self] in
      self?.relays[id] = nil
    }
  }
}

private func makeSocketPair() -> (Int32, Int32) {
  var fds: [Int32] = [0, 0]
  precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
  return (fds[0], fds[1])
}

private func writeAll(_ fd: Int32, _ data: Data) {
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
      guard count > 0 else { return }
      offset += count
    }
  }
}

private func readToEOF(_ fd: Int32) -> Data {
  var received = Data()
  var chunk = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
    let count = Darwin.read(fd, &chunk, chunk.count)
    guard count > 0 else { return received }
    received.append(chunk, count: count)
  }
}

/// Sends back what it reads, ends its own direction once the other side did, and closes.
private func echoUntilEOF(_ fd: Int32) {
  var chunk = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
    let count = Darwin.read(fd, &chunk, chunk.count)
    guard count > 0 else { break }
    var offset = 0
    while offset < count {
      let written = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, count - offset) }
      guard written > 0 else {
        Darwin.close(fd)
        return
      }
      offset += written
    }
  }
  shutdown(fd, Int32(SHUT_WR))
  Darwin.close(fd)
}
