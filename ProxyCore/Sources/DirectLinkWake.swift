import CryptoKit
import Foundation

/// Waking the phone's app from the Mac over Bluetooth, so the direct Wi-Fi link can come up without
/// anyone touching the phone.
///
/// The phone's app offers a small Bluetooth service that iOS keeps reachable while the app is
/// suspended, and wakes the app for (see `DirectLinkWakeBeacon`). The Mac asks through it for the
/// proxy to be started (see `DirectLinkWaker`). Only a Mac that knows the pairing code may:
///
///     Mac reads `challenge`    16 random bytes, new each time
///     Mac writes `answer`      HMAC-SHA256(pairing code, "nothering wake 1" + challenge), first 16 bytes
///
/// A challenge is good for one answer, from the Mac it was given to, and for `challengeLifetime`, so
/// an answer overheard once can't be sent again. Both values fit a single Bluetooth read and write
/// at the smallest packet size.
enum DirectLinkWake {
  static let serviceID = "818F2E68-8709-4C85-A1E3-5D62D2F2B2A4"
  static let challengeID = "7A1B24FD-5574-4BC8-91FF-4225619B7C21"
  static let answerID = "BB53748E-4CE2-42D3-948E-9F50393108E5"

  static let challengeSize = 16
  static let answerSize = 16
  static let challengeLifetime: TimeInterval = 30

  /// What a Mac with `code` answers to `challenge`.
  static func answer(code: String, challenge: Data) -> Data {
    let key = SymmetricKey(data: Data(DirectLinkCode.normalized(code).utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data("nothering wake 1".utf8) + challenge, using: key)
    return Data(mac.prefix(answerSize))
  }
}

/// The phone's side of the exchange: hands each Mac that asks a challenge and checks its answer.
struct WakeChallenger {
  /// How many Macs can be between asking and answering at once. One more pushes the oldest out.
  static let capacity = 8

  private let code: String
  /// The challenge each asker was last given, by its Bluetooth identifier, and when.
  private var pending: [UUID: (challenge: Data, issuedAt: Date)] = [:]

  init(code: String) {
    self.code = code
  }

  /// A new challenge for `asker`, replacing the one it had. Another asker's stays good, so a Mac
  /// that merely asks can't spoil the answer of the one that is paired.
  mutating func issue(to asker: UUID, now: Date = Date()) -> Data {
    let challenge = Data((0..<DirectLinkWake.challengeSize).map { _ in UInt8.random(in: .min ... .max) })
    if pending[asker] == nil, pending.count >= Self.capacity,
       let oldest = pending.min(by: { $0.value.issuedAt < $1.value.issuedAt })?.key {
      pending[oldest] = nil
    }
    pending[asker] = (challenge, now)
    return challenge
  }

  /// Whether `answer` is the one for the challenge `asker` was last given. Right or wrong, that
  /// challenge is used up.
  mutating func accepts(_ answer: Data, from asker: UUID, now: Date = Date()) -> Bool {
    guard let (challenge, issuedAt) = pending.removeValue(forKey: asker) else { return false }
    guard now.timeIntervalSince(issuedAt) <= DirectLinkWake.challengeLifetime else { return false }
    let expected = DirectLinkWake.answer(code: code, challenge: challenge)
    guard answer.count == expected.count else { return false }
    // Every byte is compared, so the time taken says nothing about where they differ.
    return zip(answer, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
