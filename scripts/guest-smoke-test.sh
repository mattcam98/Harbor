#!/usr/bin/env bash
# Runs a guest app inside Harbor on the iOS Simulator and checks that it
# really ran as itself.
#
# Builds Harbor and a tiny guest app for the simulator, has Harbor add the
# guest to its container, then starts Harbor as that guest and reads the
# report the guest writes about its own process. A screenshot is saved to
# build/guest-smoke/screenshot.png.
#
# A second guest is then run the same way: an app from before scenes, marked
# as built with an older SDK, which is what most real apps are. iOS stops
# such an app at launch unless the engine reports the guest's SDK version in
# place of Harbor's.
#
# Last, the guests are run beside Harbor: each in a process of its own, with
# Harbor's interface still alive underneath. One is started directly and one
# through the link a Home Screen shortcut opens.
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
bundle_id=${bundle_id:-com.example.harbor}
guest_folder=com.example.harborguest.app

echo "Simulator $simulator, Harbor bundle $bundle_id"

# --- Build the guest and package it as an IPA.
mkdir -p "$out/ipa/Payload/Guest.app"
# The header padding leaves room for the tweak loader's load command, as a
# device build and nearly every real app has. Without it the guest takes the
# engine's other path and the injected one goes untested.
xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc -fmodules -Wl,-headerpad,0x1000 \
  scripts/fixtures/guest/main.m -o "$out/ipa/Payload/Guest.app/Guest"
cp scripts/fixtures/guest/Info.plist "$out/ipa/Payload/Guest.app/Info.plist"
(cd "$out/ipa" && zip -qry ../Guest.ipa Payload)
guest_ipa="$(pwd)/$out/Guest.ipa"

# --- The second guest: no scenes, and an older SDK written into the binary
# (platform 7 is the iOS Simulator; 17.0 is both the minimum and the SDK).
legacy_folder=com.example.harborlegacy.app
legacy_sdk=1114112  # 17.0 as dyld writes it: 0x00110000
mkdir -p "$out/legacy/Payload/Legacy.app"
xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc -fmodules -Wl,-headerpad,0x1000 -DLEGACY_LIFECYCLE=1 \
  scripts/fixtures/guest/main.m -o "$out/legacy/Guest.built"
xcrun vtool -set-build-version 7 17.0 17.0 -replace \
  -output "$out/legacy/Payload/Legacy.app/Guest" "$out/legacy/Guest.built" > "$out/vtool.log" 2>&1
cp scripts/fixtures/guest/Info.plist "$out/legacy/Payload/Legacy.app/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Delete :UIApplicationSceneManifest' \
  -c 'Set :CFBundleIdentifier com.example.harborlegacy' \
  -c 'Set :CFBundleDisplayName Legacy Guest' \
  "$out/legacy/Payload/Legacy.app/Info.plist"
(cd "$out/legacy" && zip -qry ../Legacy.ipa Payload)
legacy_ipa="$(pwd)/$out/Legacy.ipa"

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
if /usr/libexec/PlistBuddy -c 'Print :dontInjectTweakLoader' "$data/Documents/Applications/$guest_folder/LCAppInfo.plist" > /dev/null 2>&1; then
  echo "FAILED: the guest was installed without the tweak loader, which is not the path a device takes."
  exit 1
fi
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

if [ -e "$data/Documents/Tweaks/TweakLoader.dylib" ]; then
  echo "ok      the engine linked its tweak loader where the guest loads it from"
else
  echo "WRONG   Documents/Tweaks/TweakLoader.dylib is missing or points nowhere"
  failures=$((failures + 1))
fi

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

# --- The second guest: added, then started.
xcrun simctl launch "$simulator" "$bundle_id" -HarborAddGuest "$legacy_ipa" > /dev/null
legacy_info="$data/Documents/Applications/$legacy_folder/LCAppInfo.plist"
if ! wait_for 60 "$legacy_info"; then
  echo "FAILED: Harbor did not add the second guest."
  exit 1
