#!/usr/bin/env bash
# Generates Harbor.xcodeproj and pins its Swift package dependencies.
#
# The project is generated, so it has no lockfile of its own. Without one
# Xcode would resolve the engines' branch-tracked dependencies to whatever
# those branches point at today. This installs the committed lockfile; build
# with -onlyUsePackageVersionsFromResolvedFile so Xcode fails instead of
# quietly resolving something else.
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init

if [ ! -f CodeSigning.xcconfig ]; then
  cp CodeSigning.xcconfig.sample CodeSigning.xcconfig
  echo "Created CodeSigning.xcconfig from the sample."
fi

xcodegen generate

lock_dir="Harbor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_dir"
cp Packages/HarborKit/Package.resolved "$lock_dir/Package.resolved"
echo "Installed dependency lockfile."
