import CryptoKit
import Foundation

/// Why a pairing attempt didn't give the Mac the phone's code.
public enum DirectLinkPairingError: Error, Equatable, Sendable {
  /// The person tapped Don't Allow on the phone, or didn't answer in time.
  case refused
  /// The connection ended, or the other side didn't follow the protocol.
  case failed
}

/// What the phone asks its user when a Mac wants to pair.
public struct DirectLinkPairingRequest: Sendable {
  /// The Mac's name, as the Mac gave it.
  public let name: String
  /// The number the Mac shows too, like `482 913`. A different one there means someone is in between.
  public let digits: String
  /// Call once with the person's answer, from any thread.
  public let answer: @Sendable (Bool) -> Void
}

/// Pairs a Mac with the phone for the direct Wi-Fi link with nothing to type: the Mac finds the
/// phone, both show the same six digits, and the person taps Allow on the phone and confirms on the
/// Mac. The Mac then has the phone's pairing code (`DirectLinkCode`), as if it had been typed in.
///
/// Both answers are needed. Allow on the phone keeps a stranger's Mac from getting the code. The
/// confirmation on the Mac keeps a stranger's device from answering in the phone's place with a
/// code of its own, after which it would carry all of the Mac's traffic: the phone then shows
/// nothing, which only its person can tell.
///
/// It runs on a plain connection before the two share any secret:
///
///     Mac → phone   version | SHA-256(Mac's key, Mac's nonce) | name length | name
///     phone → Mac   phone's key | SHA-256(phone's nonce)
///     Mac → phone   Mac's key | Mac's nonce
///                   the phone asks its person, showing the digits
///     phone → Mac   phone's nonce
///                   the Mac shows the digits
///     phone → Mac   1 | length (UInt16 BE) | the code, sealed      or      0 when refused
///
/// The keys are X25519 public keys. Their shared secret, with everything said up to there, gives
/// the digits and the key that seals the code, so someone listening learns neither. Someone in
/// between ends up with two different secrets and so two different numbers, which is what the
/// person is asked to compare.
///
/// Neither side can know the number before it is bound to it, or it could drop every attempt
/// whose number doesn't suit it and try again, unseen, until the two match. The Mac commits to its
/// key before it sees the phone's. The phone commits to a nonce, and gives it out only once its
/// question is on the screen: from then on a try costs a question the person sees.
enum DirectLinkPairing {
  /// What the phone advertises for pairing, next to `DirectLink.serviceType` for the link itself.
  static let serviceType = "_nothering-pair._tcp"
  static let version: UInt8 = 1
  static let keySize = 32
  static let nonceSize = 16
  static let maxNameBytes = 64
  /// How long the phone waits for its person to answer, and the Mac for the phone.
  static let answerTimeout: TimeInterval = 60
  /// How long the phone keeps the connection after its answer, for the Mac to read it.
  static let lingerTimeout: TimeInterval = 5

  static let commitmentSize = 32

  static func commitment(publicKey: Data, nonce: Data) -> Data {
    Data(SHA256.hash(data: publicKey + nonce))
  }

  /// What the phone sends in place of its nonce until its question is on the screen.
  static func commitment(nonce: Data) -> Data {
    Data(SHA256.hash(data: nonce))
  }

  static func randomNonce() -> Data {
    Data((0..<nonceSize).map { _ in UInt8.random(in: .min ... .max) })
  }

  /// The digits both sides show, and the key that seals the code, from the secret the two keys
  /// give and `transcript`: every byte the two sent each other up to there, in order, so that
  /// nothing of it can be changed on the way without changing the number.
  static func secrets(shared: SharedSecret, transcript: Data) -> (digits: String, seal: SymmetricKey) {
    let salt = Data(SHA256.hash(data: Data("nothering pair 1".utf8) + transcript))
    let digitsKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("digits".utf8), outputByteCount: 4)
    let number = digitsKey.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } % 1_000_000
    let text = String(number)
    let padded = String(repeating: "0", count: 6 - text.count) + text
    let seal = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("code".utf8), outputByteCount: 32)
    return ("\(padded.prefix(3)) \(padded.suffix(3))", seal)
  }

  /// A name from the other side, safe to put in an alert: one line, nothing invisible.
  static func displayName(_ bytes: Data) -> String {
    let name = String(decoding: bytes, as: UTF8.self)
      .unicodeScalars.filter { scalar in
        let category = scalar.properties.generalCategory
        return !scalar.properties.isDefaultIgnorableCodePoint && scalar != "\u{FFFD}"
          && category != .control && category != .format
          && category != .lineSeparator && category != .paragraphSeparator
      }
      .map(String.init).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "A Mac" : name
  }
}

