#!/bin/bash
# Puts together what a release carries, from what scripts/ci/run.sh built:
#   scripts/ci/package.sh <version> <build number> <derived data> <output dir>
# - Nothering-Direct.ipa: the iPhone app, unsigned, for whoever installs it to sign (SideStore,
#   AltStore, Sideloadly, Xcode)
# - nothering: the Mac command-line tool, for both kinds of Mac
# - install-mac.sh: fetches the tool and sets it up
# - install-car-mode.sh: car mode for the Nothering Mac app as it is released
# - source.json: lets SideStore and AltStore install and update the iPhone app from one address
set -euo pipefail
(( $# == 4 )) || { echo "usage: package.sh <version> <build number> <derived data> <output dir>" >&2; exit 2; }
version=$1
build=$2
derived=$3
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$4"
out=$(cd "$4" && pwd)
# On GitHub, the repository the build runs in. Elsewhere, the one this copy was cloned from.
repo=${GITHUB_REPOSITORY:-$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's|^.*github\.com[:/]||; s|\.git$||')}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "which repository's releases the installers fetch from isn't known: set GITHUB_REPOSITORY to owner/name" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

app=$derived/Build/Products/Production-iphoneos/Nothering.app
tool=$derived/Build/Products/Production/nothering
[[ -d $app ]] || { echo "no iPhone app at $app" >&2; exit 1; }
[[ -x $tool ]] || { echo "no Mac tool at $tool" >&2; exit 1; }

# The iPhone app: this build's name and version. Nothing signed the bundle here, so its Info.plist
# can still be edited. (The linker may have put a signature of its own on the program inside,
# which covers nothing else.)
if [[ -d $app/_CodeSignature ]]; then
  echo "the iPhone app's bundle is signed, it should be unsigned" >&2
  exit 1
fi
plist=$app/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Nothering Direct" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
[[ $(lipo -archs "$app/Nothering") == arm64 ]] || { echo "the iPhone app isn't arm64 only" >&2; exit 1; }
for key in NSBonjourServices NSLocalNetworkUsageDescription NSBluetoothAlwaysUsageDescription UIBackgroundModes; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" > /dev/null || { echo "the iPhone app's Info.plist has no $key" >&2; exit 1; }
done
mkdir "$work/Payload"
cp -R "$app" "$work/Payload/"
rm -f "$out/Nothering-Direct.ipa"
(cd "$work" && zip -qry "$out/Nothering-Direct.ipa" Payload)

# The Mac tool.
archs=$(lipo -archs "$tool")
[[ $archs == *arm64* && $archs == *x86_64* ]] || { echo "the Mac tool is for '$archs', not for both kinds of Mac" >&2; exit 1; }
cp "$tool" "$out/nothering"
"$out/nothering" --help > /dev/null || { echo "the Mac tool doesn't run" >&2; exit 1; }
# Waking the iPhone takes both of these in the tool itself: the entitlement that lets a program
# with the hardened runtime use Bluetooth at all, and the Info.plist with the words macOS shows
# when it asks. Without either the wake is refused without a question.
entitlements=$(codesign -d --entitlements - "$out/nothering" 2>&1 || true)
[[ $entitlements == *com.apple.security.device.bluetooth* ]] || { echo "the Mac tool lacks the Bluetooth entitlement: $entitlements" >&2; exit 1; }
# Taken whole first: a reader that stops at its first match can leave otool writing into a closed
# pipe, and under pipefail that reads as "not there".
sections=$(otool -l "$out/nothering")
[[ $sections == *__info_plist* ]] || { echo "the Mac tool carries no Info.plist" >&2; exit 1; }

# The installers, pointing at this repository's releases.
sed "s|__REPOSITORY__|$repo|g" "$root/scripts/direct/install-mac.sh" > "$out/install-mac.sh"
sh "$root/scripts/car-mode/build-installer.sh" > "$out/install-car-mode.sh"
sh -n "$out/install-mac.sh"
sh -n "$out/install-car-mode.sh"

python3 "$root/scripts/ci/make-source.py" "$out/Nothering-Direct.ipa" "direct-$version" "$repo" > "$out/source.json"

(cd "$out" && shasum -a 256 Nothering-Direct.ipa nothering install-mac.sh install-car-mode.sh source.json > SHA256SUMS)
ls -l "$out"
