#!/bin/sh
# Sets a Mac up for Nothering's direct link: fetches the command-line tool from this repository's
# newest release, installs the helper for a Mac with no network of its own, and leaves a launcher
# on the Desktop to double-click.
#   curl -fsSL https://github.com/__REPOSITORY__/releases/latest/download/install-mac.sh | sh
# Run it again to get a newer tool. To take it out: ~/.local/bin/nothering --remove-helper, then
# delete ~/.local/bin/nothering and the launcher.
set -eu
REPOSITORY=__REPOSITORY__
BIN="$HOME/.local/bin"
TOOL="$BIN/nothering"
LAUNCHER="$HOME/Desktop/Nothering Direct.command"

if [ "$(uname)" != Darwin ]; then
  echo "This is for a Mac." >&2
  exit 1
fi

mkdir -p "$BIN"
echo "Fetching the Nothering tool."
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/nothering" -o "$TOOL.new"
chmod +x "$TOOL.new"
# What a browser marks a download with, and macOS then refuses to run. curl leaves no mark, but a
# copy that was fetched another way may have one.
xattr -d com.apple.quarantine "$TOOL.new" 2>/dev/null || true
if ! "$TOOL.new" --help > /dev/null 2>&1; then
  rm -f "$TOOL.new"
  echo "The tool that was fetched doesn't run on this Mac. It needs macOS 15 or later." >&2
  exit 1
fi
mv "$TOOL.new" "$TOOL"

echo "Installing the helper that keeps the Mac's apps going when the Mac has no network of its own."
echo "It needs an administrator's password, this once."
"$TOOL" --install-helper

cat > "$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Connects this Mac to the iPhone over the direct link, wakes the iPhone's app for it, and points
# the Mac's apps at it with the system's proxy setting. Closing the window disconnects.
"$TOOL" --via direct --wake --system-proxy
status=\$?
# The tool takes the proxy setting back when it stops. If it was cut off before it could, apps
# would be left pointing at a proxy that is gone.
if [ "\$status" -ne 0 ]; then
  networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r service; do
    setting=\$(networksetup -getsocksfirewallproxy "\$service" 2>/dev/null)
    case "\$setting" in
      *"Server: 127.0.0.1"*"Port: 11080"*) networksetup -setsocksfirewallproxystate "\$service" off ;;
    esac
  done
fi
exit "\$status"
LAUNCHER
chmod +x "$LAUNCHER"

echo
echo "Done. To connect, double-click \"Nothering Direct\" on the Desktop, or run:"
echo "  $TOOL --via direct --wake --system-proxy"
echo "The first time, the iPhone asks whether to allow this Mac. Tap Allow if both show the same number."
