#!/bin/sh
# Nothering's car mode, for the Nothering Mac app as it is released: runs for the logged-in person
# (a launch agent) and waits for the moment the Mac is linked to the iPhone but has no network of
# its own, e.g. in a car with the iPhone on a cable. A Mac on no network tells its apps they are
# offline, so nothing tries to connect and there is nothing to send through the iPhone. While that
# lasts, the helper gives the Mac a stand-in network, see offline-network.sh.
#
# The stand-in also carries the system's proxy setting, pointed at the Mac app's link to the
# iPhone. The app's extension is what captures every connection, but it may not start on a Mac
# that had no network when it was switched on. With the setting, browsers and most apps get
# through either way.
#
# The command-line tool does the same for itself, so this is not needed with it.
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

HELPER=/Library/PrivilegedHelperTools/nothering-offline-network
# The helper's network, as the system's network state names it, and the interface it is on.
SERVICE=NOTHERING-OFFLINE
NEAR=feth5478
# Where the Mac app serves its link to the iPhone, for its own extension.
PORT=11080

# The Mac app answers a SOCKS5 greeting there only once its link to the iPhone's proxy is up.
linked() {
  reply=$(printf '\005\001\000' | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$reply" = "0500" ]
}

# The service the Mac is on for IPv4 or IPv6, as the system's network state names it. Empty when
# it is on none.
primary_service() {
  echo "show State:/Network/Global/$1" | scutil | awk '$1 == "PrimaryService" { print $3 }'
}

# The Mac has a way out of its own: a service other than the stand-in is the one it is on. The
# helper asks the same, so the two never disagree about bringing the stand-in up. A service with
# no router never is the one, e.g. a tunnel that only takes its own addresses.
has_network() {
  primary=$(primary_service IPv4)
  if [ -n "$primary" ] && [ "$primary" != "$SERVICE" ]; then
    return 0
  fi
  [ -n "$(primary_service IPv6)" ]
}

standin_up() {
  ifconfig "$NEAR" >/dev/null 2>&1
}

while :; do
  # A Mac with a network of its own needs nothing, and the iPhone isn't even asked: each question
  # is a connection on its proxy. The helper takes the stand-in down itself when a network appears.
  if ! has_network; then
    if linked; then
      if ! standin_up; then
        # For as long as this watcher lives.
        sudo -n "$HELPER" up $$ "$PORT" >/dev/null 2>&1
      fi
    elif standin_up; then
      # Without the iPhone the stand-in leads nowhere, and the Mac shouldn't think otherwise.
      sudo -n "$HELPER" down >/dev/null 2>&1
    fi
  fi
  sleep "${NOTHERING_CAR_WATCH_INTERVAL:-5}"
done