/// The Mac's side of one pairing attempt. Everything runs on `queue`, the transport's.
final class PairingRequester {
  private let transport: ByteStream
  private let queue: DispatchQueue
  private let name: String
  private let onDigits: (String) -> Void
  private let completion: (Result<String, DirectLinkPairingError>) -> Void
  private let privateKey = Curve25519.KeyAgreement.PrivateKey()
  private let nonce = DirectLinkPairing.randomNonce()
  private var isDone = false

  /// `onDigits` gets the number to show while the phone asks. `completion` gets the phone's code.
  init(
    transport: ByteStream,
    queue: DispatchQueue,
    name: String,
    onDigits: @escaping (String) -> Void,
    completion: @escaping (Result<String, DirectLinkPairingError>) -> Void
  ) {
    self.transport = transport
    self.queue = queue
    self.name = name
    self.onDigits = onDigits
    self.completion = completion
  }

  func start() {
    let publicKey = privateKey.publicKey.rawRepresentation
    let nameBytes = Data(name.utf8.prefix(DirectLinkPairing.maxNameBytes))
    let hello = Data([DirectLinkPairing.version])
      + DirectLinkPairing.commitment(publicKey: publicKey, nonce: nonce)
      + Data([UInt8(nameBytes.count)]) + nameBytes
    write(hello)
    read(DirectLinkPairing.keySize + DirectLinkPairing.commitmentSize) { [self] reply in
      let phoneKey = Data(reply.prefix(DirectLinkPairing.keySize))
      let phoneCommitment = Data(reply.suffix(DirectLinkPairing.commitmentSize))
      guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey),
            let shared = try? privateKey.sharedSecretFromKeyAgreement(with: key)
      else { return finish(.failure(.failed)) }
      write(publicKey + nonce)
      // The phone sends this once its question is up. Until then nobody knows the number.
      read(DirectLinkPairing.nonceSize) { [self] phoneNonce in
        guard DirectLinkPairing.commitment(nonce: phoneNonce) == phoneCommitment else {
          return finish(.failure(.failed))
        }
        let transcript = hello + phoneKey + phoneCommitment + publicKey + nonce + phoneNonce
        let secrets = DirectLinkPairing.secrets(shared: shared, transcript: transcript)
        onDigits(secrets.digits)
        readAnswer(seal: secrets.seal)
      }
    }
    queue.asyncAfter(deadline: .now() + DirectLinkPairing.answerTimeout + DirectLinkPairing.lingerTimeout) { [weak self] in
      self?.finish(.failure(.failed))
    }
  }

  /// Gives up without calling `completion`.
  func cancel() {
    guard !isDone else { return }
    isDone = true
    transport.cancel()
  }

  private func readAnswer(seal: SymmetricKey) {
    read(1) { [self] status in
      guard status[0] == 1 else { return finish(.failure(.refused)) }
      read(2) { [self] length in
        let count = Int(length[0]) << 8 | Int(length[1])
        guard count > 0, count <= 256 else { return finish(.failure(.failed)) }
        read(count) { [self] sealed in
          guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
                let plain = try? ChaChaPoly.open(box, using: seal),
                let code = String(data: plain, encoding: .utf8), DirectLinkCode.isValid(code)
          else { return finish(.failure(.failed)) }
          finish(.success(DirectLinkCode.format(code)))
        }
      }
    }
  }

  private func write(_ data: Data) {
    transport.write(data) { [weak self] error in
      if error != nil { self?.finish(.failure(.failed)) }
    }
  }

  private func read(_ count: Int, _ body: @escaping (Data) -> Void) {
    transport.read(minimum: count, maximum: count) { [weak self] data, _, _ in
      guard let self, !isDone else { return }
      guard let data, data.count == count else { return finish(.failure(.failed)) }
      body(Data(data))
    }
  }

  private func finish(_ result: Result<String, DirectLinkPairingError>) {
    guard !isDone else { return }
    isDone = true
    transport.cancel()
    completion(result)
  }
}

/// The phone's side of one pairing attempt. Everything runs on `queue`, the transport's.
final class PairingResponder: @unchecked Sendable {
  /// How an attempt ended.
  enum Ending: Equatable {
    /// The person was never asked: the Mac left first, or didn't follow the protocol.
    case notAsked
    /// The Mac left while the question was open, so it has to come off the screen.
    case leftAsking
    /// The person said no, or didn't answer in time.
    case refused
    /// The person allowed it, and the code went out.
    case allowed
  }

