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

# Prints one of the two scripts: from inside this file when it carries them, as a release's does,
# and only otherwise from next to it. One of them ends up run as root, so a file that merely has
# its name, in whatever directory this was started from, must never be taken for it.
script_text() {
  if [ -n "$EMBEDDED" ]; then
    embedded "$1"
  elif [ -f "$HERE/$1" ]; then
    cat "$HERE/$1"
  else
    echo "this copy of install.sh doesn't carry $1, and it isn't next to it" >&2
    return 1
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
  sudo /bin/sh -c "'$HELPER' down; rm -f '$RULES' '$HELPER' /var/run/nothering-offline-network.lock"
  echo "Car mode is removed."
  exit 0
fi

# Before the password is asked for: with nothing to install there is no reason to ask.
script_text offline-network.sh > /dev/null
script_text car-watch.sh > /dev/null

echo "Installing the helper needs an administrator's password, this once."
# Root takes the helper from this script's own text, through a pipe, and the rule from the command
# itself. Neither is read from a file: one that the person's other programs could change while the
# password is being typed would end up run as root, or as the rule that says what may be. Each is
# put together where only root can write and moved into place from there. A rule that doesn't
# parse would lock sudo up, so it is checked before it goes in.
script_text offline-network.sh | sudo /bin/sh -c "set -e
umask 022
mkdir -p /Library/PrivilegedHelperTools
cat > '$HELPER.new'
test -s '$HELPER.new'
chown root:wheel '$HELPER.new'
chmod 755 '$HELPER.new'
mv -f '$HELPER.new' '$HELPER'
printf '%s\n' '%admin ALL=(root) NOPASSWD: $HELPER' > '$HELPER.rule'
visudo -cf '$HELPER.rule'
chown root:wheel '$HELPER.rule'
chmod 440 '$HELPER.rule'
mv -f '$HELPER.rule' '$RULES'"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"
script_text car-watch.sh > "$WATCHER"
chmod 755 "$WATCHER"
# AbandonProcessGroup: when the agent ends, what it started is left alone. That includes the
# helper's own watcher, which has to stay to take the stand-in down once the agent is gone.
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
	<key>AbandonProcessGroup</key>
	<true/>
</dict>
</plist>
PLIST
stop_watcher
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Car mode is installed. With the iPhone linked and no other network, this Mac is given a"
echo "stand-in network so its apps go through the iPhone. To take it out: sh install.sh --remove"
