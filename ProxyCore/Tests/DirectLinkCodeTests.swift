import Foundation
import Testing
@testable import ProxyCore

@Suite struct DirectLinkCodeTests {
  @Test func generatesValidCodesThatDiffer() {
    let codes = (0..<50).map { _ in DirectLinkCode.generate() }
    for code in codes {
      #expect(DirectLinkCode.isValid(code))
      // Five groups of four, as shown on the phone.
      #expect(code.split(separator: "-").map(\.count) == [4, 4, 4, 4, 4])
    }
    #expect(Set(codes).count == codes.count)
  }

  /// However it is typed on the Mac, it has to give the key the phone derived.
  @Test(arguments: [
    "K7QM-2XBD-9RTH-W4PN-6CEA", "k7qm-2xbd-9rth-w4pn-6cea", "K7QM2XBD9RTHW4PN6CEA", " k7qm 2xbd 9rth w4pn 6cea\n",
    "K7QM–2XBD–9RTH–W4PN–6CEA",
  ])
  func normalizesHowTheCodeIsTyped(typed: String) {
    #expect(DirectLinkCode.normalized(typed) == "K7QM2XBD9RTHW4PN6CEA")
    #expect(DirectLinkCode.isValid(typed))
    #expect(DirectLinkCode.format(typed) == "K7QM-2XBD-9RTH-W4PN-6CEA")
  }

  @Test(arguments: [
    "", "K7QM-2XBD", "K7QM-2XBD-9RTH", "K7QM-2XBD-9RTH-W4PN-6CEA-AAAA", "K7QM-2XBD-9RTH-W4PN-6CE0", "K7QM-2XBD-9RTH-W4PN-6CEI",
  ])
  func rejectsCodesOfTheWrongLengthOrAlphabet(typed: String) {
    #expect(!DirectLinkCode.isValid(typed))
  }

  /// Enough that guesses can't all be tried, even at home against something overheard.
  @Test func isLongEnoughNotToBeGuessed() {
    #expect(DirectLinkCode.length * 5 >= 100)
  }
}
