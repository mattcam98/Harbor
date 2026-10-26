#!/usr/bin/env bash
# Xcode build phase for the app target.
#
# Harbor's interface framework links the Swift packages, and some of those
# bring prebuilt dynamic frameworks (OpenSSL). Xcode only embeds such
# frameworks into a target that links the package itself, and the app
# executable deliberately does not: it is a stub that must stay free of
# Harbor's code. So the frameworks the interface needs are copied in here,
# along with the tweak loader, a bare dylib the engine loads by path.
set -euo pipefail

frameworks_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
interface="$frameworks_dir/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"
mkdir -p "$frameworks_dir"

sign() {
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --generate-entitlement-der "$1"
  fi
}

tweak_loader="$BUILT_PRODUCTS_DIR/TweakLoader.dylib"
[ -f "$tweak_loader" ] || { echo "error: TweakLoader.dylib was not built into $BUILT_PRODUCTS_DIR"; exit 1; }
echo "Embedding TweakLoader.dylib"
cp -f "$tweak_loader" "$frameworks_dir/TweakLoader.dylib"
sign "$frameworks_dir/TweakLoader.dylib"

[ -f "$interface" ] || { echo "error: interface framework not found at $interface"; exit 1; }

# Every "@rpath/Name.framework/Name" the interface loads, other than itself
# and the engine, which Xcode embeds as targets of this project.
otool -L "$interface" \
  | awk '{print $1}' \
  | sed -n 's#^@rpath/\([^/]*\)\.framework/.*#\1#p' \
  | sort -u \
  | while read -r name; do
      case "$name" in
        LiveContainerSwiftUI | LiveContainerShared) continue ;;
      esac

      source="$BUILT_PRODUCTS_DIR/$name.framework"
      if [ ! -d "$source" ]; then
        echo "error: $name.framework is needed by the interface but was not built into $BUILT_PRODUCTS_DIR"
        exit 1
      fi

      echo "Embedding $name.framework"
      rsync -a --delete --exclude Headers --exclude Modules "$source" "$frameworks_dir/"
      sign "$frameworks_dir/$name.framework"
    done

# Renew Harbor, the interface's Shortcuts action (App/Intents). iOS reads an
# app's actions from Metadata.appintents at the top of the app, and only the
# app target's own; the interface's would need the stub to link it. The
# metadata names the types in full (HarborUI.RenewHarborIntent), and the
# interface is loaded before any action runs, so its copy is used as is.
intents="$frameworks_dir/LiveContainerSwiftUI.framework/Metadata.appintents"
if [ -d "$intents" ]; then
  echo "Copying the interface's App Intents metadata"
  rsync -a --delete "$intents/" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Metadata.appintents/"
fi
