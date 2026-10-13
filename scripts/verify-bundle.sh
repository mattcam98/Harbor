#!/usr/bin/env bash
# Checks that a built Harbor.app contains everything it loads at run time.
#
#   verify-bundle.sh <path/to/Harbor.app>
#
# The stub loads the engine and the interface with dlopen, and the engine
# loads the tweak loader by path, so the linker never complains when one is
# missing; the app just fails to start. This fails the build instead.
set -euo pipefail

app=$1
frameworks="$app/Frameworks"
missing=0

require() {
  if [ ! -e "$1" ]; then
    echo "MISSING $2: ${1#"$app"/}"
    missing=$((missing + 1))
  fi
}

require "$frameworks/LiveContainerShared.framework/LiveContainerShared" "the engine"
require "$frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI" "the interface"
require "$frameworks/TweakLoader.dylib" "the tweak loader"

# Every library a bundled binary names by @rpath must be in the bundle.
binaries=$(find "$app" -type f \( -name '*.dylib' -o -path '*.framework/*' \) ! -name '*.plist' ! -name '*.car' 2>/dev/null)
for binary in "$app/$(basename "$app" .app)" $binaries; do
  file "$binary" 2>/dev/null | grep -q 'Mach-O' || continue
  for dependency in $(otool -L "$binary" | awk 'NR>1 {print $1}' | grep '^@rpath/' || true); do
    relative=${dependency#@rpath/}
    if [ ! -e "$frameworks/$relative" ] && [ ! -e "$app/$relative" ]; then
      echo "MISSING ${binary#"$app"/} needs $dependency"
      missing=$((missing + 1))
    fi
  done
done

if [ "$missing" -gt 0 ]; then
  echo "$missing problem(s) in $app"
  exit 1
fi
echo "Bundle is complete: $(ls "$frameworks" | tr '\n' ' ')"
