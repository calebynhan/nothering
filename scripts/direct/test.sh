#!/bin/sh
# Tests install-mac.sh and the launcher it leaves on the Desktop, against stand-ins for curl,
# networksetup and the tool itself, so it runs on any machine.
#   sh scripts/direct/test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
bin=$work/bin
home=$work/home
mkdir -p "$bin" "$home/Desktop"
FAKE_LOG=$work/log
export FAKE_LOG
failed=0

check() {
  if eval "$2"; then
    echo "  ok: $1"
  else
    echo "  FAILED: $1"
    failed=1
  fi
}

cat > "$bin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF

# Fetches a tool that logs how it was called and ends with FAKE_TOOL_STATUS. With FAKE_BROKEN_TOOL
# set, one that doesn't run at all.
cat > "$bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && out=$2
  shift
done
if [ -n "${FAKE_BROKEN_TOOL:-}" ]; then
  printf '#!/bin/sh\nexit 126\n' > "$out"
else
  printf '#!/bin/sh\necho "tool $*" >> "$FAKE_LOG"\ncase "$1" in --help | --install-helper) exit 0 ;; esac\nexit "${FAKE_TOOL_STATUS:-0}"\n' > "$out"
fi
EOF

cat > "$bin/xattr" <<'EOF'
#!/bin/sh
exit 1
EOF

# Wi-Fi points at the forwarder, the wired service at another proxy on the same port, and the
# rest at nothing.
cat > "$bin/networksetup" <<'EOF'
#!/bin/sh
echo "networksetup $*" >> "$FAKE_LOG"
case "$1" in
  -listallnetworkservices)
    printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nUSB 10/100/1000 LAN\n*Thunderbolt Bridge\niPhone USB\n'
    ;;
  -getsocksfirewallproxy)
    case "$2" in
      Wi-Fi) printf 'Enabled: Yes\nServer: 127.0.0.1\nPort: 11080\nAuthenticated Proxy Enabled: 0\n' ;;
      "USB 10/100/1000 LAN") printf 'Enabled: Yes\nServer: 10.0.0.5\nPort: 11080\nAuthenticated Proxy Enabled: 0\n' ;;
      *) printf 'Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n' ;;
    esac
    ;;
esac
EOF
chmod +x "$bin"/*

sed "s|__REPOSITORY__|someone/nothering|g" "$here/install-mac.sh" > "$work/install-mac.sh"
tool=$home/.local/bin/nothering
launcher="$home/Desktop/Nothering Direct.command"
install() {
  : > "$FAKE_LOG"
  HOME=$home PATH=$bin:$PATH sh "$work/install-mac.sh" > "$work/out" 2>&1
}
launch() {
  : > "$FAKE_LOG"
  PATH=$bin:$PATH FAKE_TOOL_STATUS=$1 sh "$launcher" > "$work/out" 2>&1
}

echo "The installer"
check "install-mac.sh parses" 'sh -n "$here/install-mac.sh"'
install; check "installs without an error" "[ $? -eq 0 ]"
check "fetches the tool from the repository's newest release" 'grep -q "^curl .*https://github.com/someone/nothering/releases/latest/download/nothering " "$FAKE_LOG"'
check "the tool is in place and can be run" '[ -x "$tool" ] && [ ! -e "$tool.new" ]'
check "the tool was tried before it replaced anything" 'grep -n "^tool " "$FAKE_LOG" | head -1 | grep -q -- "--help"'
check "the helper is installed with it" 'grep -qx "tool --install-helper" "$FAKE_LOG"'
check "the launcher is on the Desktop, can be run, and parses" '[ -x "$launcher" ] && sh -n "$launcher"'

echo "The installer, when the tool that was fetched doesn't run"
cp "$tool" "$work/tool.before"
: > "$FAKE_LOG"
HOME=$home PATH=$bin:$PATH FAKE_BROKEN_TOOL=1 sh "$work/install-mac.sh" > "$work/out" 2>&1
check "fails" "[ $? -ne 0 ]"
check "the tool that was there is untouched, and nothing is left over" 'cmp -s "$tool" "$work/tool.before" && [ ! -e "$tool.new" ]'

echo "The launcher: the tool stops by itself"
launch 0; check "ends without an error" "[ $? -eq 0 ]"
check "connects over the direct link, wakes the iPhone and sets the system's proxy" 'grep -qx "tool --via direct --wake --system-proxy" "$FAKE_LOG"'
check "leaves the proxy settings to the tool" '! grep -q networksetup "$FAKE_LOG"'

echo "The launcher: the tool was cut off"
launch 137; check "ends with the tool's status" "[ $? -eq 137 ]"
check "switches off the proxy that pointed at the forwarder" 'grep -qx "networksetup -setsocksfirewallproxystate Wi-Fi off" "$FAKE_LOG"'
check "and no other" '[ "$(grep -c setsocksfirewallproxystate "$FAKE_LOG")" = 1 ]'
check "a disabled service isn't asked about" '! grep -q "Thunderbolt" "$FAKE_LOG"'

echo
if [ "$failed" -eq 0 ]; then
  echo "All checks passed."
else
  echo "SOME CHECKS FAILED."
fi
exit "$failed"
