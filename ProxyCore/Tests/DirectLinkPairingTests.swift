import CryptoKit
import Foundation
import Testing
@testable import ProxyCore

@Suite struct DirectLinkPairingTests {
  @Test func allowingGivesTheMacThePhonesCode() async {
    let pairing = Pairing(code: "K7QM-2XBD-9RTH-W4PN-6CEA", name: "Test Mac")
    let request = await pairing.request()
    #expect(request.name == "Test Mac")
    // The person compares this number with the one on the Mac.
    let shown = await pairing.digitsOnTheMac()
    #expect(request.digits == shown)
    #expect(shown.count == 7)
    #expect(shown.filter(\.isNumber).count == 6)

    request.answer(true)
    #expect(await pairing.result() == .success("K7QM-2XBD-9RTH-W4PN-6CEA"))
    #expect(await pairing.ends() == [.allowed])
  }

  @Test func refusingGivesTheMacNothing() async {
    let pairing = Pairing(code: "K7QM-2XBD-9RTH-W4PN-6CEA", name: "Test Mac")
    let request = await pairing.request()
    request.answer(false)
    #expect(await pairing.result() == .failure(.refused))
    #expect(await pairing.ends() == [.refused])
  }

  /// A Mac that gives up takes its question off the phone's screen, and a late tap does nothing.
  @Test func aMacThatLeavesEndsTheQuestion() async {
    let pairing = Pairing(code: "K7QM-2XBD-9RTH-W4PN-6CEA", name: "Test Mac")
    let request = await pairing.request()
    pairing.queue.async { pairing.requester.cancel() }
    #expect(await pairing.ends() == [.leftAsking])
    request.answer(true)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await onQueue(pairing.queue) { pairing.results.isEmpty })
  }

  /// Someone in between holds two attempts, one with each side, and they come out with different
  /// numbers. Seeing that is what the person is asked to check before allowing.
  @Test func someoneInBetweenShowsDifferentNumbers() async {
    let withTheMac = Pairing(code: "AAAA-AAAA-AAAA-AAAA-AAAA", name: "Test Mac")
    let withThePhone = Pairing(code: "K7QM-2XBD-9RTH-W4PN-6CEA", name: "Test Mac")
    let onTheMac = await withTheMac.digitsOnTheMac()
    let onThePhone = await withThePhone.request().digits
    #expect(onTheMac != onThePhone)
  }

  /// The Mac has to reveal the key it committed to at the start. Another one could have been
  /// picked after seeing the phone's, to steer the number.
  @Test func aKeyOtherThanTheCommittedOneIsNeverAsked() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let asked = Box(0)
    let ends = Box<[PairingResponder.Ending]>([])
    let responder = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      ask: { _ in asked.value += 1 },
      onEnd: { ends.value.append($0) }
    )
    let committed = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let revealed = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let nonce = Data(repeating: 7, count: DirectLinkPairing.nonceSize)
    queue.async {
      responder.start()
      near.write(Data([DirectLinkPairing.version]) + DirectLinkPairing.commitment(publicKey: committed, nonce: nonce) + Data([0])) { _ in }
      near.read(minimum: DirectLinkPairing.keySize, maximum: DirectLinkPairing.keySize) { _, _, _ in
        near.write(revealed + nonce) { _ in }
      }
    }
    await waitUntil(on: queue) { !ends.value.isEmpty }
    #expect(await onQueue(queue) { ends.value } == [.notAsked])
    #expect(await onQueue(queue) { asked.value } == 0)
  }

  @Test func theCommittedKeyIsAsked() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let asked = Box<[DirectLinkPairingRequest]>([])
    let responder = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      ask: { asked.value.append($0) },
      onEnd: { _ in }
    )
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let nonce = Data(repeating: 7, count: DirectLinkPairing.nonceSize)
    queue.async {
      responder.start()
      // No name: the phone still has something to call it.
      near.write(Data([DirectLinkPairing.version]) + DirectLinkPairing.commitment(publicKey: key, nonce: nonce) + Data([0])) { _ in }
      near.read(minimum: DirectLinkPairing.keySize, maximum: DirectLinkPairing.keySize) { _, _, _ in
        near.write(key + nonce) { _ in }
      }
    }
    await waitUntil(on: queue) { !asked.value.isEmpty }
    #expect(await onQueue(queue) { asked.value[0].name } == "A Mac")
    queue.async { responder.cancel() }
  }

  @Test func anotherVersionIsTurnedAway() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let asked = Box(0)
    let ends = Box<[PairingResponder.Ending]>([])
    let responder = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      ask: { _ in asked.value += 1 },
      onEnd: { ends.value.append($0) }
    )
    queue.async {
      responder.start()
      near.write(Data([DirectLinkPairing.version + 1]) + Data(repeating: 0, count: DirectLinkPairing.keySize) + Data([0])) { _ in }
    }
    await waitUntil(on: queue) { !ends.value.isEmpty }
    #expect(await onQueue(queue) { ends.value } == [.notAsked])
    #expect(await onQueue(queue) { asked.value } == 0)
  }

  /// A phone that answers with something the Mac can't open hasn't paired it.
  @Test func anAnswerTheMacCannotOpenFails() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let results = Box<[Result<String, DirectLinkPairingError>]>([])
    let requester = PairingRequester(
      transport: near, queue: queue, name: "Test Mac",
      onDigits: { _ in },
      completion: { results.value.append($0) }
    )
    let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    queue.async {
      requester.start()
      // The hello: version, commitment, name length, name.
      far.read(minimum: 1 + DirectLinkPairing.keySize + 1 + 8, maximum: 1 + DirectLinkPairing.keySize + 1 + 8) { _, _, _ in
        far.write(phoneKey) { _ in }
        far.read(minimum: DirectLinkPairing.keySize + DirectLinkPairing.nonceSize, maximum: DirectLinkPairing.keySize + DirectLinkPairing.nonceSize) { _, _, _ in
          let junk = Data(repeating: 0x5A, count: 40)
          far.write(Data([1, 0, UInt8(junk.count)]) + junk) { _ in }
        }
      }
    }
    await waitUntil(on: queue) { !results.value.isEmpty }
    #expect(await onQueue(queue) { results.value } == [.failure(.failed)])
  }

  @Test(arguments: [
    ("Test Mac", "Test Mac"),
    ("  Test\nMac\u{07} ", "TestMac"),
    ("", "A Mac"),
    ("\u{200B}\n", "A Mac"),
  ])
  func namesAreMadeSafeToShow(sent: String, shown: String) {
    #expect(DirectLinkPairing.displayName(Data(sent.utf8)) == shown)
  }

  /// A name cut at the length limit in the middle of a character still shows.
  @Test func aNameCutMidCharacterStillShows() {
    let cut = Data("Mac 😀".utf8.dropLast(2))
    #expect(DirectLinkPairing.displayName(cut) == "Mac")
  }
}

