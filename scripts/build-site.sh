#!/usr/bin/env bash
# Writes the download page's data for a Harbor Setup download about to be
# published as a GitHub release:
#   site/release.json  what the page shows: version, size, digests
#   site/install.sh    what the page's Terminal line runs: downloads Harbor
#                      Setup, checks its SHA-256, and starts it
#   site/icon.png
#
#   build-site.sh [path/to/HarborSetup-mac.zip]   default: dist/HarborSetup-mac.zip
#
# Environment:
#   HARBOR_REPO   owner/name of the GitHub repository the release and the
#                 page live in (default mattcam98/Harbor). Both must be
#                 public for the Terminal line to download them.
#
# Publishes nothing. It prints the commands that would.
set -euo pipefail
cd "$(dirname "$0")/.."

zip=${1:-dist/HarborSetup-mac.zip}
repo=${HARBOR_REPO:-mattcam98/Harbor}
[ -f "$zip" ] || { echo "No download at $zip. Make one: bash scripts/package-setup-mac.sh" >&2; exit 1; }
# The page and install.sh point at the release asset by this name.
[ "$(basename "$zip")" = HarborSetup-mac.zip ] || { echo "The download must be named HarborSetup-mac.zip" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
folder="$work/Harbor Setup"
for part in install-harbor harbor-setup harbor-setup-mac Harbor.ipa Harbor.ipa.sha256; do
  [ -e "$folder/$part" ] || { echo "$zip has no Harbor Setup/$part" >&2; exit 1; }
done
unzip -q "$folder/Harbor.ipa" -d "$work/ipa"
app=$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)

# Whether this Harbor has the iOS 27 screen for pairing with itself. It is
# only compiled with HARBOR_SELF_PAIRING. (grep -c reads everything: -q would
# stop nm early, which pipefail reports as a failure.)
self_pairing=false
if [ "$(nm "$app/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI" 2>/dev/null | grep -c SelfPairingSpike)" -gt 0 ]; then
  self_pairing=true
fi

mkdir -p site
# 256 points is plenty for the page.
sips -Z 256 Host/Assets.xcassets/AppIcon.appiconset/AppIcon-light.png --out site/icon.png >/dev/null

python3 -I - "$zip" "$app/Info.plist" "$(cat "$folder/Harbor.ipa.sha256")" "$repo" "$self_pairing" > site/release.json <<'PY'
import datetime, hashlib, json, os, plistlib, sys

zip_path, info_path, ipa_sha256, repo, self_pairing = sys.argv[1:6]
owner, name = repo.split("/", 1)
with open(info_path, "rb") as f:
    info = plistlib.load(f)
digest = hashlib.sha256()
with open(zip_path, "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        digest.update(block)
version = info["CFBundleShortVersionString"]
pages = f"https://{owner.lower()}.github.io/{name}"
json.dump({
    "version": version,
    "buildVersion": info.get("CFBundleVersion", "1"),
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    "selfPairing": self_pairing == "true",
    "repository": f"https://github.com/{repo}",
    "installCommand": f'/bin/bash -c "$(curl -fsSL {pages}/install.sh)"',
    "setup": {
        "url": f"https://github.com/{repo}/releases/download/v{version}/HarborSetup-mac.zip",
        "size": os.path.getsize(zip_path),
        "sha256": digest.hexdigest(),
    },
    "harborIPASha256": ipa_sha256.strip(),
}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

field() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[1:], json.load(open("site/release.json"))))' "$@"; }
version=$(field version)
url=$(field setup url)
sha256=$(field setup sha256)

cat > site/install.sh <<EOF
#!/bin/bash
# Installs Harbor on an iPhone from this Mac, once. The download page's line:
#
#   $(field installCommand)
#
# Downloads Harbor Setup $version, checks it against the SHA-256 below, and
# starts it. Harbor Setup asks for your Apple ID, signs Harbor with it and
# installs it on the iPhone connected by cable. Your password is sent only to
# Apple. Written by scripts/build-site.sh; edit that, not this.
set -euo pipefail

version="$version"
url="$url"
sha256="$sha256"

fail() { echo "\$*" >&2; exit 1; }
[ "\$(uname -s)" = Darwin ] || fail "Harbor Setup runs on a Mac."
[ "\$(uname -m)" = arm64 ] || fail "This Harbor Setup needs a Mac with Apple silicon (M1 or later)."
# Part of it (Unicorn, for anisette) is built for macOS 26. It may run on
# earlier releases, but that has not been tried.
if [ "\$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
  echo "Harbor Setup has only been tried on macOS 26 and later. Continuing anyway." >&2
fi

home="\$HOME/Library/Application Support/Harbor Setup/\$version"
if [ ! -x "\$home/Harbor Setup/install-harbor" ]; then
  download=\$(mktemp -d)
  trap 'rm -rf "\$download"' EXIT
  echo "Downloading Harbor Setup \$version…"
  curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "\$download/setup.zip" "\$url"
  [ "\$(shasum -a 256 "\$download/setup.zip" | cut -d' ' -f1)" = "\$sha256" ] \\
    || fail "The download does not match its published SHA-256, so nothing was run."
  rm -rf "\$home"
  mkdir -p "\$home"
  ditto -x -k "\$download/setup.zip" "\$home"
  # exec below skips the trap, so tidy up here.
  rm -rf "\$download"
  trap - EXIT
fi

echo
echo "Connect the iPhone with a cable, unlock it, and tap Trust if it asks."
echo
exec "\$home/Harbor Setup/install-harbor" "\$@"
EOF
chmod 755 site/install.sh

echo "Wrote site/release.json and site/install.sh for Harbor $version ($( [ "$self_pairing" = true ] && echo "with" || echo "without") the iOS 27 pairing screen)."
echo
echo "To publish (not done here), in this order:"
echo "  gh release create v$version \"$zip\" --repo $repo --title \"Harbor $version\" --notes \"Harbor Setup for Mac (Apple silicon). SHA-256 $sha256\""
echo "  git add site && git commit -m \"Publish Harbor $version on the download page\" && git push"
