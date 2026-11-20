import Foundation

/// The pairing code for the direct Wi-Fi link. The phone makes one and shows it. The Mac gets it by
/// pairing (see `DirectLinkPairing`), or the user types it in once. Both sides derive the link's key
/// from it, see `DirectLink`.
public enum DirectLinkCode {
  /// Letters and digits that aren't mistaken for each other when read off a screen: no I, O, 0 or 1.
  private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
  /// 20 symbols of 5 bits each. The code is the only secret of the link and of the wake, and what
  /// goes over the air lets a listener test guesses at home, as fast as their machines go: the
  /// wake's answer, or a recorded handshake. 100 bits is out of reach for that. It is rarely typed,
  /// so it can be this long.
  public static let length = 20

  /// A new random code, grouped for reading, like `K7QM-2XBD-9RTH-W4PN-6CEA`.
  public static func generate() -> String {
    format(String((0..<length).map { _ in alphabet.randomElement()! }))
  }

  /// The code as the key is derived from it: upper case, without the dashes or anything else typed
  /// around it.
  public static func normalized(_ code: String) -> String {
    String(code.uppercased().filter { alphabet.contains($0) })
  }

  public static func isValid(_ code: String) -> Bool {
    normalized(code).count == length
  }

  /// Groups of four with dashes between them.
  public static func format(_ code: String) -> String {
    let symbols = Array(normalized(code))
    return stride(from: 0, to: symbols.count, by: 4)
      .map { String(symbols[$0..<min($0 + 4, symbols.count)]) }
      .joined(separator: "-")
  }
}