/// One attempt between a Mac and a phone over an in-memory connection.
private final class Pairing: @unchecked Sendable {
  let queue = DispatchQueue(label: "DirectLinkPairingTests")
  private(set) var requester: PairingRequester!
  private var responder: PairingResponder!
  private var requests: [DirectLinkPairingRequest] = []
  private var digits: [String] = []
  private(set) var results: [Result<String, DirectLinkPairingError>] = []
  private var ended: [PairingResponder.Ending] = []

  init(code: String, name: String) {
    // A few bytes at a time, so every message arrives in pieces.
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 7)
    responder = PairingResponder(
      transport: far, queue: queue, code: code,
      ask: { [unowned self] in requests.append($0) },
      onEnd: { [unowned self] in ended.append($0) }
    )
    requester = PairingRequester(
      transport: near, queue: queue, name: name,
      onDigits: { [unowned self] in digits.append($0) },
      completion: { [unowned self] in results.append($0) }
    )
    queue.sync {
      responder.start()
      requester.start()
    }
  }

  /// What the phone asks its person.
  func request() async -> DirectLinkPairingRequest {
    await waitUntil(on: queue) { [self] in !requests.isEmpty }
    return await onQueue(queue) { [self] in requests[0] }
  }

  func digitsOnTheMac() async -> String {
    await waitUntil(on: queue) { [self] in !digits.isEmpty }
    return await onQueue(queue) { [self] in digits[0] }
  }

  func result() async -> Result<String, DirectLinkPairingError> {
    await waitUntil(on: queue) { [self] in !results.isEmpty }
    return await onQueue(queue) { [self] in results[0] }
  }

  /// How the phone's side ended, for each time it did.
  func ends() async -> [PairingResponder.Ending] {
    await waitUntil(on: queue) { [self] in !ended.isEmpty }
    return await onQueue(queue) { [self] in ended }
  }
}
