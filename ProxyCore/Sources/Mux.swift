import Foundation

/// Why a multiplexed stream ended early.
enum MuxError: Error, Equatable {
  /// The other side aborted this stream.
  case reset
  /// The connection carrying the streams is gone.
  case connectionClosed
  /// The other side sent something the protocol doesn't allow.
  case protocolViolation
}

/// Carries many independent byte streams over one ordered connection.
///
/// A connection over the direct Wi-Fi link is slow to set up, and a page load opens dozens of
/// proxied connections, so the Mac keeps a single connection to the phone and opens a stream on it
/// for each one. Opening a stream costs one small frame and no round trip.
///
/// The client starts by sending `preface`. After that every frame is:
///
///     stream ID (UInt32 BE) | type (UInt8) | payload length (UInt24 BE) | payload
///
/// Each stream has its own flow-control window, so one whose reader is slow holds back only itself:
/// a sender may have at most `window` bytes the receiver hasn't read yet, and the receiver hands
/// credit back with `window` frames as its reader consumes them.
///
/// All state is confined to the queue the transport calls back on, and every method of `Mux` and
/// `MuxStream` must be called on that queue.
final class Mux {
  enum Role {
    /// Opens streams.
    case client
    /// Accepts the client's streams.
    case server
  }

  enum FrameType: UInt8 {
    /// The client opened the stream.
    case open = 1
    case data = 2
    /// The sender has no more data for the stream; the other direction stays open.
    case fin = 3
    /// The sender dropped the stream, in both directions.
    case reset = 4
    /// The sender read this many more bytes (UInt32 BE), so the other side may send as many again.
    case window = 5
  }

  /// "NTM" and the protocol version.
  static let preface = Data([0x4E, 0x54, 0x4D, 0x01])
  /// Bytes a stream's sender may be ahead of its reader.
  static let window = 512 * 1024
  /// The largest payload a `data` frame is sent with, so a busy stream can't hold up the others for long.
  static let maxDataPayload = 64 * 1024
  /// Streams a client may have open at once; one more is reset.
  static let maxStreams = 4096
  private static let headerSize = 8
  /// The largest payload accepted. A header that announces more ends the connection.
  private static let maxPayload = 256 * 1024

  private let transport: ByteStream
  private let role: Role
  private let onStream: (MuxStream) -> Void
  private let onClose: (Error?) -> Void
  private var streams: [UInt32: MuxStream] = [:]
  private var lastStreamID: UInt32 = 0
  private(set) var isClosed = false

  /// `onStream` gets each stream the client opens. `onClose` is called once, with the reason when
  /// the connection failed and `nil` when either side closed it.
  init(
    transport: ByteStream,
    role: Role,
    onStream: @escaping (MuxStream) -> Void = { $0.cancel() },
    onClose: @escaping (Error?) -> Void = { _ in }
  ) {
    self.transport = transport
    self.role = role
    self.onStream = onStream
    self.onClose = onClose
  }

  func start() {
    switch role {
    case .client:
      transport.write(Self.preface) { [weak self] error in
        if let error { self?.close(error) }
      }
      readHeader()
    case .server:
      transport.read(minimum: Self.preface.count, maximum: Self.preface.count) { [weak self] data, _, error in
        guard let self, !isClosed else { return }
        guard let data, Data(data) == Self.preface else {
          return close(error ?? MuxError.protocolViolation)
        }
        readHeader()
      }
    }
  }

  /// Opens a stream to the server, or returns `nil` once the connection is closed.
  func openStream() -> MuxStream? {
    guard !isClosed, role == .client, streams.count < Self.maxStreams else { return nil }
    repeat {
      lastStreamID &+= 1
    } while lastStreamID == 0 || streams[lastStreamID] != nil
    let stream = MuxStream(id: lastStreamID, mux: self)
    streams[lastStreamID] = stream
    send(.open, stream: lastStreamID)
    return stream
  }

  var streamCount: Int { streams.count }

  /// Ends the connection and every stream on it.
  func close(_ error: Error? = nil) {
    guard !isClosed else { return }
    isClosed = true
    transport.cancel()
    let open = Array(streams.values)
    streams.removeAll()
    for stream in open {
      stream.fail(MuxError.connectionClosed)
    }
    onClose(error)
  }

  /// Ends the connection once it has taken everything written so far, so a last word still goes
  /// out, like the phone telling the Mac it was stopped by hand. `close()` drops what the
  /// connection hasn't taken yet.
  func closeAfterFlush(on queue: DispatchQueue, within seconds: TimeInterval = 2) {
    guard !isClosed else { return }
    // A frame that says nothing: credit for a stream that doesn't exist, which the other side
    // ignores. The connection takes frames in order, so once it took this one it took all before it.
    send(.window, stream: 0, payload: Data([0, 0, 0, 0])) { [self] _ in close() }
    // Not for ever: the other side may have stopped reading.
    queue.asyncAfter(deadline: .now() + seconds) { [self] in close() }
  }

