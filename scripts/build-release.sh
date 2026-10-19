#!/usr/bin/env bash
# Builds a Harbor Setup release from a clean copy of the committed source,
# so nothing of this Mac ends up in it:
#   - not your CodeSigning.xcconfig: the release uses the sample's generic
#     bundle identifier, with no team and no shortcut link;
#   - not uncommitted changes;
#   - not this Mac's paths or user name, which compilers otherwise write into
#     the programs. The copy is built under /tmp, with its own Cargo home,
#     and the result is checked for this Mac's home folder and user name.
#     (Prebuilt third-party libraries carry their own build machines' paths,
#     such as /Users/runner; those are not yours.)
#
#   build-release.sh      writes dist/HarborSetup-mac.zip and its .sha256
#
# Needs network access (the copy fetches its dependencies), Xcode, XcodeGen
# and Rust. Takes a few minutes. Apple silicon only.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

root=$PWD
work=/tmp/harbor-release
version=$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Note: uncommitted changes are left out. The release is built from $(git rev-parse --short HEAD)." >&2
fi

echo "Copying the committed source to $work…"
rm -rf "$work"
git clone -q "$root" "$work"
# Submodules come from this checkout, not the network.
git -C "$work" submodule init -q
for path in $(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}'); do
  name=$(git config -f .gitmodules --get-regexp '\.path$' | awk -v p="$path" '$2 == p {print $1}' | sed 's/^submodule\.//; s/\.path$//')
  git -C "$work" config "submodule.$name.url" "$root/$path"
done
git -C "$work" -c protocol.file.allow=always -c init.defaultBranch=main submodule update -q

cd "$work"
export CARGO_HOME="$work/.cargo-home"

echo "Building Harbor $version…"
bash scripts/check.sh ipa > /dev/null || { echo "Build failed; see $work/build/check-logs/ipa.log" >&2; exit 1; }
echo "Packaging Harbor Setup…"
bash scripts/package-setup-mac.sh dist/Harbor.ipa > /dev/null

echo "Checking the package for local paths…"
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k dist/HarborSetup-mac.zip "$check"
unzip -q "$check/Harbor Setup/Harbor.ipa" -d "$check/ipa"
if grep -rlaF -e "$HOME" -e "/Users/$(id -un)/" "$check" > "$check/found.txt"; then
  echo "The package still holds this Mac's paths, so it wasn't finished:" >&2
  sed "s#$check/##" "$check/found.txt" >&2
  exit 1
fi
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$check/ipa/Payload/Harbor.app/Info.plist")
echo "Harbor's bundle identifier in the package: $bundle"

mkdir -p "$root/dist"
cp dist/HarborSetup-mac.zip dist/HarborSetup-mac.zip.sha256 "$root/dist/"
echo
echo "Wrote dist/HarborSetup-mac.zip for Harbor $version:"
cat "$root/dist/HarborSetup-mac.zip.sha256"
echo
echo "Publish it with:"
echo "  gh release create v$version dist/HarborSetup-mac.zip --title \"Harbor $version\""
