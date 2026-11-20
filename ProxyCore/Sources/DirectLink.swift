import CryptoKit
import Foundation
import Network
import Security

/// The direct Wi-Fi link: the Mac reaches the phone over Apple's device-to-device Wi-Fi, the one
/// AirDrop uses, with no Personal Hotspot, no shared network and no cable.
///
/// The phone advertises a Bonjour service while its proxy runs, and the Mac connects to it. Nothing
/// else protects that connection (there is no Wi-Fi password and anyone in radio range can find the
/// service), so it runs over TLS with a key both sides derive from the pairing code, see
/// `DirectLinkCode`. A Mac with another code can't complete the handshake.
///
/// The one connection then carries every proxied connection as a stream, see `Mux`.
enum DirectLink {
  /// What the phone advertises and the Mac browses for.
  static let serviceType = "_nothering._tcp"

  /// The name the phone gives its service, made from the pairing code. A Mac picks its own phone out
  /// of several by it, and a Mac with another code can tell it isn't meant without trying. It also
  /// keeps the phone's own name, like "Anna's iPhone", off the air.
  static func serviceName(code: String) -> String {
    let key = SymmetricKey(data: Data(DirectLinkCode.normalized(code).utf8))
    let tag = HMAC<SHA256>.authenticationCode(for: Data("nothering service 1".utf8), using: key)
    return tag.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  /// The ways the connection may be encrypted, both keyed by the pairing code.
  enum CipherSuite: UInt16, CaseIterable {
    /// Adds a key exchange of its own, so what was recorded stays unreadable to someone who gets
    /// hold of the code later. `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`.
    case forwardSecret = 0xCCAC
    /// The one Apple's own sample uses. `TLS_PSK_WITH_AES_128_GCM_SHA256`.
    case plain = 0x00A8
  }

  /// For the connection itself, on both sides. Both sides offer `suites` in that order and settle
  /// on the first they share. Only tests name them.
  static func parameters(code: String, suites: [CipherSuite] = CipherSuite.allCases) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    // The mux writes whole frames, so waiting to fill a segment only adds delay.
    tcp.noDelay = true
    // A phone that walked away says nothing. Probes notice within about ten seconds.
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 5
    tcp.keepaliveInterval = 2
    tcp.keepaliveCount = 3
    let parameters = NWParameters(tls: tlsOptions(code: code, suites: suites), tcp: tcp)
    restrictToTheRoom(parameters)
    return parameters
  }

  /// For a pairing attempt, which runs before the two sides share a key, see `DirectLinkPairing`.
  static var pairingParameters: NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    restrictToTheRoom(parameters)
    return parameters
  }

  /// The services are for a Mac in the same room: over device-to-device Wi-Fi or the same network,
  /// never for the carrier's network, a device beyond the next router, or a proxy.
  private static func restrictToTheRoom(_ parameters: NWParameters) {
    parameters.includePeerToPeer = true
    parameters.prohibitedInterfaceTypes = [.cellular]
    // For the listening side: only peers on the same link.
    parameters.acceptLocalOnly = true
    // For the connecting side. The Mac's system proxy setting may point at the very forwarder that
    // is waiting for this connection.
    parameters.preferNoProxies = true
  }

  /// For finding the phone. The browse carries no data, so it needs no key.
  static var browseParameters: NWParameters {
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    return parameters
  }

  /// A missing Local Network permission shows up as this DNS-SD error (`kDNSServiceErr_PolicyDenied`).
  static func isLocalNetworkDenied(_ error: NWError) -> Bool {
    if case let .dns(code) = error { return code == -65570 }
    return false
  }

  private static func tlsOptions(code: String, suites: [CipherSuite]) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let key = SymmetricKey(data: Data(DirectLinkCode.normalized(code).utf8))
    let secret = Data(HMAC<SHA256>.authenticationCode(for: Data("nothering direct link 1".utf8), using: key))
    sec_protocol_options_add_pre_shared_key(
      options.securityProtocolOptions,
      dispatchData(secret),
      dispatchData(Data("nothering".utf8))
    )
    for suite in suites {
      // By number: the type that takes it only names the suites that go with certificates.
      sec_protocol_options_append_tls_ciphersuite(
        options.securityProtocolOptions,
        tls_ciphersuite_t(rawValue: suite.rawValue)!
      )
    }
    return options
  }

  private static func dispatchData(_ data: Data) -> __DispatchData {
    data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
  }
}