  // MARK: Used by MuxStream

  func send(_ type: FrameType, stream id: UInt32, payload: Data = Data(), completion: ((Error?) -> Void)? = nil) {
    guard !isClosed else {
      completion?(MuxError.connectionClosed)
      return
    }
    // One write per frame, so a frame never shares the connection with half of another.
    var frame = Data(capacity: Self.headerSize + payload.count)
    frame.append(contentsOf: [
      UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
      UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id),
      type.rawValue,
      UInt8(truncatingIfNeeded: payload.count >> 16), UInt8(truncatingIfNeeded: payload.count >> 8),
      UInt8(truncatingIfNeeded: payload.count),
    ])
    frame.append(payload)
    transport.write(frame) { [weak self] error in
      completion?(error)
      if let error { self?.close(error) }
    }
  }

  /// Stops routing frames to a stream that is done.
  func forget(_ stream: MuxStream) {
    if streams[stream.id] === stream {
      streams.removeValue(forKey: stream.id)
    }
  }

  // MARK: Reading

  private func readHeader() {
    transport.read(minimum: Self.headerSize, maximum: Self.headerSize) { [weak self] data, _, error in
      guard let self, !isClosed else { return }
      // Fewer bytes than a header means the connection ended.
      guard let data, data.count == Self.headerSize else { return close(error) }
      let header = [UInt8](data)
      let id = UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3])
      let length = Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
      guard let type = FrameType(rawValue: header[4]), length <= Self.maxPayload else {
        return close(MuxError.protocolViolation)
      }
      guard length > 0 else {
        handle(type, stream: id, payload: Data())
        if !isClosed { readHeader() }
        return
      }
      transport.read(minimum: length, maximum: length) { [weak self] payload, _, error in
        guard let self, !isClosed else { return }
        guard let payload, payload.count == length else { return close(error) }
        // Readers index what they get from zero, which a slice of a larger buffer doesn't allow.
        handle(type, stream: id, payload: payload.startIndex == 0 ? payload : Data(payload))
        if !isClosed { readHeader() }
      }
    }
  }

  private func handle(_ type: FrameType, stream id: UInt32, payload: Data) {
    switch type {
    case .open:
      guard role == .server, id != 0, streams[id] == nil else { return close(MuxError.protocolViolation) }
      guard streams.count < Self.maxStreams else { return send(.reset, stream: id) }
      let stream = MuxStream(id: id, mux: self)
      streams[id] = stream
      onStream(stream)
    case .data:
      // No stream: this side dropped it while the frame was on its way.
      streams[id]?.receive(payload)
    case .fin:
      streams[id]?.receiveEOF()
    case .reset:
      streams.removeValue(forKey: id)?.fail(MuxError.reset)
    case .window:
      guard payload.count == 4 else { return close(MuxError.protocolViolation) }
      let bytes = [UInt8](payload)
      let credit = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
      streams[id]?.addSendCredit(credit)
    }
  }
}

/// One stream of a `Mux`. It reads and writes like any other `ByteStream`, so the proxy serves it
/// the way it serves a socket.
final class MuxStream: ByteStream {
  let id: UInt32
  private weak var mux: Mux?

  /// What arrived and hasn't been read: `chunks[head...]`, the first of them from `headOffset` on.
  private var chunks: [Data] = []
  private var head = 0
  private var headOffset = 0
  private var buffered = 0
  /// Bytes read since the last `window` frame.
  private var consumed = 0
  private var receivedEOF = false
  private var error: Error?
  private var pendingRead: (minimum: Int, maximum: Int, completion: (Data?, Bool, Error?) -> Void)?
  private var isFulfillingRead = false

  /// Bytes this side may still send before the other side's reader has to catch up.
  private var sendCredit = Mux.window
  private var pendingWrites: [(data: Data, completion: (Error?) -> Void)] = []
  private var writeOffset = 0
  private var wantsEOF = false
  private var sentEOF = false
  private var isCancelled = false

  init(id: UInt32, mux: Mux) {
    self.id = id
    self.mux = mux
  }

