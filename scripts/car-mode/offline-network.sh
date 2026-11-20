#!/bin/sh
# Nothering's stand-in network, see OfflineNetwork.swift. Installed by `nothering --install-helper`
# and run as root through sudo.
#
#   up <pid> [<port>]   bring it up, and take it down again when process <pid> ends or a real
#                       network appears. With <port>, the Mac's apps are also told to use the SOCKS
#                       proxy on 127.0.0.1:<port>, as long as it is up
#   down                take it down
#   status              say whether it is up
#   expire <pid>        what its own watcher ends with: down, if it is still up for process <pid>
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

NEAR=feth5478
FAR=feth5479
SERVICE=NOTHERING-OFFLINE
# From the range set aside for testing, so no real network is shadowed.
ADDRESS=198.18.0.2
ROUTER=198.18.0.1
OWNER_FILE=/var/run/nothering-offline-network.owner
WATCHER_FILE=/var/run/nothering-offline-network.watcher
LOCK_FILE=/var/run/nothering-offline-network.lock

# One change at a time. Two "up"s at once each take down what the other is putting up, and both
# leave a watcher behind. So whatever changes the stand-in runs once more under lockf, which waits
# its turn. The lock stays with lockf: neither this script nor the watcher it leaves holds it. A
# system without lockf goes without.
case "${1:-}" in
  up | down | expire)
    if [ "${NOTHERING_OFFLINE_LOCKED:-}" != 1 ] && command -v lockf >/dev/null 2>&1; then
      NOTHERING_OFFLINE_LOCKED=1
      export NOTHERING_OFFLINE_LOCKED
      # Root's alone: whoever can open the lock file can hold the lock.
      umask 077
      exec lockf -k -t 30 "$LOCK_FILE" /bin/sh "$0" "$@"
    fi
    ;;
esac
umask 022

# The service the Mac is on for IPv4 or IPv6, as the system's network state names it. Empty when
# it is on none.
primary_service() {
  echo "show State:/Network/Global/$1" | scutil | awk '$1 == "PrimaryService" { print $3 }'
}

# The Mac has a way out of its own: a service other than the stand-in is the one it is on. A
# service with no router never is, e.g. a tunnel that only takes its own addresses, so a Mac on
# nothing but those still gets the stand-in. The stand-in has no IPv6, so a service the Mac is on
# for IPv6 is always another one. OfflineNetwork.macHasNetwork() asks the same.
other_network() {
  primary=$(primary_service IPv4)
  if [ -n "$primary" ] && [ "$primary" != "$SERVICE" ]; then
    return 0
  fi
  [ -n "$(primary_service IPv6)" ]
}

is_up() {
  ifconfig "$NEAR" >/dev/null 2>&1
}

teardown() {
  scutil >/dev/null 2>&1 <<EOF
remove State:/Network/Service/$SERVICE/IPv4
remove State:/Network/Service/$SERVICE/DNS
remove State:/Network/Service/$SERVICE/Proxies
EOF
  # No "route delete default" here: it takes the default route of whatever network the Mac is on
  # by then, whichever router it names. Destroying the interface takes its own routes with it.
  ifconfig "$NEAR" destroy >/dev/null 2>&1
  ifconfig "$FAR" destroy >/dev/null 2>&1
  rm -f "$OWNER_FILE"
}

down() {
  if [ -f "$WATCHER_FILE" ]; then
    watcher=$(cat "$WATCHER_FILE")
    rm -f "$WATCHER_FILE"
    # A watcher that was ended any other way leaves its number behind, and by now the number may
    # be any process's. Only this script is ended. Not with a signal it could be ignoring: what
    # started it may ignore the usual one, and a shell can't take that back.
    case "$watcher" in
      '' | *[!0-9]*) ;;
      *)
        case "$(ps -ww -o command= -p "$watcher" 2>/dev/null)" in
          *"${0##*/}"*) kill -KILL "$watcher" >/dev/null 2>&1 ;;
        esac
        ;;
    esac
  fi
  teardown
}

# What a watcher ends with: down, if the stand-in is still the one it was started for. Not "down"
# itself, which ends the watcher on file, and that is the one asking.
expire() {
  if [ -f "$OWNER_FILE" ] && [ "$(cat "$OWNER_FILE")" = "$1" ]; then
    rm -f "$WATCHER_FILE"
    teardown
  fi
}

up() {
  owner=$1
  proxy_port=$2
  case "$owner" in
    '' | *[!0-9]*)
      echo "up needs the ID of the process to follow" >&2
      exit 64
      ;;
  esac
  # A port and nothing else: it ends up in the system's settings, written by root.
  case "$proxy_port" in
    '' | [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9]) ;;
    6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-2][0-9] | 6553[0-5]) ;;
    *)
      echo "the proxy's port is a number from 1 to 65535" >&2
      exit 64
      ;;
  esac
  if ! kill -0 "$owner" 2>/dev/null; then
    echo "no process $owner" >&2
    exit 64
  fi
  if other_network; then
    echo "this Mac has a network of its own"
    exit 0
  fi
  # Already up for this process: nothing to do, and nothing to interrupt.
  if is_up && [ -f "$OWNER_FILE" ] && [ "$(cat "$OWNER_FILE")" = "$owner" ]; then
    exit 0
  fi
  down
  ifconfig "$NEAR" create || exit 1
  if ! ifconfig "$FAR" create; then
    ifconfig "$NEAR" destroy
    exit 1
  fi
  ifconfig "$NEAR" peer "$FAR"
  ifconfig "$FAR" up
  ifconfig "$NEAR" inet "$ADDRESS" netmask 255.255.255.0 up
  # What tells macOS this is a network: a service with an address, a router and a DNS server.
  scutil >/dev/null <<EOF
d.init
d.add Addresses * $ADDRESS
d.add SubnetMasks * 255.255.255.0
d.add InterfaceName $NEAR
d.add Router $ROUTER
set State:/Network/Service/$SERVICE/IPv4
d.init
d.add ServerAddresses * $ROUTER
set State:/Network/Service/$SERVICE/DNS
EOF
  # Most apps follow the system's proxy setting. On this network it sends them to the forwarder on
  # this Mac, which reaches the iPhone, and it is the forwarder's side that looks names up.
  if [ -n "$proxy_port" ]; then
    scutil >/dev/null <<EOF
d.init
d.add SOCKSEnable # 1
d.add SOCKSProxy 127.0.0.1
d.add SOCKSPort # $proxy_port
d.add ExceptionsList * *.local 169.254/16
set State:/Network/Service/$SERVICE/Proxies
EOF
  fi
  # macOS adds the default route for a service with a router. In case it didn't.
  route -n add default "$ROUTER" >/dev/null 2>&1
  echo "$owner" > "$OWNER_FILE"
  # Takes it all down again without being asked, so a Mac is never left on a network that
  # leads nowhere after the process it was for is gone. It has to outlive what asked for it: a
  # launch agent's end comes with a signal to end for everything the agent started.
  (
    trap '' HUP INT TERM
    while kill -0 "$owner" 2>/dev/null && ! other_network; do
      sleep 2
    done
    # In its turn, like any other change.
    NOTHERING_OFFLINE_LOCKED=
    exec /bin/sh "$0" expire "$owner"
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "$WATCHER_FILE"
}

case "${1:-}" in
  up) up "${2:-}" "${3:-}" ;;
  down) down ;;
  expire) expire "${2:-}" ;;
  status) if is_up; then echo up; else echo down; fi ;;
  *)
    echo "usage: $0 up <pid> [<port>] | down | status" >&2
    exit 64
    ;;
esac
