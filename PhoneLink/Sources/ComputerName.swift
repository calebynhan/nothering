import Foundation
import SystemConfiguration

/// This Mac's name as its person set it, e.g. "Ada's MacBook Air", for the iPhone to show when the
/// Mac asks to be paired. Read from the system's settings: asking for the host's names instead can
/// wait on the network, and a Mac that pairs over the direct link often has none.
public func computerName() -> String {
  (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}
