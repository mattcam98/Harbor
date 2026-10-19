#!/usr/bin/env bash
# Builds and tests Harbor on a Mac: everything the CI workflow does, locally.
#
#   scripts/check.sh              run every stage
#   scripts/check.sh core app     run only the named stages
#
# Stages:
#   core          HarborCore unit tests
#   platform      HarborPlatform unit tests
#   signing       HarborSigning unit tests (pinned dependency revisions)
#   device        HarborDevice unit tests on an iOS Simulator
#   app           the app and its tests on an iOS Simulator
#   differential  the Mach-O patcher against LiveContainer's original
#   guest         a guest app added to Harbor and run inside it on a simulator
#   ipa           an unsigned device build, packaged as dist/Harbor.ipa
#   setup         Harbor Setup's unit tests, and a build of both its halves
#
# Each stage's full output goes to build/check-logs/<stage>.log. A failed
# stage prints its distinct error lines; the script exits non-zero if any
# stage failed. Needs Xcode and XcodeGen (brew install xcodegen).
set -uo pipefail
cd "$(dirname "$0")/.."

all_stages="core platform signing device app differential guest ipa setup"
stages=${*:-$all_stages}

logs=build/check-logs
mkdir -p "$logs"

for tool in xcodebuild swift git; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Install Xcode and its command line tools."; exit 2; }
done

simulator=""
need_simulator() {
  if [ -z "$simulator" ]; then
    simulator=$(bash scripts/pick-simulator.sh) || exit 2
  fi
}

project_ready=0
need_project() {
  if [ "$project_ready" = 0 ]; then
    command -v xcodegen >/dev/null || { echo "Missing xcodegen: brew install xcodegen"; exit 2; }
    bash scripts/generate-project.sh > "$logs/generate-project.log" 2>&1 || {
      echo "Project generation failed; see $logs/generate-project.log"
      tail -20 "$logs/generate-project.log"
      exit 2
    }
    project_ready=1
  fi
}

stage_core() {
  (cd Packages/HarborCore && swift test)
}

stage_platform() {
  (cd Packages/HarborPlatform && swift test)
}

stage_signing() {
  # SideSign tracks some dependencies by branch. Refuse to build with
  # anything other than the revisions recorded in Package.resolved.
  (cd Packages/HarborSigning && swift test --force-resolved-versions)
}

stage_device() {
  need_simulator
  # minimuxer's prebuilt frameworks only link through Xcode's build system.
  (cd Packages/HarborDevice && xcodebuild test \
    -scheme HarborDevice \
    -destination "platform=iOS Simulator,id=$simulator" \
    -onlyUsePackageVersionsFromResolvedFile)
}

stage_app() {
  need_project
  need_simulator
  xcodebuild test \
    -project Harbor.xcodeproj \
    -scheme Harbor \
    -destination "platform=iOS Simulator,id=$simulator" \
    -onlyUsePackageVersionsFromResolvedFile
}

stage_differential() {
  bash scripts/differential-machopatch.sh
}

stage_guest() {
  bash scripts/guest-smoke-test.sh
}

stage_setup() {
  # Rust from Homebrew's rustup is not on the default PATH.
  export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
  command -v cargo > /dev/null || { echo "Missing cargo. Install Rust: brew install rustup && rustup default stable"; return 1; }
  (cd Setup && cargo test --locked && cargo build --locked) || return 1
  (cd Packages/HarborSigning && swift build --force-resolved-versions --product harbor-setup-mac)
}

stage_ipa() {
  need_project
  xcodebuild build \
    -project Harbor.xcodeproj \
    -scheme Harbor \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath build/device \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO || return 1
  mkdir -p dist
  bash scripts/package-ipa.sh build/device/Build/Products/Release-iphoneos/Harbor.app dist/Harbor.ipa
}

# The lines worth reading from a failed stage's log.
show_errors() {
  grep -E 'error:|error |✘|recorded an issue|\*\* [A-Z ]*FAILED \*\*|fatal error|Undefined symbols|ld: |did not run' "$1" \
    | grep -vE 'Compiling|warning:|note:' \
    | sed -E "s#$(pwd)/##g" \
    | awk '!seen[$0]++' \
    | cut -c1-400 \
    | head -40
}

echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Commit: $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (with local changes)')"
echo

failed=""
for stage in $stages; do
  case " $all_stages " in
    *" $stage "*) ;;
    *) echo "Unknown stage: $stage"; exit 2 ;;
  esac

  printf '%-14s ' "$stage"
  started=$(date +%s)
  if "stage_$stage" > "$logs/$stage.log" 2>&1; then
    echo "ok      ($(( $(date +%s) - started ))s)"
    grep -E 'Test run with [0-9]+ tests|Executed [1-9][0-9]* tests|^(ok|note|WRONG) ' "$logs/$stage.log" | tail -9 | sed 's/^/               /'
  else
    echo "FAILED  ($(( $(date +%s) - started ))s)"
    show_errors "$logs/$stage.log" | sed 's/^/    /'
    failed="$failed $stage"
  fi
done

echo
if [ -n "$failed" ]; then
  echo "Failed:$failed"
  echo "Full logs are in $logs/"
  exit 1
fi
echo "All stages passed."
