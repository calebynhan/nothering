#!/bin/sh
# Installs Nothering's car mode on a Mac: the helper that gives a Mac with no network of its own a
# stand-in while the iPhone is linked (offline-network.sh), and, for the Nothering Mac app as it is
# released, the watcher that brings it up and down (car-watch.sh).
#
#   sh install.sh            install, asking for an administrator's password once
#   sh install.sh --remove   take it all out again
#
# Run from a copy of the repository, or as the single file a release carries, which has the other
# two scripts inside it.
set -eu
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

HELPER=/Library/PrivilegedHelperTools/nothering-offline-network
RULES=/etc/sudoers.d/nothering
SUPPORT="$HOME/Library/Application Support/Nothering"
WATCHER="$SUPPORT/car-watch.sh"
LABEL=app.nothering.car-mode
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)

if [ "$(uname)" != Darwin ]; then
  echo "This is for a Mac." >&2
  exit 1
fi

# Writes one of the two scripts to $2: from inside this file when it carries them, as a release's
# does, and only otherwise from next to it. One of them ends up run as root, so a file that merely
# has its name, in whatever directory this was started from, must never be taken for it.
write_script() {
  if [ -n "$EMBEDDED" ]; then
    embedded "$1" > "$2"
  elif [ -f "$HERE/$1" ]; then
    cp "$HERE/$1" "$2"
  else
    echo "this copy of install.sh doesn't carry $1, and it isn't next to it" >&2
    exit 1
  fi
}

EMBEDDED=
# EMBEDDED SCRIPTS

stop_watcher() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--remove" ]; then
  stop_watcher
  rm -f "$AGENT" "$WATCHER"
  echo "Removing the helper needs an administrator's password."
  sudo /bin/sh -c "'$HELPER' down; rm -f '$RULES' '$HELPER'"
  echo "Car mode is removed."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
write_script offline-network.sh "$work/helper"
echo "%admin ALL=(root) NOPASSWD: $HELPER" > "$work/rules"

echo "Installing the helper needs an administrator's password, this once."
# A rule that doesn't parse would lock sudo up, so it is checked before it goes in.
sudo /bin/sh -c "mkdir -p /Library/PrivilegedHelperTools && install -o root -g wheel -m 755 '$work/helper' '$HELPER' && visudo -cf '$work/rules' && install -o root -g wheel -m 440 '$work/rules' '$RULES'"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"
write_script car-watch.sh "$WATCHER"
chmod 755 "$WATCHER"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$WATCHER</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST
stop_watcher
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Car mode is installed. With the iPhone linked and no other network, this Mac is given a"
echo "stand-in network so its apps go through the iPhone. To take it out: sh install.sh --remove"
