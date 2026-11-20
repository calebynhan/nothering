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
      near.read(minimum: phoneReply, maximum: phoneReply) { _, _, _ in
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
      near.read(minimum: phoneReply, maximum: phoneReply) { _, _, _ in
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
    let phoneNonce = Data(repeating: 3, count: DirectLinkPairing.nonceSize)
    queue.async {
      requester.start()
      far.read(minimum: helloWithName, maximum: helloWithName) { _, _, _ in
        far.write(phoneKey + DirectLinkPairing.commitment(nonce: phoneNonce)) { _ in }
        far.read(minimum: macReveal, maximum: macReveal) { _, _, _ in
          let junk = Data(repeating: 0x5A, count: 40)
          far.write(phoneNonce + Data([1, 0, UInt8(junk.count)]) + junk) { _ in }
        }
      }
    }
    await waitUntil(on: queue) { !results.value.isEmpty }
    #expect(await onQueue(queue) { results.value } == [.failure(.failed)])
  }

  /// The phone committed to its nonce before it saw the Mac's key. Another one afterwards could
  /// have been picked to steer the number, so the Mac shows no number for it.
  @Test func aNonceOtherThanTheOneThePhoneCommittedToFails() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let shown = Box<[String]>([])
    let results = Box<[Result<String, DirectLinkPairingError>]>([])
    let requester = PairingRequester(
      transport: near, queue: queue, name: "Test Mac",
      onDigits: { shown.value.append($0) },
      completion: { results.value.append($0) }
    )
    let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let committed = Data(repeating: 3, count: DirectLinkPairing.nonceSize)
    let sent = Data(repeating: 4, count: DirectLinkPairing.nonceSize)
    queue.async {
      requester.start()
      far.read(minimum: helloWithName, maximum: helloWithName) { _, _, _ in
        far.write(phoneKey + DirectLinkPairing.commitment(nonce: committed)) { _ in }
        far.read(minimum: macReveal, maximum: macReveal) { _, _, _ in
          far.write(sent) { _ in }
        }
      }
    }
    await waitUntil(on: queue) { !results.value.isEmpty }
    #expect(await onQueue(queue) { results.value } == [.failure(.failed)])
    #expect(await onQueue(queue) { shown.value.isEmpty })
  }

  /// What the number hangs on leaves the phone only once its question is on the screen. Before
  /// that a Mac could work the number out, drop the attempt unseen, and try for a better one.
  @Test func thePhoneGivesItsNonceOnlyOnceItAsks() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let asked = Box(0)
    let askedWhenTheNonceCame = Box<Int?>(nil)
    let kept = Box(false)
    let responder = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      ask: { _ in asked.value += 1 },
      onEnd: { _ in }
    )
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let nonce = Data(repeating: 7, count: DirectLinkPairing.nonceSize)
    queue.async {
      responder.start()
      near.write(Data([DirectLinkPairing.version]) + DirectLinkPairing.commitment(publicKey: key, nonce: nonce) + Data([0])) { _ in }
      near.read(minimum: phoneReply, maximum: phoneReply) { reply, _, _ in
        let commitment = Data((reply ?? Data()).suffix(DirectLinkPairing.commitmentSize))
        near.write(key + nonce) { _ in }
        near.read(minimum: DirectLinkPairing.nonceSize, maximum: DirectLinkPairing.nonceSize) { phoneNonce, _, _ in
          askedWhenTheNonceCame.value = asked.value
          kept.value = DirectLinkPairing.commitment(nonce: Data(phoneNonce ?? Data())) == commitment
        }
      }
    }
    await waitUntil(on: queue) { askedWhenTheNonceCame.value != nil }
    #expect(await onQueue(queue) { askedWhenTheNonceCame.value } == 1)
    #expect(await onQueue(queue) { kept.value })
    queue.async { responder.cancel() }
  }

  /// A request that is turned away before it is asked, e.g. while another question is open, never
  /// gets what the number hangs on.
  @Test func aRequestThatIsNotPutToThePersonLearnsNothing() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let responder = Box<PairingResponder?>(nil)
    let ends = Box<[PairingResponder.Ending]>([])
    let afterReveal = Box<(data: Data?, isOver: Bool)?>(nil)
    responder.value = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      // What the listener does with a request it can't put to the person.
      ask: { _ in responder.value?.cancel() },
      onEnd: { ends.value.append($0) }
    )
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let nonce = Data(repeating: 7, count: DirectLinkPairing.nonceSize)
    queue.async {
      responder.value?.start()
      near.write(Data([DirectLinkPairing.version]) + DirectLinkPairing.commitment(publicKey: key, nonce: nonce) + Data([0])) { _ in }
      near.read(minimum: phoneReply, maximum: phoneReply) { _, _, _ in
        near.write(key + nonce) { _ in }
        near.read(minimum: 1, maximum: DirectLinkPairing.nonceSize) { data, isComplete, error in
          afterReveal.value = (data, isComplete || error != nil)
        }
      }
    }
    await waitUntil(on: queue) { afterReveal.value != nil }
    #expect(await onQueue(queue) { afterReveal.value?.data } == nil)
    #expect(await onQueue(queue) { afterReveal.value?.isOver } == true)
    #expect(await onQueue(queue) { ends.value } == [.leftAsking])
  }

  /// A question nobody answers counts as a no, for the Mac and for whoever takes it off the screen.
  @Test func aQuestionNobodyAnswersIsRefusedInTime() async {
    let pairing = Pairing(code: "K7QM-2XBD-9RTH-W4PN-6CEA", name: "Test Mac", answerTimeout: 0.1)
    _ = await pairing.request()
    #expect(await pairing.result() == .failure(.refused))
    #expect(await pairing.ends() == [.refused])
  }

  /// The Mac's name is part of what the number is made from, so it can't be changed on the way
  /// to the phone without the numbers coming apart.
  @Test func aNameChangedOnTheWayChangesTheNumber() async {
    let queue = DispatchQueue(label: "DirectLinkPairingTests")
    let (near, toInBetween) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let (fromInBetween, far) = PipeEnd.pair(queue: queue, pieceSize: 1500)
    let onTheMac = Box<[String]>([])
    let onThePhone = Box<[String]>([])
    let requester = PairingRequester(
      transport: near, queue: queue, name: "Test Mac",
      onDigits: { onTheMac.value.append($0) },
      completion: { _ in }
    )
    let responder = PairingResponder(
      transport: far, queue: queue, code: "K7QM-2XBD-9RTH-W4PN-6CEA",
      ask: { onThePhone.value.append($0.digits) },
      onEnd: { _ in }
    )
    queue.async {
      responder.start()
      requester.start()
      // Passes everything on untouched, except one letter of the name.
      toInBetween.read(minimum: helloWithName, maximum: helloWithName) { hello, _, _ in
        var changed = Data(hello ?? Data())
        changed[changed.count - 1] ^= 0x01
        fromInBetween.write(changed) { _ in }
        fromInBetween.read(minimum: phoneReply, maximum: phoneReply) { reply, _, _ in
          toInBetween.write(Data(reply ?? Data())) { _ in }
          toInBetween.read(minimum: macReveal, maximum: macReveal) { reveal, _, _ in
            fromInBetween.write(Data(reveal ?? Data())) { _ in }
            fromInBetween.read(minimum: DirectLinkPairing.nonceSize, maximum: DirectLinkPairing.nonceSize) { phoneNonce, _, _ in
              toInBetween.write(Data(phoneNonce ?? Data())) { _ in }
            }
          }
        }
      }
    }
    await waitUntil(on: queue) { !onTheMac.value.isEmpty && !onThePhone.value.isEmpty }
    #expect(await onQueue(queue) { onTheMac.value[0] != onThePhone.value[0] })
    queue.async {
      responder.cancel()
      requester.cancel()
    }
  }

  @Test(arguments: [
    ("Test Mac", "Test Mac"),
    ("  Test\nMac\u{07} ", "TestMac"),
    ("", "A Mac"),
    ("\u{200B}\n", "A Mac"),
    // Separators that would start a line of their own in the alert, and a mark that turns text around.
    ("Mac\u{2028}Tap Allow", "MacTap Allow"),
    ("Mac\u{2029}Tap Allow", "MacTap Allow"),
    ("Mac\u{202E}wollA", "MacwollA"),
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

/// The sizes of the messages, for the tests that play one side by hand: the Mac's hello with the
/// name "Test Mac", the phone's reply to it, and the Mac's reveal.
private let helloWithName = 1 + DirectLinkPairing.commitmentSize + 1 + 8
private let phoneReply = DirectLinkPairing.keySize + DirectLinkPairing.commitmentSize
private let macReveal = DirectLinkPairing.keySize + DirectLinkPairing.nonceSize

/// One attempt between a Mac and a phone over an in-memory connection.
private final class Pairing: @unchecked Sendable {
  let queue = DispatchQueue(label: "DirectLinkPairingTests")
  private(set) var requester: PairingRequester!
  private var responder: PairingResponder!
  private var requests: [DirectLinkPairingRequest] = []
  private var digits: [String] = []
  private(set) var results: [Result<String, DirectLinkPairingError>] = []
  private var ended: [PairingResponder.Ending] = []

  init(code: String, name: String, answerTimeout: TimeInterval = DirectLinkPairing.answerTimeout) {
    // A few bytes at a time, so every message arrives in pieces.
    let (near, far) = PipeEnd.pair(queue: queue, pieceSize: 7)
    // Weakly: an attempt a test leaves unfinished outlives the test, and still ends later, when
    // its own time is up.
    responder = PairingResponder(
      transport: far, queue: queue, code: code, answerTimeout: answerTimeout,
      ask: { [weak self] in self?.requests.append($0) },
      onEnd: { [weak self] in self?.ended.append($0) }
    )
    requester = PairingRequester(
      transport: near, queue: queue, name: name,
      onDigits: { [weak self] in self?.digits.append($0) },
      completion: { [weak self] in self?.results.append($0) }
    )
    queue.sync {
      responder.start()
      requester.start()
    }
  }

  deinit {
    // Ends what the test left open, so nothing of it is still waiting when later tests run.
    queue.async { [requester, responder] in
      requester?.cancel()
      responder?.cancel()
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
