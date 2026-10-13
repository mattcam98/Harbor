#!/usr/bin/env bash
# Builds the smoke-test guest app for a real device, as an unsigned IPA.
#
#   scripts/build-test-guest.sh        -> dist/HarborTestGuest.ipa
#
# A known-good, tiny app to try first when running a guest inside Harbor on
# an iPhone: one screen that says "Hello from the guest". It is unsigned;
# Harbor signs it when it is added.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Payload/Guest.app" dist
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
  -fobjc-arc -fmodules scripts/fixtures/guest/main.m -o "$work/Payload/Guest.app/Guest"
cp scripts/fixtures/guest/Info.plist "$work/Payload/Guest.app/Info.plist"

rm -f dist/HarborTestGuest.ipa
(cd "$work" && zip -qry "$OLDPWD/dist/HarborTestGuest.ipa" Payload)
echo "Built dist/HarborTestGuest.ipa ($(stat -f %z dist/HarborTestGuest.ipa) bytes)"
