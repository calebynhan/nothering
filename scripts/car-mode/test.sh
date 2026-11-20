#!/bin/sh
# Tests the car-mode scripts against stand-ins for the system's tools, so they run on any machine
# and need no root: offline-network.sh (the helper), car-watch.sh (the watcher) and install.sh,
# alone and as the single file a release carries.
#   sh scripts/car-mode/test.sh
# What it can't show is how macOS takes the real ifconfig, scutil and route commands.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
state=$work/state
bin=$work/bin
mkdir -p "$bin" "$state" "$work/run" "$work/home" "$work/system"
FAKE_STATE=$state
export FAKE_STATE

failed=0
started=""

cleanup() {
  for pid in $started; do
    kill "$pid" >/dev/null 2>&1
  done
  rm -rf "${work:?}"
}
trap cleanup EXIT

check() {
  if eval "$2"; then
    echo "  ok: $1"
  else
    echo "  FAILED: $1"
    failed=1
  fi
}

# A process that ended but wasn't collected yet still answers to kill -0.
running() {
  status=$(ps -o stat= -p "$1" 2>/dev/null)
  case "$status" in
    '' | Z*) return 1 ;;
    *) return 0 ;;
  esac
}

sleeper() {
  sleep 300 &
  started="$started $!"
  sleeper_pid=$!
}

