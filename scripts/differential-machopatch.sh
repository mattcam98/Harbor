#!/usr/bin/env bash
# Checks Harbor's Swift executable patcher against LiveContainer's original.
#
# Builds real iOS arm64 executables, patches copies of them with
# LiveContainer's LCPatchExecSlice (compiled from the pinned submodule), and
# runs the HarborCore tests that patch the same inputs and compare the bytes.
# macOS with Xcode only.
set -euo pipefail
cd "$(dirname "$0")/.."

fixtures=${1:-$(mktemp -d)}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

source_repo=Vendor/LiveContainer
source_file=LiveContainer/LCMachOUtils.m
# The extraction below is by line number, so it is tied to this exact file.
expected_blob=54daa2dc8c6c7159dbbf71df19b0bb2681624996

actual_blob=$(git -C "$source_repo" rev-parse "HEAD:$source_file")
if [ "$actual_blob" != "$expected_blob" ]; then
  echo "LCMachOUtils.m changed ($actual_blob); review the port and update this script." >&2
  exit 1
fi

# rnd32 (lines 8-11) and everything from get_chained_fixups_seg_count to the
# end of LCPatchExecSlice (lines 34-235), exactly as upstream wrote them.
git -C "$source_repo" show "HEAD:$source_file" | sed -n '8,11p;34,235p' > "$build/lc_patch_extract.inc"
git -C "$source_repo" show "HEAD:LiveContainer/LCMachOUtils.h" > "$build/LCMachOUtils.h"

clang -fmodules -fobjc-arc -Wno-everything -I "$build" \
  scripts/differential/harness.m -o "$build/harness"

printf '#include <stdio.h>\nint main(void) { puts("guest"); return 0; }\n' > "$build/guest.c"

# "roomy" has header padding for both new load commands; "tight" has the
# linker's default, which forces the fallback paths.
build_guest() {
  local variant=$1
  shift
  mkdir -p "$fixtures/$variant"
  xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 "$@" \
    "$build/guest.c" -o "$fixtures/$variant/guest"

  for inject in 1 0; do
    mkdir -p "$fixtures/$variant/lc-$inject"
    cp "$fixtures/$variant/guest" "$fixtures/$variant/lc-$inject/guest"
    "$build/harness" "$fixtures/$variant/lc-$inject/guest" "$inject" \
      | tail -1 > "$fixtures/$variant/lc-$inject/result"
    echo "$variant inject=$inject -> LiveContainer result $(cat "$fixtures/$variant/lc-$inject/result")"
  done
}

build_guest roomy -Wl,-headerpad,0x400
build_guest tight

output=$(cd Packages/HarborCore && HARBOR_MACHO_FIXTURES="$fixtures" swift test --filter DifferentialPatchTests 2>&1) || {
  echo "$output"
  exit 1
}
echo "$output" | tail -25

# A skipped suite also "passes"; make sure the comparison really ran.
if ! echo "$output" | grep -q "Suite DifferentialPatchTests passed"; then
  echo "The differential tests did not run." >&2
  exit 1
fi
