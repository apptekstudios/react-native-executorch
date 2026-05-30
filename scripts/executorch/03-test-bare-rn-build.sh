#!/bin/bash
#
# Verify the rebuilt ExecutorchLib.xcframework links cleanly into a real
# consumer by building apps/bare-rn for both Mac Catalyst and the iOS
# Simulator.
#
# This script is fully self-contained — it does not assume
# 02-reinstall-pods-for-example-apps.sh has been run first. It runs
# `yarn install` at the repo root, `pod install` inside apps/bare-rn/ios/,
# wipes the local Xcode build dir so the link step picks up the freshly
# rebuilt static archives, then runs `xcodebuild` for both slices.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/apps/bare-rn"
WORKSPACE="$APP_DIR/ios/bare-rn.xcworkspace"
SCHEME="bare-rn"

if [ ! -d "$APP_DIR/ios" ]; then
  echo "ERROR: $APP_DIR/ios not found — check the apps layout." >&2
  exit 1
fi

echo "==> yarn install (top-level)"
(cd "$REPO_ROOT" && yarn install --frozen-lockfile)

echo
echo "==> pod install in $APP_DIR/ios"
# Always reinstall pods so the Pods project re-links against whatever the
# `01-build.sh` run just produced. Cheap and idempotent on a no-op; safe to
# run even if 02-reinstall-pods-for-example-apps.sh already touched this app.
(cd "$APP_DIR/ios" && pod install)

echo
echo "==> Clearing $APP_DIR/ios/build so xcodebuild relinks against fresh libs"
# Xcode's DerivedData caches the linked binary at the object-file level. If
# the `.a` archives under third-party/ios/libs/ change between runs, the
# cached objects still reference the old symbols and the build silently
# produces a binary that doesn't include the new code.
rm -rf "$APP_DIR/ios/build"

run_build() {
  local destination="$1"
  local label="$2"
  echo
  echo "==> xcodebuild build ($label) — destination: $destination"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$APP_DIR/ios/build/$label" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

run_build "platform=macOS,variant=Mac Catalyst,arch=arm64" "maccatalyst"
run_build "generic/platform=iOS Simulator" "iossim"

echo
echo "==> Both Mac Catalyst and iOS Simulator builds succeeded."
echo
echo "Manual runtime check (do this once, on your Mac):"
echo "  1. open $WORKSPACE"
echo "  2. Select the 'bare-rn' scheme and 'My Mac (Mac Catalyst)' as the run destination."
echo "  3. Run the app; trigger one of the example flows (LLM, ExecutorchModule)."
echo "  4. Compare the inference output to an iOS Simulator run of the same flow."
