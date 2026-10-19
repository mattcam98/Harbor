#!/bin/bash
# Installs Harbor on an iPhone from this Mac, once. The download page's line:
#
#   /bin/bash -c "$(curl -fsSL https://mattcam98.github.io/Harbor/install.sh)"
#
# Downloads Harbor Setup 0.1.0, checks it against the SHA-256 below, and
# starts it. Harbor Setup asks for your Apple ID, signs Harbor with it and
# installs it on the iPhone connected by cable. Your password is sent only to
# Apple. Written by scripts/build-site.sh; edit that, not this.
set -euo pipefail

version="0.1.0"
url="https://github.com/mattcam98/Harbor/releases/download/v0.1.0/HarborSetup-mac.zip"
sha256="ac0a023587ef9af524008e279957feb718cd16c285f7467e42c7ca4d84b0fc57"

fail() { echo "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail "Harbor Setup runs on a Mac."
[ "$(uname -m)" = arm64 ] || fail "This Harbor Setup needs a Mac with Apple silicon (M1 or later)."
# Part of it (Unicorn, for anisette) is built for macOS 26. It may run on
# earlier releases, but that has not been tried.
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
  echo "Harbor Setup has only been tried on macOS 26 and later. Continuing anyway." >&2
fi

home="$HOME/Library/Application Support/Harbor Setup/$version"
if [ ! -x "$home/Harbor Setup/install-harbor" ]; then
  download=$(mktemp -d)
  trap 'rm -rf "$download"' EXIT
  echo "Downloading Harbor Setup $version…"
  curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$download/setup.zip" "$url"
  [ "$(shasum -a 256 "$download/setup.zip" | cut -d' ' -f1)" = "$sha256" ] \
    || fail "The download does not match its published SHA-256, so nothing was run."
  rm -rf "$home"
  mkdir -p "$home"
  ditto -x -k "$download/setup.zip" "$home"
  # exec below skips the trap, so tidy up here.
  rm -rf "$download"
  trap - EXIT
fi

echo
echo "Connect the iPhone with a cable, unlock it, and tap Trust if it asks."
echo
exec "$home/Harbor Setup/install-harbor" "$@"
