import Foundation
import Testing
@testable import ProxyCore

@Suite struct MuxTests {
  @Test func echoesOverOneStream() async {
    let link = makeLink { echo($0) }
    let stream = await link.openStream()
    let message = Data("through the phone".utf8)
    #expect(await write(message, to: stream, thenEOF: true, on: link.queue) == nil)
    let reply = await readToEnd(stream, on: link.queue)
    #expect(reply.data == message)
    #expect(reply.error == nil)
  }

  /// Far more than a window, arriving 1 KB at a time, so frames reach the mux split anywhere.
  @Test func carriesALargeTransferIntact() async {
    let link = makeLink(pieceSize: 1000) { echo($0) }
    let stream = await link.openStream()
    let sent = payload(6 * 1024 * 1024, seed: 1)
    async let reply = readToEnd(stream, on: link.queue)
    #expect(await write(sent, to: stream, chunk: 48 * 1024, thenEOF: true, on: link.queue) == nil)
    let received = await reply
    #expect(received.error == nil)
    #expect(received.data == sent)
  }

  @Test func keepsStreamsApart() async {
    let link = makeLink(pieceSize: 700) { echo($0) }
    await withTaskGroup(of: Bool.self) { group in
      for index in 0..<40 {
        group.addTask {
          let stream = await link.openStream()
          let sent = payload(20_000 + index * 9_000, seed: UInt64(index))
          async let reply = readToEnd(stream, on: link.queue)
          let writeError = await write(sent, to: stream, chunk: 5_000 + index * 100, thenEOF: true, on: link.queue)
          let received = await reply
          return writeError == nil && received.error == nil && received.data == sent
        }
      }
      for await intact in group {
        #expect(intact)
      }
    }
    #expect(await onQueue(link.queue) { link.client.streamCount } == 0)
    #expect(await onQueue(link.queue) { link.server.streamCount } == 0)
  }

  /// A stream nobody reads stops taking data at its window, while another stream on the same
  /// connection carries on. Once it is read, the rest arrives.
  @Test func slowReaderHoldsBackOnlyItsOwnStream() async {
    let accepted = Box<[MuxStream]>([])
    let link = makeLink { accepted.value.append($0) }
    let total = 2 * 1024 * 1024
    let stalled = await link.openStream()
    let completed = Box(0)
    let stalledData = payload(total, seed: 7)
    link.queue.async {
      var offset = 0
      func next() {
        guard offset < total else { return stalled.writeEOF() }
        let piece = stalledData.subdata(in: offset..<offset + 64 * 1024)
        offset += piece.count
        stalled.write(piece) { error in
          guard error == nil else { return }
          completed.value += piece.count
          next()
        }
      }
      next()
    }

    let busy = await link.openStream()
    let busyData = payload(1024 * 1024, seed: 8)
    await waitUntil(on: link.queue) { accepted.value.count == 2 }
    let busyServer = await onQueue(link.queue) { accepted.value[1] }
    async let busyReceived = readToEnd(busyServer, on: link.queue)
    #expect(await write(busyData, to: busy, thenEOF: true, on: link.queue) == nil)
    #expect(await busyReceived.data == busyData)

    // The other stream finished, and this one took exactly a window and no more.
    await waitUntil(on: link.queue) { completed.value >= Mux.window }
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await onQueue(link.queue) { completed.value } == Mux.window)

