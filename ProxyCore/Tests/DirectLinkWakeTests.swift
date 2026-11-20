import Foundation
import Testing
@testable import ProxyCore

@Suite struct DirectLinkWakeTests {
  private let code = "K7QM-2XBD-9RTH-W4PN-6CEA"
  private let mac = UUID()

  @Test func aMacWithTheCodeIsAccepted() {
    var phone = WakeChallenger(code: code)
    let challenge = phone.issue(to: mac)
    #expect(challenge.count == DirectLinkWake.challengeSize)
    // However the code was typed on the Mac.
    let answer = DirectLinkWake.answer(code: "k7qm2xbd9rthw4pn6cea", challenge: challenge)
    #expect(answer.count == DirectLinkWake.answerSize)
    let accepted = phone.accepts(answer, from: mac)
    #expect(accepted)
  }

  @Test func aMacWithAnotherCodeIsRefused() {
    var phone = WakeChallenger(code: code)
    let challenge = phone.issue(to: mac)
    let accepted = phone.accepts(DirectLinkWake.answer(code: "AAAA-AAAA-AAAA-AAAA-AAAA", challenge: challenge), from: mac)
    #expect(!accepted)
  }

  /// Someone who overheard a wake can't repeat it: the challenge is used up, and the next is new.
  @Test func anAnswerWorksOnce() {
    var phone = WakeChallenger(code: code)
    let answer = DirectLinkWake.answer(code: code, challenge: phone.issue(to: mac))
    let first = phone.accepts(answer, from: mac)
    let again = phone.accepts(answer, from: mac)
    _ = phone.issue(to: mac)
    let afterANewChallenge = phone.accepts(answer, from: mac)
    #expect(first)
    #expect(!again)
    #expect(!afterANewChallenge)
  }

  /// A wrong guess uses the challenge up too, so there is one try per challenge.
  @Test func aWrongAnswerUsesTheChallengeUp() {
    var phone = WakeChallenger(code: code)
    let challenge = phone.issue(to: mac)
    let guess = phone.accepts(Data(repeating: 0, count: DirectLinkWake.answerSize), from: mac)
    let rightAnswerAfterwards = phone.accepts(DirectLinkWake.answer(code: code, challenge: challenge), from: mac)
    #expect(!guess)
    #expect(!rightAnswerAfterwards)
  }

  @Test func anAnswerThatComesTooLateIsRefused() {
    var phone = WakeChallenger(code: code)
    let issued = Date(timeIntervalSince1970: 1_000_000)
    let answer = DirectLinkWake.answer(code: code, challenge: phone.issue(to: mac, now: issued))
    let accepted = phone.accepts(answer, from: mac, now: issued.addingTimeInterval(DirectLinkWake.challengeLifetime + 1))
    #expect(!accepted)
  }

  @Test func anAnswerInTimeIsAccepted() {
    var phone = WakeChallenger(code: code)
    let issued = Date(timeIntervalSince1970: 1_000_000)
    let answer = DirectLinkWake.answer(code: code, challenge: phone.issue(to: mac, now: issued))
    let accepted = phone.accepts(answer, from: mac, now: issued.addingTimeInterval(DirectLinkWake.challengeLifetime - 1))
    #expect(accepted)
  }

  @Test func nothingIsAcceptedBeforeAChallenge() {
    var phone = WakeChallenger(code: code)
    let zeros = phone.accepts(Data(repeating: 0, count: DirectLinkWake.answerSize), from: mac)
    let nothing = phone.accepts(Data(), from: mac)
    #expect(!zeros)
    #expect(!nothing)
  }

  @Test func anAnswerOfAnotherLengthIsRefused() {
    var phone = WakeChallenger(code: code)
    let answer = DirectLinkWake.answer(code: code, challenge: phone.issue(to: mac))
    let accepted = phone.accepts(answer + Data([0]), from: mac)
    #expect(!accepted)
  }

  @Test func challengesDiffer() {
    var phone = WakeChallenger(code: code)
    var challenges: Set<Data> = []
    for _ in 0..<20 {
      challenges.insert(phone.issue(to: mac))
    }
    #expect(challenges.count == 20)
  }

  /// Another Mac in range, one that isn't paired, asks between the paired Mac's question and its
  /// answer. That must not cost the paired Mac its wake.
  @Test func anotherMacAskingDoesNotSpoilTheAnswer() {
    var phone = WakeChallenger(code: code)
    let stranger = UUID()
    let challenge = phone.issue(to: mac)
    let strangers = phone.issue(to: stranger)
    let strangerAccepted = phone.accepts(DirectLinkWake.answer(code: "AAAA-AAAA-AAAA-AAAA-AAAA", challenge: strangers), from: stranger)
    let accepted = phone.accepts(DirectLinkWake.answer(code: code, challenge: challenge), from: mac)
    #expect(!strangerAccepted)
    #expect(accepted)
  }

  /// The right answer to a challenge that was given to someone else is no answer.
  @Test func anAnswerOnlyCountsFromTheMacThatWasAsked() {
    var phone = WakeChallenger(code: code)
    let challenge = phone.issue(to: mac)
    let fromAnother = phone.accepts(DirectLinkWake.answer(code: code, challenge: challenge), from: UUID())
    #expect(!fromAnother)
  }

  /// Many devices asking and never answering can't make the phone remember them all, and the ones
  /// that asked last keep their challenges.
  @Test func remembersOnlySoManyAskers() {
    var phone = WakeChallenger(code: code)
    let start = Date(timeIntervalSince1970: 1_000_000)
    let first = phone.issue(to: mac, now: start)
    var last = Data()
    let lastAsker = UUID()
    for index in 1...WakeChallenger.capacity {
      let asker = index == WakeChallenger.capacity ? lastAsker : UUID()
      last = phone.issue(to: asker, now: start.addingTimeInterval(Double(index)))
    }
    let now = start.addingTimeInterval(Double(WakeChallenger.capacity) + 1)
    let oldest = phone.accepts(DirectLinkWake.answer(code: code, challenge: first), from: mac, now: now)
    let newest = phone.accepts(DirectLinkWake.answer(code: code, challenge: last), from: lastAsker, now: now)
    #expect(!oldest)
    #expect(newest)
  }
}
