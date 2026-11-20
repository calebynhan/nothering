// Prints what macOS itself believes about being online, for scripts/ci/probe-offline-network.sh:
// the network path apps are told about, whether an address on the internet counts as reachable,
// the primary network service and the proxy setting apps get. Run it before and while the stand-in
// network is up.
//   reachability               what macOS believes
//   reachability fetch <url>   fetch the URL the way an app does, following the system's proxy setting
import Foundation
import Network
import SystemConfiguration

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "fetch", let url = URL(string: CommandLine.arguments[2]) {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = 8
  configuration.timeoutIntervalForResource = 8
  let done = DispatchSemaphore(value: 0)
  URLSession(configuration: configuration).dataTask(with: url) { data, response, error in
    if let error = error as NSError? {
      print("fetch failed: \(error.domain) \(error.code) \(error.localizedDescription)")
    } else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let body = String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      print("fetch answered: status \(status), body '\(body)'")
    }
    done.signal()
  }.resume()
  if done.wait(timeout: .now() + 12) == .timedOut {
    print("fetch: no answer in 12 seconds")
  }
  exit(0)
}

let monitor = NWPathMonitor()
let seen = DispatchSemaphore(value: 0)
monitor.pathUpdateHandler = { path in
  print("path status: \(path.status)")
  print("path interfaces: \(path.availableInterfaces.map { "\($0.name) (\($0.type))" })")
  print("path supports IPv4: \(path.supportsIPv4), IPv6: \(path.supportsIPv6), DNS: \(path.supportsDNS)")
  print("path expensive: \(path.isExpensive), constrained: \(path.isConstrained)")
  seen.signal()
}
monitor.start(queue: DispatchQueue(label: "probe"))
if seen.wait(timeout: .now() + 3) == .timedOut {
  print("path: no answer in 3 seconds")
}
monitor.cancel()

// 192.0.2.1 is set aside for documentation: a stand-in for "somewhere on the internet".
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_addr.s_addr = inet_addr("192.0.2.1")
let reachability = withUnsafePointer(to: &address) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SCNetworkReachabilityCreateWithAddress(nil, $0) }
}
var flags = SCNetworkReachabilityFlags()
if let reachability, SCNetworkReachabilityGetFlags(reachability, &flags) {
  print("reachability of an internet address: reachable=\(flags.contains(.reachable)) connectionRequired=\(flags.contains(.connectionRequired)) raw=\(flags.rawValue)")
} else {
  print("reachability: couldn't be read")
}

if let store = SCDynamicStoreCreate(nil, "nothering-probe" as CFString, nil, nil) {
  for key in ["State:/Network/Global/IPv4", "State:/Network/Global/DNS"] {
    let value = SCDynamicStoreCopyValue(store, key as CFString)
    print("\(key): \(value.map { "\($0)" } ?? "none")")
  }
  let services = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
  print("IPv4 services: \(services)")
  // What CFNetwork hands to apps: the primary service's proxies, merged.
  let proxies = SCDynamicStoreCopyProxies(store, nil) as? [String: Any] ?? [:]
  let socks = ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"].map { "\($0)=\(proxies[$0].map { "\($0)" } ?? "none")" }
  print("proxies for apps: \(socks.joined(separator: " "))")
}
