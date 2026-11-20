#!/bin/bash
# Finds out, on a real Mac, what macOS makes of the stand-in network (scripts/car-mode/
# offline-network.sh): does the machine count as online with it, does it get a default route and a
# DNS server, do programs then try to connect, and do they follow the proxy setting it can carry?
# It takes the machine off its network for about a minute to see, so it runs as a job of its own.
#   scripts/ci/probe-offline-network.sh <output dir>
# Everything it sees goes to <output dir>/probe.txt, and the verdict to <output dir>/summary.txt.
#
# What it can't see is the proxy extension: whether macOS hands it connections and lookups on this
# network takes a signed extension that a person approved.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
log=$out/probe.txt
helper=/Library/PrivilegedHelperTools/nothering-offline-network
port=11080
: > "$log"
: > "$out/summary.txt"

say() {
  echo "$*" | tee -a "$out/summary.txt"
}

default_interface() {
  route -n get default 2>/dev/null | awk '/interface:/ { print $2 }'
}

# How many lines of a file match, 0 when the file isn't there.
count() {
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null)
  echo "${n:-0}"
}

# The probe that asks macOS itself. Built now: there is no network to fetch anything with later.
probe=$out/reachability
if ! swiftc -O "$root/scripts/ci/reachability.swift" -o "$probe" >> "$log" 2>&1; then
  say "reachability.swift didn't compile, going on with the command-line tools only"
  probe=
fi

snapshot() {
  {
    echo
    echo "=================== $1"
    echo "--- route -n get default"; route -n get default 2>&1
    echo "--- route -n get -inet6 default"; route -n get -inet6 default 2>&1
    echo "--- netstat -rn -f inet (top)"; netstat -rn -f inet 2>&1 | head -15
    echo "--- scutil --nwi"; scutil --nwi 2>&1
    echo "--- scutil --dns (top)"; scutil --dns 2>&1 | head -30
    echo "--- scutil --proxy"; scutil --proxy 2>&1
    echo "--- State:/Network/Service/*/IPv4"; echo "list State:/Network/Service/[^/]+/IPv4" | scutil 2>&1
    echo "--- ifconfig feth5478"; ifconfig feth5478 2>&1
    if [[ -n $probe ]]; then
      echo "--- what macOS tells apps"; "$probe" 2>&1
    fi
  } >> "$log"
}

told_apps() {
  [[ -n $probe ]] || { echo "not asked"; return; }
  "$probe" 2>&1 | grep -E '^path status|^reachability|^proxies' | tr '\n' ';'
}

sudo mkdir -p /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$root/scripts/car-mode/offline-network.sh" "$helper"