  // MARK: ByteStream

  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
    guard !isCancelled else { return }
    pendingRead = (minimum, maximum, completion)
    // Called from a read completion: the loop in `fulfillPendingRead` picks this up, so chained
    // reads over buffered data don't recurse once per read.
    fulfillPendingRead()
  }

  func write(_ data: Data, completion: @escaping (Error?) -> Void) {
    if let error { return completion(error) }
    guard !isCancelled, !wantsEOF, mux != nil else { return completion(MuxError.connectionClosed) }
    guard !data.isEmpty else { return completion(nil) }
    pendingWrites.append((data, completion))
    flushWrites()
  }

  func writeEOF() {
    guard !isCancelled, error == nil, !wantsEOF else { return }
    wantsEOF = true
    flushWrites()
  }

  /// Drops the stream. Like a cancelled socket, nothing pending is completed after this.
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    pendingRead = nil
    pendingWrites.removeAll()
    dropBuffer()
    // A stream both sides finished needs no reset, and one that already failed is gone over there.
    if error == nil, !(sentEOF && receivedEOF) {
      mux?.send(.reset, stream: id)
    }
    mux?.forget(self)
  }

  // MARK: Frames from the Mux

  func receive(_ payload: Data) {
    guard !isCancelled, error == nil, !receivedEOF, !payload.isEmpty else { return }
    // The other side may only be `window` bytes ahead of what was read here and reported back.
    guard buffered + consumed + payload.count <= Mux.window else {
      mux?.send(.reset, stream: id)
      mux?.forget(self)
      return fail(MuxError.protocolViolation)
    }
    chunks.append(payload)
    buffered += payload.count
    fulfillPendingRead()
  }

  func receiveEOF() {
    guard !isCancelled, error == nil, !receivedEOF else { return }
    receivedEOF = true
    forgetIfDone()
    fulfillPendingRead()
  }

  func addSendCredit(_ credit: Int) {
    guard !isCancelled, error == nil, credit > 0 else { return }
    sendCredit += credit
    flushWrites()
  }

  /// Ends the stream with `error`: the reset from the other side, or the connection going away.
  func fail(_ error: Error) {
    guard self.error == nil, !isCancelled else { return }
    self.error = error
    dropBuffer()
    let failed = pendingWrites
    pendingWrites.removeAll()
    writeOffset = 0
    for write in failed {
      write.completion(error)
    }
    fulfillPendingRead()
  }

  // MARK: Reading

  private func fulfillPendingRead() {
    guard !isFulfillingRead else { return }
    isFulfillingRead = true
    defer { isFulfillingRead = false }
    while let request = pendingRead {
      if let error {
        pendingRead = nil
        request.completion(nil, false, error)
        continue
      }
      guard buffered >= request.minimum || receivedEOF else { return }
      let data = take(minimum: request.minimum, maximum: request.maximum)
      pendingRead = nil
      grantCredit(data.count)
      request.completion(data.isEmpty ? nil : data, receivedEOF && buffered == 0, nil)
    }
  }

  private func take(minimum: Int, maximum: Int) -> Data {
    guard head < chunks.count else { return Data() }
    let first = chunks[head]
    // A whole frame's payload that fits goes to the reader as it arrived, without a copy.
    if headOffset == 0, first.count >= minimum, first.count <= maximum {
      popChunk()
      buffered -= first.count
      return first
    }
    var data = Data(capacity: min(maximum, buffered))
    while data.count < maximum, head < chunks.count {
      let chunk = chunks[head]
      let count = min(maximum - data.count, chunk.count - headOffset)
      let start = chunk.startIndex + headOffset
      data.append(chunk[start..<start + count])
      headOffset += count
      if headOffset == chunk.count { popChunk() }
    }
    buffered -= data.count
    return data
  }

  private func popChunk() {
    head += 1
    headOffset = 0
    if head == chunks.count {
      chunks.removeAll(keepingCapacity: true)
      head = 0
    } else if head >= 64 {
      chunks.removeFirst(head)
      head = 0
    }
  }

  private func dropBuffer() {
    chunks.removeAll()
    head = 0
    headOffset = 0
    buffered = 0
  }

  /// Tells the other side it may send what was just read again, once that adds up to half a window.
  private func grantCredit(_ count: Int) {
    guard count > 0, !receivedEOF else { return }
    consumed += count
    guard consumed >= Mux.window / 2 else { return }
    let credit = consumed
    consumed = 0
    mux?.send(.window, stream: id, payload: Data([
      UInt8(truncatingIfNeeded: credit >> 24), UInt8(truncatingIfNeeded: credit >> 16),
      UInt8(truncatingIfNeeded: credit >> 8), UInt8(truncatingIfNeeded: credit),
    ]))
  }

  // MARK: Writing

  private func flushWrites() {
    guard error == nil, !isCancelled, let mux else { return }
    while sendCredit > 0, let (data, completion) = pendingWrites.first {
      let count = min(data.count - writeOffset, sendCredit, Mux.maxDataPayload)
      let start = data.startIndex + writeOffset
      sendCredit -= count
      if writeOffset + count == data.count {
        // The write is done once its last frame is: the caller waits for that before it reads more
        // from where the data comes from, which is what slows a fast source down to this link.
        pendingWrites.removeFirst()
        writeOffset = 0
        mux.send(.data, stream: id, payload: data[start..<start + count], completion: completion)
      } else {
        writeOffset += count
        mux.send(.data, stream: id, payload: data[start..<start + count])
      }
      guard error == nil, !isCancelled else { return }
    }
    if pendingWrites.isEmpty, wantsEOF, !sentEOF {
      sentEOF = true
      mux.send(.fin, stream: id)
      forgetIfDone()
    }
  }

  /// Once both directions ended, no more frames come for this stream. What's buffered stays readable.
  private func forgetIfDone() {
    if sentEOF, receivedEOF {
      mux?.forget(self)
    }
  }
}
