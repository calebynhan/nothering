#!/bin/sh
# Nothering's car mode, for the Nothering Mac app as it is released: runs for the logged-in person
# (a launch agent) and waits for the moment the Mac is linked to the iPhone but has no network of
# its own, e.g. in a car with the iPhone on a cable. A Mac on no network tells its apps they are
# offline, so nothing tries to connect and there is nothing to send through the iPhone. While that
# lasts, the helper gives the Mac a stand-in network, see offline-network.sh.
#
# The command-line tool does the same for itself, so this is not needed with it.
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

HELPER=/Library/PrivilegedHelperTools/nothering-offline-network
# Where the Mac app serves its link to the iPhone, for its own extension.
PORT=11080

# The Mac app answers a SOCKS5 greeting there only once its link to the iPhone's proxy is up.
linked() {
  reply=$(printf '\005\001\000' | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$reply" = "0500" ]
}

default_interface() {
  route -n get "$1" default 2>/dev/null | awk '/interface:/ { print $2 }'
}

# A default route that isn't the helper's. Tunnels and the device-to-device Wi-Fi interfaces have
# IPv6 routes of their own on any Mac, so those don't count.
has_network() {
  case "$(default_interface -inet)" in
    '' | feth*) ;;
    *) return 0 ;;
  esac
  case "$(default_interface -inet6)" in
    '' | utun* | awdl* | llw* | feth*) return 1 ;;
    *) return 0 ;;
  esac
}

standin_up() {
  case "$(default_interface -inet)" in
    feth*) return 0 ;;
    *) return 1 ;;
  esac
}

while :; do
  # A Mac with a network of its own needs nothing, and the iPhone isn't even asked: each question
  # is a connection on its proxy. The helper takes the stand-in down itself when a network appears.
  if ! has_network; then
    if linked; then
      if ! standin_up; then
        # For as long as this watcher lives.
        sudo -n "$HELPER" up $$ >/dev/null 2>&1
      fi
    elif standin_up; then
      # Without the iPhone the stand-in leads nowhere, and the Mac shouldn't think otherwise.
      sudo -n "$HELPER" down >/dev/null 2>&1
    fi
  fi
  sleep "${NOTHERING_CAR_WATCH_INTERVAL:-5}"
done