fi
sleep 2
xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true

reported=$(/usr/libexec/PlistBuddy -c 'Print :spoofSDKVersion' "$legacy_info" 2>/dev/null || echo nothing)
if [ "$reported" = "$legacy_sdk" ]; then
  echo "ok      Harbor recorded the SDK the older app was built with"
else
  echo "WRONG   Harbor recorded $reported as the older app's SDK, not $legacy_sdk"
  failures=$((failures + 1))
fi

legacy_container=$(/usr/libexec/PlistBuddy -c 'Print :LCDataUUID' "$legacy_info")
alive="$data/Documents/Data/Application/$legacy_container/Documents/guest-alive.txt"
xcrun simctl launch "$simulator" "$bundle_id" -selected "$legacy_folder" > /dev/null
if wait_for 30 "$alive"; then
  echo "ok      an app from before scenes, built with an older SDK, starts and keeps running"
else
  echo "WRONG   the app from before scenes did not stay running"
  echo "        Engine error, if any: $(/usr/libexec/PlistBuddy -c 'Print :error' "$data/Library/Preferences/$bundle_id.plist" 2>/dev/null || echo none recorded)"
  failures=$((failures + 1))
fi
xcrun simctl io "$simulator" screenshot "$out/screenshot-legacy.png" > /dev/null 2>&1 || true
xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true

# --- Beside Harbor: the first guest in a process of its own.
first_documents="$data/Documents/Data/Application/$container/Documents"
rm -f "$first_documents/guest-alive.txt" "$first_documents/guest-report.json" "$alive"
# The link is the one a Home Screen shortcut for the second guest opens.
xcrun simctl launch "$simulator" "$bundle_id" -HarborRunBeside "$guest_folder" \
  -HarborOpenLink "harbor://livecontainer-launch?bundle-name=$legacy_folder" > /dev/null
if wait_for 30 "$first_documents/guest-alive.txt"; then
  echo "ok      a guest starts beside Harbor and keeps running"
else
  echo "WRONG   the guest did not run beside Harbor"
  failures=$((failures + 1))
fi
if pgrep -f "Harbor.app/Harbor" > /dev/null && pgrep -f "LiveProcess.appex/LiveProcess" > /dev/null; then
  echo "ok      Harbor is still running, and the guest has a process of its own"
else
  echo "WRONG   expected both Harbor and the guest's process to be running"
  failures=$((failures + 1))
fi
# The guest's home is the extension's sandbox, not Harbor's container: it
# is handed its own folders and nothing else of Harbor's.
beside_home=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("home", ""))' "$first_documents/guest-report.json" 2>/dev/null || true)
case "$beside_home" in
  *PluginKitPlugin*) echo "ok      the guest's process is outside Harbor's own container" ;;
  *) echo "WRONG   the guest's home is '$beside_home', not the extension's"; failures=$((failures + 1)) ;;
esac
sleep 1

# --- The shortcut's link, acted on with the first guest already running:
# the second guest opens too, and the first is not disturbed.
if wait_for 30 "$alive"; then
  echo "ok      a Home Screen shortcut's link opens its app beside the one already open"
else
  echo "WRONG   the shortcut link did not open the second guest"
  failures=$((failures + 1))
fi
running=$(pgrep -f "LiveProcess.appex/LiveProcess" | wc -l | tr -d ' ')
if [ "$running" = 2 ]; then
  echo "ok      two guests are running at once"
else
  echo "WRONG   expected two guest processes, found $running"
  failures=$((failures + 1))
fi
sleep 1
xcrun simctl io "$simulator" screenshot "$out/screenshot-beside.png" > /dev/null 2>&1 || true
xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true

[ "$failures" = 0 ] || { echo "$failures check(s) failed."; exit 1; }
echo "All checks passed. Screenshot: $out/screenshot.png"
