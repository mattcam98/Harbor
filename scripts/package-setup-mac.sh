#!/usr/bin/env bash
# Packages Harbor Setup for Mac as the single download the download page
# offers: the part that talks to the iPhone (Rust), the part that signs in and
# signs (Swift), an unsigned Harbor.ipa with its SHA-256, and install-harbor,
# which runs them in order.
#
#   package-setup-mac.sh [path/to/Harbor.ipa]      default: dist/Harbor.ipa
#
# Writes dist/HarborSetup-mac.zip and its .sha256. Apple silicon only: the
# programs are built for this Mac's architecture, arm64.
#
# Needs the Xcode command line tools and Rust (brew install rustup).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

ipa=${1:-dist/Harbor.ipa}
[ -f "$ipa" ] || { echo "No IPA at $ipa. Build one: bash scripts/check.sh ipa" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Package on a Mac with Apple silicon." >&2; exit 1; }

echo "Building the part that talks to the iPhone…"
(cd Setup && cargo build --release --quiet)
echo "Building the part that signs in and signs…"
# Unicorn's prebuilt library targets macOS 26 and the linker says so once
# per object file; install.sh warns about it instead. Other output is shown
# only if the build fails.
log=$(mktemp)
if ! (cd Packages/HarborSigning && swift build -c release --force-resolved-versions --product harbor-setup-mac) > "$log" 2>&1; then
  grep -v "was built for newer 'macOS' version" "$log" >&2
  rm -f "$log"
  exit 1
fi
rm -f "$log"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
folder="$work/Harbor Setup"
mkdir "$folder"
cp Setup/target/release/harbor-setup "$folder/"
cp Packages/HarborSigning/.build/release/harbor-setup-mac "$folder/"
cp "$ipa" "$folder/Harbor.ipa"
shasum -a 256 "$folder/Harbor.ipa" | cut -d' ' -f1 > "$folder/Harbor.ipa.sha256"
cp scripts/setup-runner.sh "$folder/install-harbor"
chmod 755 "$folder/install-harbor" "$folder/harbor-setup" "$folder/harbor-setup-mac"

# Both programs may only depend on what every Mac has.
for program in harbor-setup harbor-setup-mac; do
  if otool -L "$folder/$program" | tail -n +2 | grep -vqE '^\s+(/usr/lib/|/System/Library/)'; then
    echo "$program links a library a Mac does not have:" >&2
    otool -L "$folder/$program" >&2
    exit 1
  fi
done

mkdir -p dist
output="$PWD/dist/HarborSetup-mac.zip"
rm -f "$output"
(cd "$work" && ditto -c -k --keepParent --norsrc "Harbor Setup" "$output")
(cd dist && shasum -a 256 HarborSetup-mac.zip > HarborSetup-mac.zip.sha256)
echo "Wrote dist/HarborSetup-mac.zip"
cat dist/HarborSetup-mac.zip.sha256