    let stalledServer = await onQueue(link.queue) { accepted.value[0] }
    let received = await readToEnd(stalledServer, on: link.queue)
    #expect(received.error == nil)
    #expect(received.data == stalledData)
    #expect(await onQueue(link.queue) { completed.value } == total)
  }

  @Test func halfCloseLeavesTheOtherDirectionOpen() async {
    let request = Box(Data())
    let link = makeLink { stream in
      // Answers only once the client has finished sending.
      func next() {
        stream.read(minimum: 1, maximum: 64 * 1024) { data, isComplete, _ in
          if let data { request.value.append(data) }
          guard isComplete else { return next() }
          stream.write(Data("reply to ".utf8) + request.value) { _ in stream.writeEOF() }
        }
      }
      next()
    }
    let stream = await link.openStream()
    #expect(await write(Data("a request".utf8), to: stream, thenEOF: true, on: link.queue) == nil)
    let reply = await readToEnd(stream, on: link.queue)
    #expect(reply.error == nil)
    #expect(reply.data == Data("reply to a request".utf8))
  }

  @Test func resetFailsTheOtherSide() async {
    let link = makeLink { stream in
      stream.read(minimum: 1, maximum: 16) { _, _, _ in stream.cancel() }
    }
    let stream = await link.openStream()
    #expect(await write(Data("hello".utf8), to: stream, thenEOF: false, on: link.queue) == nil)
    let reply = await readToEnd(stream, on: link.queue)
    #expect(reply.error as? MuxError == .reset)
    // A write after the reset fails instead of waiting for a reader that is gone.
    let error = await write(Data("more".utf8), to: stream, thenEOF: false, on: link.queue)
    #expect(error as? MuxError == .reset)
    #expect(await onQueue(link.queue) { link.client.streamCount } == 0)
  }

  @Test func closingTheConnectionFailsEveryStream() async {
    let closed = Box<[String]>([])
    let link = makeLink(onStream: { _ in }, onClose: { side in closed.value.append(side) })
    let first = await link.openStream()
    let second = await link.openStream()
    async let firstRead = readToEnd(first, on: link.queue)
    async let secondRead = readToEnd(second, on: link.queue)
    link.queue.async { link.server.close() }
    #expect(await firstRead.error as? MuxError == .connectionClosed)
    #expect(await secondRead.error as? MuxError == .connectionClosed)
    #expect(await onQueue(link.queue) { link.client.openStream() } == nil)
    #expect(await onQueue(link.queue) { closed.value.sorted() } == ["client", "server"])
  }

  /// The phone's last word before it stops, like "stopped by hand", is written and the connection
  /// closed in the same breath. It still has to arrive.
  @Test func closingAfterAFlushDeliversWhatWasWritten() async {
    let result = await lastWords { $0.closeAfterFlush(on: $1) }
    #expect(result.received == result.sent)
    #expect(result.error as? MuxError == .connectionClosed)
    #expect(result.serverIsClosed)
  }

  /// What that is for: closing at once drops what the connection hadn't taken yet.
  @Test func closingAtOnceDropsWhatWasNotSentYet() async {
    let result = await lastWords { server, _ in server.close() }
    #expect(result.received.count < result.sent.count)
    #expect(result.error as? MuxError == .connectionClosed)
  }

  /// While it says its last words, a connection takes up nothing new: the proxy behind it is
  /// stopping.
  @Test func nothingNewIsTakenUpWhileClosingAfterAFlush() async {
    let accepted = Box<[MuxStream]>([])
    let link = makeLink { accepted.value.append($0) }
    _ = await link.openStream()
    await waitUntil(on: link.queue) { accepted.value.count == 1 }
    link.queue.async {
      // Enough to keep the connection busy while the client's next stream arrives.
      accepted.value[0].write(payload(200_000, seed: 5)) { _ in }
      link.server.closeAfterFlush(on: link.queue)
      _ = link.client.openStream()
    }
    await waitUntil(on: link.queue) { link.server.isClosed }
    #expect(await onQueue(link.queue) { accepted.value.count } == 1)
  }

  /// A relay that dropped a stream isn't called back about a write the connection had already
  /// taken. It would go on reading from a source it has closed.
  @Test func aCancelledStreamCompletesNoWrite() async {
    let link = makeLink { _ in }
    let stream = await link.openStream()
    let completed = Box(false)
    link.queue.async {
      stream.write(Data("on its way".utf8)) { _ in completed.value = true }
      stream.cancel()
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await onQueue(link.queue) { !completed.value })
  }

  /// A connection whose other side stopped reading is still closed, after a moment.
  @Test func closingAfterAFlushDoesNotWaitForEver() async {
    let queue = DispatchQueue(label: "MuxTests.stuck")
    let closed = Box(false)
    let server = Mux(transport: StuckStream(), role: .server, onClose: { _ in closed.value = true })
    queue.async { server.closeAfterFlush(on: queue, within: 0.05) }
    await waitUntil(on: queue) { closed.value }
    #expect(await onQueue(queue) { server.isClosed })
  }

  /// The SOCKS5 handshake reads exact counts, which rarely line up with how the data was framed.
  @Test func readsExactCountsAcrossFrames() async {
    let accepted = Box<MuxStream?>(nil)
    let link = makeLink(pieceSize: 3) { accepted.value = $0 }
    let stream = await link.openStream()
    for piece in ["ab", "cdefg", "h", "ijklmnop"] {
      #expect(await write(Data(piece.utf8), to: stream, thenEOF: false, on: link.queue) == nil)
    }
    link.queue.async { stream.writeEOF() }
    let server = await onQueue(link.queue) { accepted.value! }
    var reads: [String] = []
    for count in [1, 4, 6, 3, 8] {
      let result = await readOnce(server, minimum: count, maximum: count, on: link.queue)
      // Readers index from zero.
      #expect(result.data?.startIndex ?? 0 == 0)
      reads.append(String(decoding: result.data ?? Data(), as: UTF8.self) + (result.isComplete ? "." : ""))
    }
    // The last read asks for more than is left and gets the rest, with the end of the stream.
    #expect(reads == ["a", "bcde", "fghijk", "lmn", "op."])
  }

  @Test func rejectsAWrongPreface() async {
    let queue = DispatchQueue(label: "MuxTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let reason = Box<Error?>(nil)
    let closed = Box(false)
    let server = Mux(transport: far, role: .server, onClose: { error in
      reason.value = error
      closed.value = true
    })
    queue.async {
      server.start()
      near.write(Data("GET / HTTP/1.1\r\n".utf8)) { _ in }
    }
    await waitUntil(on: queue) { closed.value }
    #expect(await onQueue(queue) { reason.value as? MuxError } == .protocolViolation)
    #expect(await onQueue(queue) { server.isClosed })
  }

  /// A client that ignores the window gets its stream reset, and the other streams go on.
  @Test func resetsAStreamThatOverrunsItsWindow() async {
    let queue = DispatchQueue(label: "MuxTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 4096)
    let accepted = Box<[MuxStream]>([])
    let server = Mux(transport: far, role: .server, onStream: { accepted.value.append($0) })
    let chunk = Data(repeating: 9, count: 64 * 1024)
    queue.async {
      server.start()
      near.write(Mux.preface) { _ in }
      near.write(frame(1, .open)) { _ in }
      near.write(frame(2, .open)) { _ in }
      // One frame more than a window, with nobody reading.
      for _ in 0...(Mux.window / chunk.count) {
        near.write(frame(1, .data, chunk)) { _ in }
      }
      near.write(frame(2, .data, Data("still here".utf8))) { _ in }
      near.write(frame(2, .fin)) { _ in }
    }
    await waitUntil(on: queue) { accepted.value.count == 2 }
    let overrun = await onQueue(queue) { accepted.value[0] }
    let other = await onQueue(queue) { accepted.value[1] }
    #expect(await readToEnd(other, on: queue).data == Data("still here".utf8))
    #expect(await readToEnd(overrun, on: queue).error as? MuxError == .protocolViolation)
    // The raw client is told with a reset frame for stream 1.
    let reset = await readOnce(near, minimum: 8, maximum: 8, on: queue)
    #expect(reset.data.map { [UInt8]($0) } == [0, 0, 0, 1, Mux.FrameType.reset.rawValue, 0, 0, 0])
    #expect(await onQueue(queue) { server.isClosed } == false)
  }

  @Test func closesOnAnUnknownFrameType() async {
    let queue = DispatchQueue(label: "MuxTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let closed = Box(false)
    let server = Mux(transport: far, role: .server, onClose: { _ in closed.value = true })
    queue.async {
      server.start()
      near.write(Mux.preface + Data([0, 0, 0, 1, 0x7F, 0, 0, 0])) { _ in }
    }
    await waitUntil(on: queue) { closed.value }
    #expect(await onQueue(queue) { server.isClosed })
  }
}

// MARK: - Helpers

/// A value shared between a test and the closures it hands to the mux, all of which run on one queue.
final class Box<Value>: @unchecked Sendable {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}

private struct Link: @unchecked Sendable {
  let queue: DispatchQueue
  let client: Mux
  let server: Mux

  func openStream() async -> MuxStream {
    await onQueue(queue) { client.openStream()! }
  }
}

/// A client and a server mux joined by an in-memory connection that delivers `pieceSize` bytes at a time.
private func makeLink(
  pieceSize: Int = 1500,
  onStream: @escaping (MuxStream) -> Void,
  onClose: @escaping (String) -> Void = { _ in }
) -> Link {
  let queue = DispatchQueue(label: "MuxTests")
  let (near, far) = PipeEnd.pair(queue: queue, pieceSize: pieceSize)
  let client = Mux(transport: near, role: .client, onClose: { _ in onClose("client") })
  let server = Mux(transport: far, role: .server, onStream: onStream, onClose: { _ in onClose("server") })
  queue.sync {
    client.start()
    server.start()
  }
  return Link(queue: queue, client: client, server: server)
}

private func frame(_ id: UInt32, _ type: Mux.FrameType, _ payload: Data = Data()) -> Data {
  Data([
    UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16), UInt8(truncatingIfNeeded: id >> 8),
    UInt8(truncatingIfNeeded: id), type.rawValue,
    UInt8(truncatingIfNeeded: payload.count >> 16), UInt8(truncatingIfNeeded: payload.count >> 8),
    UInt8(truncatingIfNeeded: payload.count),
  ]) + payload
}

/// Sends back what it reads, and its end of the stream once the other side ended.
private func echo(_ stream: MuxStream) {
  stream.read(minimum: 1, maximum: 64 * 1024) { data, isComplete, error in
    guard error == nil else { return stream.cancel() }
    guard let data else {
      if isComplete { stream.writeEOF() }
      return
    }
    stream.write(data) { writeError in
      guard writeError == nil else { return stream.cancel() }
      isComplete ? stream.writeEOF() : echo(stream)
    }
  }
}

/// The same bytes for the same seed, and different ones for another.
func payload(_ count: Int, seed: UInt64) -> Data {
  var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
  var bytes = [UInt8](repeating: 0, count: count)
  for index in bytes.indices {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
  }
  return Data(bytes)
}

func onQueue<Value>(_ queue: DispatchQueue, _ body: @escaping () -> Value) async -> Value {
  await withCheckedContinuation { continuation in
    queue.async { continuation.resume(returning: body()) }
  }
}

/// Waits for `condition`, looked at on `queue`. Not for ever: a wait with no end would hold up the
/// whole run instead of failing one test.
func waitUntil(
  on queue: DispatchQueue, within seconds: Int = 30,
  sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping () -> Bool
) async {
  let deadline = Date().addingTimeInterval(TimeInterval(seconds))
  while !(await onQueue(queue, condition)) {
    guard Date() < deadline else {
      Issue.record("waited \(seconds) s for something that never happened", sourceLocation: sourceLocation)
      return
    }
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
}

/// Writes `data` in `chunk`-sized writes, each after the one before completed, and returns the first error.
private func write(_ data: Data, to stream: ByteStream, chunk: Int = 64 * 1024, thenEOF: Bool, on queue: DispatchQueue) async -> Error? {
  await withCheckedContinuation { continuation in
    queue.async {
      var offset = 0
      func next() {
        guard offset < data.count else {
          if thenEOF { stream.writeEOF() }
          return continuation.resume(returning: nil)
        }
        let piece = data.subdata(in: offset..<min(offset + chunk, data.count))
        offset += piece.count
        stream.write(piece) { error in
          if let error { return continuation.resume(returning: error) }
          next()
        }
      }
      next()
    }
  }
}

private func readOnce(_ stream: ByteStream, minimum: Int, maximum: Int, on queue: DispatchQueue) async -> (data: Data?, isComplete: Bool, error: Error?) {
  await withCheckedContinuation { continuation in
    queue.async {
      stream.read(minimum: minimum, maximum: maximum) { data, isComplete, error in
        continuation.resume(returning: (data, isComplete, error))
      }
    }
  }
}

/// Reads until the stream ends or fails.
private func readToEnd(_ stream: ByteStream, on queue: DispatchQueue) async -> (data: Data, error: Error?) {
  await withCheckedContinuation { continuation in
    queue.async {
      var received = Data()
      func next() {
        stream.read(minimum: 1, maximum: 64 * 1024) { data, isComplete, error in
          if let data { received.append(data) }
          if error != nil || isComplete || data == nil {
            return continuation.resume(returning: (received, error))
          }
          next()
        }
      }
      next()
    }
  }
}

/// The server writes on a stream the client is reading, as a relay always is, and ends the
/// connection with `end` in the same turn of the queue. Returns what the client got.
private func lastWords(
  _ end: @escaping (Mux, DispatchQueue) -> Void
) async -> (sent: Data, received: Data, error: Error?, serverIsClosed: Bool) {
  let accepted = Box<MuxStream?>(nil)
  let link = makeLink(pieceSize: 500) { accepted.value = $0 }
  let stream = await link.openStream()
  await waitUntil(on: link.queue) { accepted.value != nil }
  let sent = payload(100_000, seed: 3)
  let received = Box(Data())
  let ending = Box<(isOver: Bool, error: Error?)>((false, nil))
  link.queue.async {
    func next() {
      stream.read(minimum: 1, maximum: 64 * 1024) { data, isComplete, error in
        if let data { received.value.append(data) }
        guard error == nil, !isComplete, data != nil else {
          ending.value = (true, error)
          return
        }
        next()
      }
    }
    next()
    accepted.value?.write(sent) { _ in }
    end(link.server, link.queue)
  }
  await waitUntil(on: link.queue) { ending.value.isOver }
  return await onQueue(link.queue) { (sent, received.value, ending.value.error, link.server.isClosed) }
}

private struct PipeClosed: Error {}

/// A connection that takes nothing and gives nothing: neither a read nor a write ever completes.
private final class StuckStream: ByteStream {
  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {}
  func write(_ data: Data, completion: @escaping (Error?) -> Void) {}
  func writeEOF() {}
  func cancel() {}
}

/// One end of an in-memory connection. Bytes written here arrive at the other end in order,
/// `pieceSize` at a time, and are handed to the reader as a slice that doesn't start at index
/// zero, like a piece of a larger receive buffer. Everything runs on `queue`.
final class PipeEnd: ByteStream {
  private let queue: DispatchQueue
  private let pieceSize: Int
  private weak var peer: PipeEnd?
  /// Keeps the other end alive for as long as this one is, so a test only has to hold one.
  private var retainedPeer: PipeEnd?
  private var buffer = Data()
  private var reachedEOF = false
  private var pendingRead: (minimum: Int, maximum: Int, completion: (Data?, Bool, Error?) -> Void)?
  private var outbox: [(data: Data, offset: Int, completion: (Error?) -> Void)] = []
  private var isDelivering = false
  private var isCancelled = false

  private init(queue: DispatchQueue, pieceSize: Int) {
    self.queue = queue
    self.pieceSize = pieceSize
  }

  static func pair(queue: DispatchQueue, pieceSize: Int) -> (PipeEnd, PipeEnd) {
    let near = PipeEnd(queue: queue, pieceSize: pieceSize)
    let far = PipeEnd(queue: queue, pieceSize: pieceSize)
    near.peer = far
    far.peer = near
    near.retainedPeer = far
    return (near, far)
  }

  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
    pendingRead = (minimum, maximum, completion)
    queue.async { self.fulfill() }
  }

  func write(_ data: Data, completion: @escaping (Error?) -> Void) {
    guard !isCancelled else {
      queue.async { completion(PipeClosed()) }
      return
    }
    outbox.append((Data(data), 0, completion))
    deliver()
  }

  func writeEOF() {}

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    pendingRead = nil
    let unsent = outbox
    outbox.removeAll()
    queue.async { [peer] in
      unsent.forEach { $0.completion(PipeClosed()) }
      peer?.peerClosed()
    }
  }

  private func peerClosed() {
    reachedEOF = true
    fulfill()
  }

  private func deliver() {
    guard !isDelivering, !outbox.isEmpty else { return }
    isDelivering = true
    queue.async { self.deliverNextPiece() }
  }

  private func deliverNextPiece() {
    isDelivering = false
    guard !isCancelled, var entry = outbox.first else { return }
    let count = min(pieceSize, entry.data.count - entry.offset)
    peer?.arrive(entry.data.subdata(in: entry.offset..<entry.offset + count))
    entry.offset += count
    if entry.offset == entry.data.count {
      outbox.removeFirst()
      entry.completion(nil)
    } else {
      outbox[0] = entry
    }
    deliver()
  }

  private func arrive(_ piece: Data) {
    guard !isCancelled else { return }
    buffer.append(piece)
    fulfill()
  }

  private func fulfill() {
    guard let request = pendingRead, buffer.count >= request.minimum || reachedEOF else { return }
    pendingRead = nil
    let count = min(request.maximum, buffer.count)
    let chunk = (Data([0, 0, 0]) + buffer.prefix(count)).dropFirst(3)
    buffer = Data(buffer.dropFirst(count))
    request.completion(chunk.isEmpty ? nil : chunk, reachedEOF && buffer.isEmpty, nil)
  }
}
