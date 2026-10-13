#!/usr/bin/env bash
# Runs a guest app inside Harbor on the iOS Simulator and checks that it
# really ran as itself.
#
# Builds Harbor and a tiny guest app for the simulator, has Harbor add the
# guest to its container, then starts Harbor as that guest and reads the
# report the guest writes about its own process. A screenshot is saved to
# build/guest-smoke/screenshot.png.
#
# The simulator does not enforce code signatures, so this exercises
# everything about running a guest except signing.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/guest-smoke
rm -rf "$out"
mkdir -p "$out"

simulator=$(bash scripts/pick-simulator.sh)
bundle_id=$(awk '/HARBOR_BUNDLE_ID/ {print $3}' CodeSigning.xcconfig 2>/dev/null | head -1)
bundle_id=${bundle_id:-me.mattcam.harbor}
guest_folder=com.example.harborguest.app

echo "Simulator $simulator, Harbor bundle $bundle_id"

# --- Build the guest and package it as an IPA.
mkdir -p "$out/ipa/Payload/Guest.app"
xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc -fmodules scripts/fixtures/guest/main.m -o "$out/ipa/Payload/Guest.app/Guest"
cp scripts/fixtures/guest/Info.plist "$out/ipa/Payload/Guest.app/Info.plist"
(cd "$out/ipa" && zip -qry ../Guest.ipa Payload)
guest_ipa="$(pwd)/$out/Guest.ipa"

# --- Build Harbor for the simulator.
bash scripts/generate-project.sh > "$out/generate.log" 2>&1
xcodebuild build \
  -project Harbor.xcodeproj -scheme Harbor \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath build/sim \
  -onlyUsePackageVersionsFromResolvedFile > "$out/build.log" 2>&1 || {
    grep -E 'error:|\*\* BUILD FAILED' "$out/build.log" | head -20
    exit 1
  }
app=build/sim/Build/Products/Debug-iphonesimulator/Harbor.app
bash scripts/verify-bundle.sh "$app"

# --- A clean install on a booted simulator.
xcrun simctl boot "$simulator" 2>/dev/null || true
xcrun simctl bootstatus "$simulator" > /dev/null
xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true
xcrun simctl uninstall "$simulator" "$bundle_id" 2>/dev/null || true
xcrun simctl install "$simulator" "$app"
data=$(xcrun simctl get_app_container "$simulator" "$bundle_id" data)

wait_for() {
  # wait_for <seconds> <path>
  local remaining=$1
  while [ "$remaining" -gt 0 ]; do
    [ -e "$2" ] && return 0
    sleep 1
    remaining=$((remaining - 1))
  done
  return 1
}

# --- Step 1: Harbor adds the guest to its container.
xcrun simctl launch "$simulator" "$bundle_id" -HarborAddGuest "$guest_ipa" > /dev/null
if ! wait_for 60 "$data/Documents/Applications/$guest_folder/LCAppInfo.plist"; then
  echo "FAILED: Harbor did not add the guest."
  xcrun simctl io "$simulator" screenshot "$out/screenshot.png" > /dev/null 2>&1 || true
  exit 1
fi
echo "Guest added to Harbor's container."
sleep 2
xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true

container=$(/usr/libexec/PlistBuddy -c 'Print :LCDataUUID' "$data/Documents/Applications/$guest_folder/LCAppInfo.plist")
report="$data/Documents/Data/Application/$container/Documents/guest-report.json"

# --- Step 2: start Harbor as the guest. The engine reads "selected" from the
# user defaults, which launch arguments feed.
xcrun simctl launch "$simulator" "$bundle_id" -selected "$guest_folder" > /dev/null
if ! wait_for 45 "$report"; then
  echo "FAILED: the guest did not report in."
  echo "Engine error, if any:"
  /usr/libexec/PlistBuddy -c 'Print :error' "$data/Library/Preferences/$bundle_id.plist" 2>/dev/null || echo "  (none recorded)"
  xcrun simctl io "$simulator" screenshot "$out/screenshot.png" > /dev/null 2>&1 || true
  exit 1
fi
sleep 3
xcrun simctl io "$simulator" screenshot "$out/screenshot.png" > /dev/null 2>&1 || true
cp "$report" "$out/guest-report.json"

echo "The guest ran. Its report:"
cat "$report"
echo

# --- What the report has to say for the engine to have done its job.
failures=0
expect() {
  # expect <description> <key> <substring>
  local value
  value=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$report" "$2")
  case "$value" in
    *"$3"*) echo "ok      $1" ;;
    *) echo "WRONG   $1: got '$value'"; failures=$((failures + 1)) ;;
  esac
}
expect "the process sees the guest's bundle identifier" bundleIdentifier com.example.harborguest
expect "the main bundle is the guest's bundle" bundlePath "Documents/Applications/$guest_folder"
expect "the executable path is the guest's" executablePath "$guest_folder/Guest"
expect "Documents is inside the guest's data container" documents "Documents/Data/Application/$container/Documents"
expect "the process is named after the guest" processName Guest
expect "Info.plist values come from the guest" infoName Guest

if [ -f "$data/Documents/Data/Application/$container/Library/Preferences/com.example.harborguest.plist" ]; then
  echo "ok      the guest's preferences went to its own container"
else
  echo "WRONG   the guest's preferences are not in its container"
  failures=$((failures + 1))
fi

# The engine moves the home directory by setting CFFIXED_USER_HOME before the
# guest starts. On the simulator NSHomeDirectory() has already settled on
# Harbor's own container by then, so this is reported, not required. What it
# returns on a device is to be checked there.
home=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("home", ""))' "$report")
case "$home" in
  *"Documents/Data/Application/$container") echo "ok      NSHomeDirectory() is the guest's container" ;;
  *) echo "note    NSHomeDirectory() is still Harbor's container on the simulator" ;;
esac

xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true
[ "$failures" = 0 ] || { echo "$failures check(s) failed."; exit 1; }
echo "All checks passed. Screenshot: $out/screenshot.png"
