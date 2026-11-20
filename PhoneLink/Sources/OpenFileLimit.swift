import Darwin

/// Lets the process hold as many open files as macOS allows it. A process starts with room for
/// 256, and each connection forwarded to the phone takes two of them, three over the direct link.
/// With a browser and everything else on the Mac going through, that is reached.
public func raiseOpenFileLimit() {
  var limit = rlimit()
  guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
  // macOS refuses a limit above OPEN_MAX, also where the hard limit says there is none.
  let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
  guard limit.rlim_cur < wanted else { return }
  limit.rlim_cur = wanted
  setrlimit(RLIMIT_NOFILE, &limit)
}
