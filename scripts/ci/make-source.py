#!/usr/bin/env python3
# Writes the AltStore/SideStore source for a release: a JSON file that lists the iPhone app, so
# people add one address in SideStore or AltStore and install and update the app from there. Those
# apps sign it with the person's own Apple ID and sign it again before it expires.
#   scripts/ci/make-source.py Nothering-Direct.ipa direct-0.6.0 owner/repository > source.json
# Field reference: https://faq.altstore.io/developers/make-a-source
# After the same script in viktor-svirsky/tether (MIT).
import datetime
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def info_plist(ipa):
    with zipfile.ZipFile(ipa) as archive:
        paths = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(paths) != 1:
            sys.exit(f"{ipa}: no app in Payload/, or more than one")
        return plistlib.loads(archive.read(paths[0]))


def source(ipa, tag, repo, date):
    repo_url = f"https://github.com/{repo}"
    # The release's own tag, so each release's pictures get new addresses: SideStore keeps showing
    # what it has for an address it has seen.
    raw = f"https://raw.githubusercontent.com/{repo}/{tag}"
    info = info_plist(ipa)
    version = info["CFBundleShortVersionString"]
    if tag != f"direct-{version}":
        sys.exit(f"the tag {tag} doesn't match the app's version {version}")
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+", build):
        sys.exit(f"the app's build number is {build!r}, not a commit count")
    return {
        "name": "Nothering Direct",
        "identifier": "app.nothering.direct.source",
        "subtitle": "Your iPhone's connection on your Mac, with no hotspot and no cable.",
        "website": repo_url,
        "nsfw": False,
        "apps": [
            {
                "name": "Nothering Direct",
                "bundleIdentifier": info["CFBundleIdentifier"],
                "developerName": "devxoul and contributors",
                "subtitle": "Your iPhone's connection on your Mac.",
                "localizedDescription": (
                    "Nothering runs a small proxy on your iPhone, and your Mac's connections are made "
                    "again from the iPhone over cellular. This build adds the direct link: the Mac "
                    "reaches the iPhone over Wi-Fi with no Personal Hotspot, no cable and no network "
                    f"to join. Setup: {repo_url}/blob/{tag}/docs/direct-link.md#install"
                ),
                "iconURL": f"{raw}/Shared/AppIcon.icon/Assets/nothering.png",
                "screenshots": [
                    f"{raw}/fastlane/screenshots/en-US/{name}.png"
                    for name in ("1_iphone69_running", "3_iphone69_usage", "4_iphone69_dark")
                ],
                "category": "utilities",
                # The app is unsigned and asks for no entitlements. Whatever signs it adds its own.
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {k: v for k, v in info.items() if k.endswith("UsageDescription")},
                },
                "versions": [
                    {
                        "version": version,
                        "buildVersion": build,
                        "date": date,
                        "downloadURL": f"{repo_url}/releases/download/{tag}/{Path(ipa).name}",
                        "size": Path(ipa).stat().st_size,
                        # SideStore and AltStore check what they downloaded against this.
                        "sha256": hashlib.sha256(Path(ipa).read_bytes()).hexdigest(),
                        "minOSVersion": info["MinimumOSVersion"],
                        "localizedDescription": f"{repo_url}/releases/tag/{tag}",
                    }
                ],
            }
        ],
    }


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: make-source.py <ipa> <tag> <owner/repository>")
    today = datetime.date.today().isoformat()
    json.dump(source(sys.argv[1], sys.argv[2], sys.argv[3], today), sys.stdout, indent=2)
    print()
