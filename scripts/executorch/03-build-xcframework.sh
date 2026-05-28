#!/bin/bash
#
# Regenerate ExecutorchLib.xcframework with all three slices (ios-arm64,
# ios-arm64-simulator, ios-arm64-maccatalyst). Wraps
# third-party/ios/ExecutorchLib/build.sh and verifies the resulting Info.plist
# contains every expected entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/ExecutorchLib"
XCFRAMEWORK_DST="$REPO_ROOT/packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework"

echo "==> Running ExecutorchLib build.sh (iOS + iOS Simulator + Mac Catalyst)"
(cd "$LIB_DIR" && ./build.sh)

BUILT_XCF="$LIB_DIR/output/ExecutorchLib.xcframework"
if [ ! -d "$BUILT_XCF" ]; then
  echo "ERROR: build.sh did not produce $BUILT_XCF" >&2
  exit 1
fi

echo "==> Replacing $XCFRAMEWORK_DST"
rm -rf "$XCFRAMEWORK_DST"
cp -R "$BUILT_XCF" "$XCFRAMEWORK_DST"

echo
echo "==> Inspecting Info.plist"
PLIST="$XCFRAMEWORK_DST/Info.plist"
plutil -p "$PLIST"

echo
echo "==> Verifying all three slices are present"
for slot in ios-arm64 ios-arm64-simulator ios-arm64-maccatalyst; do
  if ! plutil -p "$PLIST" | grep -q "\"LibraryIdentifier\" => \"$slot\""; then
    echo "ERROR: Info.plist is missing the $slot entry." >&2
    exit 1
  fi
  echo "    + $slot"
done

echo
echo "==> ExecutorchLib.xcframework updated with all three slices."
echo "    Commit $XCFRAMEWORK_DST and the in-repo edits, then proceed to:"
echo "    scripts/executorch/04-verify-example-app.sh"
