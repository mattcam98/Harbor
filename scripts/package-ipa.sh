#!/usr/bin/env bash
# Packages a built .app as an unsigned IPA and records its SHA-256.
# The result is for installing with a sideloading tool, which signs it.
#
#   package-ipa.sh <path/to/Harbor.app> <output.ipa>
set -euo pipefail

app=$1
output=$2

[ -d "$app" ] || { echo "No app bundle at $app" >&2; exit 1; }
bash "$(dirname "$0")/verify-bundle.sh" "$app"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/Payload"
cp -R "$app" "$work/Payload/"
# A build made without signing must not carry a stale signature.
find "$work/Payload" -name _CodeSignature -type d -prune -exec rm -rf {} +

# The tool that signs this for a device starts from what Apple's profile
# allows and keeps only what the app itself asks for, which it reads from
# the app's own signature. So the app and its extension are signed here with
# no identity, just to carry their entitlements. The team in the keychain
# group names is a stand-in; the signing tool puts the real one in.
packaged="$work/Payload/$(basename "$app")"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$packaged/Info.plist")
host_dir="$(cd "$(dirname "$0")/.." && pwd)/Host"
declare_entitlements() {
  # declare_entitlements <entitlements file> <bundle>
  sed -e 's/\$(AppIdentifierPrefix)/HARBORTEAM./g' -e "s/\$(HARBOR_BUNDLE_ID)/$bundle_id/g" "$1" > "$work/entitlements.plist"
  if grep -q '\$(' "$work/entitlements.plist"; then
    echo "Unresolved build setting in $1" >&2
    exit 1
  fi
  codesign --force --sign - --entitlements "$work/entitlements.plist" "$2"
}
find "$packaged/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -exec codesign --force --sign - {} \;
declare_entitlements "$host_dir/LiveProcess.entitlements" "$packaged/PlugIns/LiveProcess.appex"
declare_entitlements "$host_dir/Harbor.entitlements" "$packaged"
for bundle in "$packaged" "$packaged/PlugIns/LiveProcess.appex"; do
  if ! codesign -d --entitlements - "$bundle" 2>/dev/null | grep -q 'keychain-access-groups'; then
    echo "$bundle does not carry its entitlements" >&2
    exit 1
  fi
done

output_dir=$(cd "$(dirname "$output")" && pwd)
output_path="$output_dir/$(basename "$output")"
rm -f "$output_path"
(cd "$work" && zip -qry "$output_path" Payload)

(cd "$output_dir" && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")

echo "Contents:"
find "$work/Payload" -maxdepth 3 | sed "s|$work/||" | sort
echo "Mach-O:"
file "$work/Payload/$(basename "$app")/$(basename "$app" .app)"
cat "$output_path.sha256"