  private let transport: ByteStream
  private let queue: DispatchQueue
  private let code: String
  private let ask: (DirectLinkPairingRequest) -> Void
  private let onEnd: (Ending) -> Void
  private let answerTimeout: TimeInterval
  private let privateKey = Curve25519.KeyAgreement.PrivateKey()
  private let nonce = DirectLinkPairing.randomNonce()
  private var isAsking = false
  private var answered: Ending?
  private var isDone = false

  /// `ask` puts the question to the person. `onEnd` is called once when the attempt is over.
  init(
    transport: ByteStream,
    queue: DispatchQueue,
    code: String,
    answerTimeout: TimeInterval = DirectLinkPairing.answerTimeout,
    ask: @escaping (DirectLinkPairingRequest) -> Void,
    onEnd: @escaping (Ending) -> Void
  ) {
    self.transport = transport
    self.queue = queue
    self.code = code
    self.answerTimeout = answerTimeout
    self.ask = ask
    self.onEnd = onEnd
  }

  func start() {
    read(1 + DirectLinkPairing.keySize + 1) { [self] hello in
      let commitment = Data(hello[1..<1 + DirectLinkPairing.keySize])
      let nameLength = Int(hello[1 + DirectLinkPairing.keySize])
      guard hello[0] == DirectLinkPairing.version, nameLength <= DirectLinkPairing.maxNameBytes else { return end() }
      read(nameLength) { [self] nameBytes in
        let publicKey = privateKey.publicKey.rawRepresentation
        let ownCommitment = DirectLinkPairing.commitment(nonce: nonce)
        write(publicKey + ownCommitment)
        read(DirectLinkPairing.keySize + DirectLinkPairing.nonceSize) { [self] reveal in
          let macKey = Data(reveal.prefix(DirectLinkPairing.keySize))
          let macNonce = Data(reveal.suffix(DirectLinkPairing.nonceSize))
          // The key has to be the one the Mac committed to before it saw this side's.
          guard DirectLinkPairing.commitment(publicKey: macKey, nonce: macNonce) == commitment,
                let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
                let shared = try? privateKey.sharedSecretFromKeyAgreement(with: key)
          else { return end() }
          let transcript = hello + nameBytes + publicKey + ownCommitment + macKey + macNonce + nonce
          let secrets = DirectLinkPairing.secrets(shared: shared, transcript: transcript)
          question(name: DirectLinkPairing.displayName(nameBytes), digits: secrets.digits, seal: secrets.seal)
          // Only an attempt whose question is on the screen gets what the number hangs on.
          if isAsking, !isDone { write(nonce) }
        }
      }
    }
  }

  func cancel() {
    end()
  }

  private func question(name: String, digits: String, seal: SymmetricKey) {
    isAsking = true
    // The Mac sends nothing more, so anything read now means it went away.
    transport.read(minimum: 1, maximum: 1) { [weak self] _, _, _ in self?.end() }
    queue.asyncAfter(deadline: .now() + answerTimeout) { [weak self] in
      self?.answer(false, seal: seal)
    }
    ask(DirectLinkPairingRequest(name: name, digits: digits) { [weak self] allowed in
      guard let self else { return }
      queue.async { self.answer(allowed, seal: seal) }
    })
  }

  private func answer(_ allowed: Bool, seal: SymmetricKey) {
    guard isAsking, !isDone else { return }
    isAsking = false
    answered = .refused
    var reply = Data([0])
    if allowed, let sealed = try? ChaChaPoly.seal(Data(DirectLinkCode.normalized(code).utf8), using: seal).combined {
      reply = Data([1, UInt8(sealed.count >> 8), UInt8(sealed.count & 0xFF)]) + sealed
      answered = .allowed
    }
    transport.write(reply) { [weak self] _ in
      guard let self else { return }
      // The Mac closes once it has read the answer, which ends this. Not forever, though.
      queue.asyncAfter(deadline: .now() + DirectLinkPairing.lingerTimeout) { [weak self] in self?.end() }
    }
  }

  private func write(_ data: Data) {
    transport.write(data) { [weak self] error in
      if error != nil { self?.end() }
    }
  }

  private func read(_ count: Int, _ body: @escaping (Data) -> Void) {
    guard count > 0 else { return body(Data()) }
    transport.read(minimum: count, maximum: count) { [weak self] data, _, _ in
      guard let self, !isDone else { return }
      guard let data, data.count == count else { return end() }
      body(Data(data))
    }
  }

  private func end() {
    guard !isDone else { return }
    isDone = true
    let ending = answered ?? (isAsking ? .leftAsking : .notAsked)
    isAsking = false
    transport.cancel()
    onEnd(ending)
  }
}
