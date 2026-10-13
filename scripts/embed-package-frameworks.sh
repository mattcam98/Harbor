#!/usr/bin/env bash
# Xcode build phase for the app target.
#
# Harbor's interface framework links the Swift packages, and some of those
# bring prebuilt dynamic frameworks (OpenSSL). Xcode only embeds such
# frameworks into a target that links the package itself, and the app
# executable deliberately does not: it is a stub that must stay free of
# Harbor's code. So the frameworks the interface needs are copied in here.
set -euo pipefail

frameworks_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
interface="$frameworks_dir/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"

[ -f "$interface" ] || { echo "error: interface framework not found at $interface"; exit 1; }

# Every "@rpath/Name.framework/Name" the interface loads, other than itself.
otool -L "$interface" \
  | awk '{print $1}' \
  | sed -n 's#^@rpath/\([^/]*\)\.framework/.*#\1#p' \
  | sort -u \
  | while read -r name; do
      [ "$name" = LiveContainerSwiftUI ] && continue
      [ -d "$frameworks_dir/$name.framework" ] && [ "$name" = LiveContainerShared ] && continue

      source="$BUILT_PRODUCTS_DIR/$name.framework"
      if [ ! -d "$source" ]; then
        echo "error: $name.framework is needed by the interface but was not built into $BUILT_PRODUCTS_DIR"
        exit 1
      fi

      echo "Embedding $name.framework"
      rsync -a --delete --exclude Headers --exclude Modules "$source" "$frameworks_dir/"

      if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
          --generate-entitlement-der "$frameworks_dir/$name.framework"
      fi
    done
