#!/bin/bash
# Publishes what scripts/ci/package.sh put together as a GitHub release, tagged direct-<version>:
#   scripts/ci/release.sh <version> <release dir>
# The tag has a prefix of its own, since plain x.y.z tags are the original project's releases.
set -euo pipefail
version=$1
from=$2
tag=direct-$version
repo=$GITHUB_REPOSITORY
if gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
  echo "::error::$tag is already released. Release the next version instead."
  exit 1
fi
cat > "$from/notes.md" <<NOTES
Nothering with the direct link: the Mac uses the iPhone's connection with no Personal Hotspot, no cable and no Wi-Fi network.

Install: https://github.com/$repo/blob/$tag/docs/direct-link.md#install

- **Nothering-Direct.ipa** is the iPhone app, unsigned. SideStore or AltStore install and keep it signed from \`https://github.com/$repo/releases/latest/download/source.json\`.
- **install-mac.sh** sets the Mac up for the direct link.
- **install-car-mode.sh** is for the App Store's Nothering with a cable, on a Mac with no network.

Built by GitHub from $(git rev-parse HEAD). Checksums are in SHA256SUMS.
NOTES
gh release create "$tag" --repo "$repo" --target "$(git rev-parse HEAD)" --title "Nothering Direct $version" \
  --notes-file "$from/notes.md" --latest \
  "$from/Nothering-Direct.ipa" "$from/nothering" "$from/install-mac.sh" "$from/install-car-mode.sh" \
  "$from/source.json" "$from/SHA256SUMS"
