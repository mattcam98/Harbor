#!/usr/bin/env bash
# Installs Harbor on a connected iPhone from this Mac, signed with your own
# Apple ID, without Xcode doing the signing or the installing.
#
#   scripts/setup-mac.sh [--apple-id you@example.com] [--udid ID] [--ipad]
#
# Run it in Terminal on the Mac, with the iPhone connected and unlocked. It
# asks for your Apple ID password on the keyboard; the password is used once
# to sign in to Apple and is not stored or sent anywhere else.
#
# What it does:
#   1. builds the two halves of Harbor Setup and an unsigned copy of Harbor;
#   2. checks that copy against its recorded digest;
#   3. asks Apple, without touching any account, whether it accepts sign-in
#      from this Mac;
#   4. signs in, signs Harbor, installs it, and gives it a pairing file and
#      its signing certificate.
#
# Needs the Xcode command line tools (to build) and Rust (brew install rustup).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

echo "Building the part that talks to the iPhone…"
(cd Setup && cargo build --release --quiet)
tool="$PWD/Setup/target/release/harbor-setup"

echo "Building the part that signs in and signs…"
(cd Packages/HarborSigning && swift build -c release --force-resolved-versions --product harbor-setup-mac > /dev/null)
signer="$PWD/Packages/HarborSigning/.build/release/harbor-setup-mac"

if [ ! -f dist/Harbor.ipa ] || [ ! -f dist/Harbor.ipa.sha256 ]; then
  echo "Building Harbor…"
  bash scripts/check.sh ipa
fi
"$tool" verify dist/Harbor.ipa --sha256 "$(cut -d' ' -f1 dist/Harbor.ipa.sha256)"

"$signer" check
exec "$signer" install --ipa dist/Harbor.ipa --tool "$tool" "$@"