# A proxy that leads nowhere but says what it was asked for, where the forwarder would be.
socks_log=$out/socks.txt
python3 "$root/scripts/ci/fake-socks.py" "$port" "$socks_log" >> "$log" 2>&1 &
socks=$!
sleep 1
control=$(curl -m 5 -sS --socks5-hostname "127.0.0.1:$port" http://control.nothering-probe.example/ 2>&1)
say "the stand-in proxy, asked directly: '$control'"

snapshot "before: the machine's own network"
interface=$(default_interface)
if [[ -z $interface ]]; then
  say "no default route to begin with, nothing to take away"
  kill "$socks" > /dev/null 2>&1
  exit 1
fi
say "the machine's network is on $interface"

said=$(sudo "$helper" up $$ 2>&1)
say "helper up with a real network: '$said' (it should decline)"

# Whatever goes wrong below, the network comes back by itself.
( sleep 150; sudo ifconfig "$interface" up; sudo "$helper" down ) > /dev/null 2>&1 &
restore=$!

sudo ifconfig "$interface" down
sleep 4
snapshot "the network taken away, no stand-in"
say "without the stand-in, what macOS tells apps: $(told_apps)"
curl -m 3 -sS -o /dev/null http://192.0.2.10/ >> "$log" 2>&1
say "without the stand-in, connecting to an internet address: curl exit $? (7 = didn't even try, 28 = tried and timed out)"
if [[ -n $probe ]]; then
  say "without the stand-in, an app fetching a page: $("$probe" fetch http://plain.nothering-probe.example/ 2>&1)"
fi

# --- The stand-in as the proxy extension uses it: a network, and nothing said about a proxy -------
sudo "$helper" up $$ >> "$log" 2>&1
say "helper up with no network: exit $?"
sleep 4
snapshot "the network taken away, stand-in up"
say "default route with the stand-in: $(default_interface)"
say "DNS servers with the stand-in: $(scutil --dns 2>/dev/null | awk '/nameserver\[/ { print $3 }' | sort -u | tr '\n' ' ')"
say "with the stand-in, what macOS tells apps: $(told_apps)"
# What leaves on the stand-in while programs try: they should be asking for its router.
sudo tcpdump -i feth5478 -n -l > "$out/wire.txt" 2>> "$log" &
capture=$!
sleep 1
curl -m 3 -sS -o /dev/null http://192.0.2.10/ >> "$log" 2>&1
say "with the stand-in, connecting to an internet address: curl exit $? (7 = didn't even try, 28 = tried and timed out)"
curl -m 3 -sS -o /dev/null http://example.com/ >> "$log" 2>&1
say "with the stand-in, connecting to a name: curl exit $? (6 = the name wasn't even looked up for long, 28 = the lookup or connection was tried and timed out)"
# With an answer for "where is the router", the lookup itself gets on the wire and can be seen.
sudo arp -s 198.18.0.1 02:00:5e:00:53:01 ifscope feth5478 >> "$log" 2>&1
dscacheutil -q host -a name lookup.nothering-probe.example >> "$log" 2>&1 &
lookup=$!
sleep 3
kill "$lookup" > /dev/null 2>&1
sudo arp -d 198.18.0.1 ifscope feth5478 >> "$log" 2>&1
sudo kill "$capture" > /dev/null 2>&1
sleep 1
say "on the stand-in's wire: $(count 'who-has 198.18.0.1' "$out/wire.txt") questions for its router, $(count '> 198.18.0.1.53:' "$out/wire.txt") lookups sent to its DNS server"
if [[ -n $probe ]]; then
  say "with the stand-in and no proxy set, an app fetching a page: $("$probe" fetch http://plain.nothering-probe.example/ 2>&1)"
fi
sudo "$helper" down >> "$log" 2>&1
say "helper down: exit $?"

# --- The stand-in as the command-line tool uses it with --system-proxy: it carries the setting ----
sudo "$helper" up $$ "$port" >> "$log" 2>&1
say "helper up with the proxy's port: exit $?"
sleep 4
snapshot "the network taken away, stand-in up with the proxy setting"
say "with the proxy setting, what macOS tells apps: $(told_apps)"
: > "$socks_log"
if [[ -n $probe ]]; then
  say "with the proxy setting, an app fetching a page by name: $("$probe" fetch http://name.nothering-probe.example/ 2>&1)"
  say "with the proxy setting, an app fetching a page by address: $("$probe" fetch http://192.0.2.10/ 2>&1)"
fi
say "what the proxy was asked for: $(tr '\n' ';' < "$socks_log")"

sudo "$helper" down >> "$log" 2>&1
say "helper down: exit $?"
snapshot "stand-in taken down, network still away"
say "anything left behind: $(ifconfig feth5478 > /dev/null 2>&1 && echo "the interface is still there" || echo no)"
say "proxy setting left behind: $(scutil --proxy 2>/dev/null | grep -c SOCKS) lines about SOCKS (0 = none)"

sudo ifconfig "$interface" up
kill "$restore" "$socks" > /dev/null 2>&1
for _ in $(seq 1 30); do
  if curl -m 5 -sS -o /dev/null https://github.com 2> /dev/null; then
    break
  fi
  sleep 2
done
snapshot "after: the machine's own network again"
say "the machine's network came back: $(curl -m 5 -sS -o /dev/null https://github.com 2> /dev/null && echo yes || echo NO)"
