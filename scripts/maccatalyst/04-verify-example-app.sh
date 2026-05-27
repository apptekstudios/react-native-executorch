#!/bin/bash
#
# Verify the new Mac Catalyst slice links cleanly into a real consumer by
# building apps/bare-rn for both Mac Catalyst and the iOS Simulator
# (regression check).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/apps/bare-rn"

echo "==> yarn install (top-level)"
(cd "$REPO_ROOT" && yarn install --frozen-lockfile)

echo
echo "==> pod install in $APP_DIR/ios"
(cd "$APP_DIR/ios" && pod install)

WORKSPACE="$APP_DIR/ios/bare-rn.xcworkspace"
SCHEME="bare-rn"

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
    -derivedDataPath "$APP_DIR/ios/build-$label" \
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
