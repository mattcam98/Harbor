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