reset() {
  rm -f "${state:?}"/* "${work:?}"/run/*
  : > "$state/keys"
  : > "$state/log"
}

# --- Stand-ins for the tools the scripts call ------------------------------------------------

# Remembers which interfaces exist and logs every call.
cat > "$bin/ifconfig" <<'EOF'
#!/bin/sh
echo "ifconfig $*" >> "$FAKE_STATE/log"
case "${2:-}" in
  create) [ -e "$FAKE_STATE/if-$1" ] && exit 1; : > "$FAKE_STATE/if-$1" ;;
  destroy) [ -e "$FAKE_STATE/if-$1" ] || exit 1; rm -f "$FAKE_STATE/if-$1" ;;
  "") [ -e "$FAKE_STATE/if-$1" ] || exit 1 ;;
esac
exit 0
EOF

# Keeps the published keys in a file. Asked which service the Mac is on, it names the one a test
# put in primary-IPv4 or primary-IPv6, or else the stand-in once that is published, in scutil's
# format. A service that is only in the keys has no router, and so is never the one.
cat > "$bin/scutil" <<'EOF'
#!/bin/sh
while read -r verb rest; do
  case "$verb" in
    show)
      primary=
      case "$rest" in
        State:/Network/Global/IPv4)
          if [ -s "$FAKE_STATE/primary-IPv4" ]; then
            primary=$(cat "$FAKE_STATE/primary-IPv4")
          elif grep -qx "State:/Network/Service/NOTHERING-OFFLINE/IPv4" "$FAKE_STATE/keys"; then
            primary=NOTHERING-OFFLINE
          fi
          ;;
        State:/Network/Global/IPv6)
          [ -s "$FAKE_STATE/primary-IPv6" ] && primary=$(cat "$FAKE_STATE/primary-IPv6")
          ;;
      esac
      if [ -n "$primary" ]; then
        printf '<dictionary> {\n  PrimaryInterface : en0\n  PrimaryService : %s\n  Router : 192.0.2.1\n}\n' "$primary"
      else
        echo "  No such key"
      fi
      ;;
    d.add)
      echo "scutil d.add $rest" >> "$FAKE_STATE/log"
      ;;
    set)
      echo "scutil set $rest" >> "$FAKE_STATE/log"
      grep -qx "$rest" "$FAKE_STATE/keys" || echo "$rest" >> "$FAKE_STATE/keys"
      ;;
    remove)
      echo "scutil remove $rest" >> "$FAKE_STATE/log"
      grep -vx "$rest" "$FAKE_STATE/keys" > "$FAKE_STATE/keys.new"
      mv "$FAKE_STATE/keys.new" "$FAKE_STATE/keys"
      ;;
  esac
done
exit 0
EOF

cat > "$bin/route" <<'EOF'
#!/bin/sh
echo "route $*" >> "$FAKE_STATE/log"
exit 0
EOF

# The Mac app's forwarder: answers the greeting only while the iPhone is linked.
cat > "$bin/nc" <<'EOF'
#!/bin/sh
echo "nc $*" >> "$FAKE_STATE/log"
cat > /dev/null
[ -e "$FAKE_STATE/linked" ] && printf '\005\000'
exit 0
EOF

# Runs the command as it is: the tests need no root.
cat > "$bin/sudo" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-n" ] && shift
echo "sudo $*" >> "$FAKE_STATE/log"
exec "$@"
EOF

cat > "$bin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF

# Making a file root's takes root. Here it only has to be asked for.
cat > "$bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$FAKE_STATE/log"
exit 0
EOF

# visudo -cf FILE: the one rule, and nothing else.
cat > "$bin/visudo" <<'EOF'
#!/bin/sh
echo "visudo $*" >> "$FAKE_STATE/log"
[ "$1" = "-cf" ] && [ "$(wc -l < "$2" | tr -d ' ')" = 1 ] && grep -q '^%admin ALL=(root) NOPASSWD: /' "$2"
EOF

cat > "$bin/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "$FAKE_STATE/log"
exit 0
EOF

# lockf -k -t SECONDS FILE COMMAND...: a Mac has it. Elsewhere flock does the same, and like lockf
# it keeps the lock to itself instead of handing it to the command.
locks=yes
if ! command -v lockf >/dev/null 2>&1; then
  if command -v flock >/dev/null 2>&1; then
    cat > "$bin/lockf" <<'EOF'
#!/bin/sh
[ "$1" = "-k" ] && shift
wait=
if [ "$1" = "-t" ]; then
  wait="-w $2"
  shift 2
fi
file=$1
shift
exec flock -o $wait "$file" "$@"
EOF
  else
    locks=
  fi
fi
chmod +x "$bin"/*

# The scripts under test, with the stand-ins first on their PATH and their files somewhere a test
# may write.
adapt() {
  sed -e "s|^PATH=/sbin:/usr/sbin:/bin:/usr/bin\$|PATH=$bin:/bin:/usr/bin|" \
      -e "s|/var/run/|$work/run/|g" \
      -e "s|/Library/PrivilegedHelperTools|$work/system/PrivilegedHelperTools|g" \
      -e "s|/etc/sudoers.d|$work/system/sudoers.d|g" "$1"
}
adapt "$here/offline-network.sh" > "$work/helper.sh"
adapt "$here/car-watch.sh" > "$work/watch.sh"
mkdir -p "$work/repo" "$work/system/sudoers.d"
for script in offline-network.sh car-watch.sh install.sh; do
  adapt "$here/$script" > "$work/repo/$script"
done
sh "$here/build-installer.sh" > "$work/install-car-mode.raw.sh"
adapt "$work/install-car-mode.raw.sh" > "$work/install-car-mode.sh"

helper() {
  sh "$work/helper.sh" "$@"
}

# The lock file stays, as it does for the real helper: it is what the next call waits its turn on.
none_left() {
  ! ls "$state" | grep -q '^if-' && ! grep -q NOTHERING "$state/keys" && [ -z "$(ls "$work/run" | grep -v '\.lock$')" ]
}

# --- The copies of the helper agree -----------------------------------------------------------

echo "The helper is the same everywhere it is kept"
awk '/public static let script = #"""/ { on = 1; next } on && /^    """#/ { exit } on { sub(/^    /, ""); print }' \
  "$root/PhoneLink/Sources/OfflineNetwork.swift" > "$work/from-swift.sh"
check "the script in OfflineNetwork.swift is offline-network.sh" 'cmp -s "$work/from-swift.sh" "$here/offline-network.sh"'
check "neither script contains the installer's end marker" '! grep -q NOTHERING_EMBEDDED_SCRIPT "$here/offline-network.sh" "$here/car-watch.sh"'
for script in offline-network.sh car-watch.sh install.sh build-installer.sh; do
  check "$script parses" 'sh -n "$here/$script"'
done
check "the single-file installer parses" 'sh -n "$work/install-car-mode.raw.sh"'

# --- The helper -------------------------------------------------------------------------------

echo "The helper: up for a live process"
reset; sleeper; owner=$sleeper_pid
helper up "$owner"; check "exit status 0" "[ $? -eq 0 ]"
check "both interfaces exist" '[ -e "$state/if-feth5478" ] && [ -e "$state/if-feth5479" ]'
check "the pair is joined and both ends are up" 'grep -q "ifconfig feth5478 peer feth5479" "$state/log" && grep -q "ifconfig feth5479 up" "$state/log"'
check "address set" 'grep -q "ifconfig feth5478 inet 198.18.0.2 netmask 255.255.255.0 up" "$state/log"'
check "service and DNS published" 'grep -qx "State:/Network/Service/NOTHERING-OFFLINE/IPv4" "$state/keys" && grep -qx "State:/Network/Service/NOTHERING-OFFLINE/DNS" "$state/keys"'
check "default route added" 'grep -q "route -n add default 198.18.0.1" "$state/log"'
check "status says up" '[ "$(helper status)" = up ]'

echo "The helper: up again for the same process"
before=$(wc -l < "$state/log")
helper up "$owner"
check "does nothing" '! tail -n +$((before + 1)) "$state/log" | grep -Eq "create|destroy|scutil set"'

echo "The helper: the process ends"
kill "$owner"; wait "$owner" 2>/dev/null; sleep 4
check "taken down by itself" none_left
# Deleting "the default route" takes the one of whatever network the Mac is on by then.
check "no default route is deleted" '! grep -q "route .*delete" "$state/log"'

echo "The helper: a real network comes up"
reset; sleeper; owner=$sleeper_pid
helper up "$owner"
echo "State:/Network/Service/AAAA-REAL/IPv4" >> "$state/keys"; echo AAAA-REAL > "$state/primary-IPv4"; sleep 4
check "taken down, the real one untouched" '! ls "$state" | grep -q "^if-" && ! grep -q NOTHERING "$state/keys" && grep -q AAAA-REAL "$state/keys"'
check "no default route is deleted" '! grep -q "route .*delete" "$state/log"'
said=$(helper up "$owner")
check "up then says the Mac has a network, and creates nothing" '[ "$said" = "this Mac has a network of its own" ] && ! ls "$state" | grep -q "^if-"'

echo "The helper: an IPv6-only network"
reset; echo BBBB-REAL > "$state/primary-IPv6"
said=$(helper up "$owner")
check "counts as the Mac's own network" '[ "$said" = "this Mac has a network of its own" ] && ! ls "$state" | grep -q "^if-"'

echo "The helper: a tunnel with addresses of its own and no router"
reset; echo "State:/Network/Service/TUNNEL/IPv4" >> "$state/keys"
helper up "$owner"; sleep 3
check "is no way out: the stand-in comes up and stays" '[ -e "$state/if-feth5478" ] && grep -qx "State:/Network/Service/NOTHERING-OFFLINE/IPv4" "$state/keys"'
helper down

echo "The helper: down by hand"
reset; helper up "$owner"; watcher=$(cat "$work/run/nothering-offline-network.watcher")
check "a watcher is running" 'running "$watcher"'
helper down
check "everything gone" none_left
check "the watcher stopped" '! running "$watcher"'
helper down; check "down again is harmless" "[ $? -eq 0 ] && none_left"
check "status says down" '[ "$(helper status)" = down ]'

echo "The helper: asked by a process that ignores the usual signal to end"
reset
(trap '' TERM; exec sh "$work/helper.sh" up "$owner")
watcher=$(cat "$work/run/nothering-offline-network.watcher")
check "a watcher is running" 'running "$watcher"'
helper down
check "the watcher stopped all the same" '! running "$watcher"'
check "everything gone" none_left

echo "The helper: a number left behind by a watcher that is gone"
reset; sleeper; bystander=$sleeper_pid
echo "$bystander" > "$work/run/nothering-offline-network.watcher"
helper down
check "the process that has the number now is left alone" 'running "$bystander"'
check "the number is forgotten" '[ ! -e "$work/run/nothering-offline-network.watcher" ]'
echo "not a number; touch $state/injected" > "$work/run/nothering-offline-network.watcher"
helper down
check "what isn't a number is run as nothing" '[ ! -e "$state/injected" ] && [ ! -e "$work/run/nothering-offline-network.watcher" ]'
kill "$bystander"; wait "$bystander" 2>/dev/null

echo "The helper: a second process takes over"
reset; sleeper; other=$sleeper_pid
helper up "$owner"; helper up "$other"
check "the new process is followed" '[ "$(cat "$work/run/nothering-offline-network.owner")" = "$other" ]'
kill "$owner"; wait "$owner" 2>/dev/null; sleep 3
check "still up after the first one ended" '[ -e "$state/if-feth5478" ]'
kill "$other"; wait "$other" 2>/dev/null; sleep 4
check "down once the second ended" none_left

echo "The helper: asked twice at once"
if [ -n "$locks" ]; then
  reset; sleeper; owner=$sleeper_pid
  helper up "$owner" & first=$!
  helper up "$owner" & second=$!
  wait "$first"; wait "$second"
  check "built once, and whole" '[ "$(grep -c "ifconfig feth5478 create" "$state/log")" = 1 ] && [ -e "$state/if-feth5478" ] && [ -e "$state/if-feth5479" ]'
  helper down
  check "down leaves nothing, and no second watcher behind" 'none_left && ! ps -ww -A -o command= | grep -q "[h]elper.sh up $owner"'
  kill "$owner"; wait "$owner" 2>/dev/null
else
  echo "  skipped: no lockf and no flock on this machine, so the helper goes without its lock"
fi

echo "The helper: a watcher's end is for the stand-in it was started for"
reset; sleeper; owner=$sleeper_pid
helper up "$owner"
helper expire 1; check "exit status 0" "[ $? -eq 0 ]"
check "the end of another's watcher takes nothing down" '[ -e "$state/if-feth5478" ] && [ -e "$work/run/nothering-offline-network.watcher" ]'
helper expire "$owner"
check "the end of its own does" none_left
# The watcher itself is still there, with nothing left to end.
kill "$owner"; wait "$owner" 2>/dev/null; sleep 3
check "and it ends with nothing left to do" '! ps -ww -A -o command= | grep -q "[h]elper.sh up $owner" && none_left'

echo "The helper: what asked for it ends, and its process group is told to end, as a launch agent's is"
if command -v perl >/dev/null 2>&1; then
  reset; sleeper; owner=$sleeper_pid
  # The watcher is in the group of whatever asked for it. Here that is a group of its own.
  perl -e 'setpgrp(0, 0); exec @ARGV' sh "$work/helper.sh" up "$owner"
  watcher=$(cat "$work/run/nothering-offline-network.watcher")
  group=$(ps -o pgid= -p "$watcher" | tr -d ' ')
  kill "$owner"; wait "$owner" 2>/dev/null
  # Never this test's own group, whatever went wrong above.
  if [ -n "$group" ] && [ "$group" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
    perl -e 'kill "TERM", -$ARGV[0]' "$group"
    sleep 4
    check "the watcher outlives that and takes the stand-in down" none_left
  else
    check "the helper ran in a group of its own" false
  fi
else
  echo "  skipped: no perl to make a process group with"
fi

echo "The helper: up without a port"
reset; sleeper; owner=$sleeper_pid
helper up "$owner"
check "no proxy is set" '! grep -q Proxies "$state/keys" && ! grep -Eq "set .*Proxies|SOCKS" "$state/log"'
helper down

echo "The helper: up with the forwarder's port"
reset
helper up "$owner" 11080; check "exit status 0" "[ $? -eq 0 ]"
check "the network is up as without one" '[ -e "$state/if-feth5478" ] && grep -qx "State:/Network/Service/NOTHERING-OFFLINE/IPv4" "$state/keys"'
check "the proxy setting is published" 'grep -qx "State:/Network/Service/NOTHERING-OFFLINE/Proxies" "$state/keys"'
check "it points at this Mac and that port" 'grep -qx "scutil d.add SOCKSProxy 127.0.0.1" "$state/log" && grep -qx "scutil d.add SOCKSPort # 11080" "$state/log" && grep -qx "scutil d.add SOCKSEnable # 1" "$state/log"'
helper down
check "taken down with the rest" none_left
kill "$owner"; wait "$owner" 2>/dev/null

echo "The helper: ports that aren't ports"
reset; sleeper; owner=$sleeper_pid
results=""
for port in 0 65536 70000 123456 1e3 -1 "80 80" "80; touch $state/injected" 0x50 08; do
  helper up "$owner" "$port" 2>/dev/null; results="$results $?"
done
check "all refused with exit 64" '[ "$results" = " 64 64 64 64 64 64 64 64 64 64" ]'
check "nothing created, and nothing run from the argument" '! ls "$state" | grep -q "^if-" && [ ! -e "$state/injected" ]'
results=""
for port in 1 80 1024 11080 59999 64999 65000 65499 65529 65535; do
  helper up "$owner" "$port" 2>/dev/null; results="$results $?"; helper down
done
check "every real port is taken" '[ "$results" = " 0 0 0 0 0 0 0 0 0 0" ]'
kill "$owner"; wait "$owner" 2>/dev/null

echo "The helper: arguments that aren't a process"
reset
helper up "12; touch $state/injected" 2>/dev/null; r0=$?
helper up abc 2>/dev/null; r1=$?
helper up 2>/dev/null; r2=$?
helper up 999999 2>/dev/null; r3=$?
helper nonsense 2>/dev/null; r4=$?
helper 2>/dev/null; r5=$?
check "all refused with exit 64" '[ "$r0 $r1 $r2 $r3 $r4 $r5" = "64 64 64 64 64 64" ]'
check "nothing created, and nothing run from the argument" '! ls "$state" | grep -q "^if-" && [ ! -e "$state/injected" ]'

# --- The watcher ------------------------------------------------------------------------------

# Runs the watcher for a few rounds in the state the test set up, and leaves what it asked sudo for
# in $work/asks. Not in a subshell, so the watcher's process ID is known afterwards.
watch() {
  : > "$state/log"
  NOTHERING_CAR_WATCH_INTERVAL=1 sh "$work/watch.sh" &
  watch_pid=$!
  started="$started $watch_pid"
  sleep 3
  kill "$watch_pid" >/dev/null 2>&1
  wait "$watch_pid" 2>/dev/null
  grep '^sudo ' "$state/log" | sed "s|$work/system/PrivilegedHelperTools/nothering-offline-network|HELPER|" > "$work/asks"
}
# The watcher's helper only has to be there to be called.
mkdir -p "$work/system/PrivilegedHelperTools"
printf '#!/bin/sh\nexit 0\n' > "$work/system/PrivilegedHelperTools/nothering-offline-network"
chmod +x "$work/system/PrivilegedHelperTools/nothering-offline-network"

echo "The watcher: linked to the iPhone, and the Mac has no network"
reset; : > "$state/linked"; watch
check "asks for the stand-in with the app's port, for its own lifetime" 'grep -q "^sudo HELPER up $watch_pid 11080\$" "$work/asks"'
check "never asks for it to be taken down" '! grep -q down "$work/asks"'

echo "The watcher: linked, and the Mac has a network of its own"
reset; : > "$state/linked"; echo AAAA-REAL > "$state/primary-IPv4"; watch
check "asks for nothing" '[ ! -s "$work/asks" ]'

echo "The watcher: linked, on an IPv6-only network"
reset; : > "$state/linked"; echo BBBB-REAL > "$state/primary-IPv6"; watch
check "asks for nothing" '[ ! -s "$work/asks" ]'

echo "The watcher: linked, with only a tunnel that has no router"
reset; : > "$state/linked"; echo "State:/Network/Service/TUNNEL/IPv4" >> "$state/keys"; watch
check "asks for the stand-in" 'grep -q "^sudo HELPER up " "$work/asks"'

# The stand-in as the helper leaves it: its interface, and its service the one the Mac is on.
standin() {
  : > "$state/if-feth5478"
  echo "State:/Network/Service/NOTHERING-OFFLINE/IPv4" >> "$state/keys"
}

echo "The watcher: linked, and the stand-in is already up"
reset; : > "$state/linked"; standin; watch
check "asks for nothing, so it isn't torn down and rebuilt" '[ ! -s "$work/asks" ]'

echo "The watcher: the iPhone is gone and the stand-in is still up"
reset; standin; watch
check "asks for it to be taken down" 'grep -q "^sudo HELPER down\$" "$work/asks"'
check "never asks for it to be brought up" '! grep -q " up " "$work/asks"'

echo "The watcher: no iPhone, no stand-in"
reset; watch
check "asks for nothing" '[ ! -s "$work/asks" ]'

# --- The installer ----------------------------------------------------------------------------

installed_helper=$work/system/PrivilegedHelperTools/nothering-offline-network
installed_rules=$work/system/sudoers.d/nothering
agent="$work/home/Library/LaunchAgents/app.nothering.car-mode.plist"
watcher_file="$work/home/Library/Application Support/Nothering/car-watch.sh"

try_installer() {
  rm -rf "${work:?}/home" "${work:?}/system"
  mkdir -p "$work/home" "$work/system/sudoers.d"
  reset
  HOME=$work/home sh "$1" > "$work/install.out" 2>&1
  check "installs without an error" "[ $? -eq 0 ]"
  check "the helper is in place, as the repository has it" 'cmp -s "$installed_helper" "$work/repo/offline-network.sh"'
  check "the helper is made root's, and others can run it and not write it" 'grep -q "^chown root:wheel $installed_helper.new\$" "$state/log" && [ "$(ls -l "$installed_helper" | cut -c1-10)" = "-rwxr-xr-x" ]'
  check "the sudo rule names only the helper" '[ "$(cat "$installed_rules")" = "%admin ALL=(root) NOPASSWD: $installed_helper" ]'
  check "the rule was checked before it went in, and only root reads it" 'grep -q "^visudo -cf $installed_helper.rule\$" "$state/log" && [ "$(ls -l "$installed_rules" | cut -c1-10)" = "-r--r-----" ]'
  check "nothing is left where the two were put together" '[ "$(ls "$work/system/PrivilegedHelperTools")" = nothering-offline-network ]'
  check "root takes the helper from a pipe, and reads no file for it" 'grep -qx "cat > .$installed_helper.new." "$state/log" && ! grep -Eq "^install |^cp |install -o" "$state/log"'
  check "the watcher is in place" 'cmp -s "$watcher_file" "$work/repo/car-watch.sh" && [ -x "$watcher_file" ]'
  check "the launch agent runs the watcher" 'grep -q "<string>$watcher_file</string>" "$agent" && grep -q "<string>app.nothering.car-mode</string>" "$agent"'
  check "the launch agent is started" 'grep -q "^launchctl bootstrap gui/$(id -u) $agent\$" "$state/log"'
  check "the agent's end leaves what it started alone, the helper's watcher with it" 'grep -A1 "<key>AbandonProcessGroup</key>" "$agent" | grep -q "<true/>"'
  HOME=$work/home sh "$1" --remove > "$work/remove.out" 2>&1
  check "removes without an error" "[ $? -eq 0 ]"
  check "nothing is left, the helper's lock included" '[ ! -e "$installed_helper" ] && [ ! -e "$installed_rules" ] && [ ! -e "$agent" ] && [ ! -e "$watcher_file" ] && [ -z "$(ls "$work/run")" ]'
  check "the launch agent is stopped" 'grep -q "^launchctl bootout gui/$(id -u)/app.nothering.car-mode\$" "$state/log"'
}

echo "The installer, from a copy of the repository"
try_installer "$work/repo/install.sh"

echo "The installer, as the single file a release carries"
mkdir -p "$work/alone"
cp "$work/install-car-mode.sh" "$work/alone/install-car-mode.sh"
try_installer "$work/alone/install-car-mode.sh"

echo "The installer, fed to sh the way a download is"
rm -rf "${work:?}/home" "${work:?}/system"; mkdir -p "$work/home" "$work/system/sudoers.d"; reset
(cd "$work/alone" && HOME=$work/home sh < "$work/install-car-mode.sh" > "$work/install.out" 2>&1)
check "installs without an error" "[ $? -eq 0 ]"
check "the helper is in place" 'cmp -s "$installed_helper" "$work/repo/offline-network.sh"'
check "the watcher is in place" 'cmp -s "$watcher_file" "$work/repo/car-watch.sh"'

echo "The installer, fed to sh in a directory that has files with the scripts' names"
rm -rf "${work:?}/home" "${work:?}/system"; mkdir -p "$work/home" "$work/system/sudoers.d" "$work/trap"; reset
printf '#!/bin/sh\ntouch "%s/planted"\n' "$state" > "$work/trap/offline-network.sh"
cp "$work/trap/offline-network.sh" "$work/trap/car-watch.sh"
(cd "$work/trap" && HOME=$work/home sh < "$work/install-car-mode.sh" > "$work/install.out" 2>&1)
check "installs without an error" "[ $? -eq 0 ]"
check "the helper is its own, not the file that was lying there" 'cmp -s "$installed_helper" "$work/repo/offline-network.sh"'
check "the watcher is its own, not the file that was lying there" 'cmp -s "$watcher_file" "$work/repo/car-watch.sh"'

echo "The installer, with nothing to install"
rm -rf "${work:?}/home" "${work:?}/system"; mkdir -p "$work/home" "$work/system/sudoers.d" "$work/bare"; reset
cp "$work/repo/install.sh" "$work/bare/install.sh"
HOME=$work/home sh "$work/bare/install.sh" > "$work/install.out" 2>&1
check "fails" "[ $? -ne 0 ]"
check "and never asks for the password" '! grep -q "^sudo " "$state/log" && [ ! -e "$installed_helper" ]'

echo "The watcher: with a network, the iPhone isn't asked"
reset; : > "$state/linked"; echo AAAA-REAL > "$state/primary-IPv4"; watch
check "no connection to the iPhone's proxy" '! grep -q "^nc " "$state/log"'
reset; : > "$state/linked"; watch
check "without one it is asked" 'grep -q "^nc " "$state/log"'

echo
if [ "$failed" -eq 0 ]; then
  echo "All checks passed."
else
  echo "SOME CHECKS FAILED."
fi
exit "$failed"
