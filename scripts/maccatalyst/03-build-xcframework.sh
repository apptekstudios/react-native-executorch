#!/bin/bash
#
# Regenerate ExecutorchLib.xcframework with the new ios-arm64-maccatalyst
# slice. Wraps third-party/ios/ExecutorchLib/build.sh and verifies the
# resulting Info.plist contains the catalyst entry.

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

if ! plutil -p "$PLIST" | grep -q '"LibraryIdentifier" => "ios-arm64-maccatalyst"'; then
  echo "ERROR: Info.plist is missing the ios-arm64-maccatalyst entry." >&2
  echo "       Confirm SUPPORTS_MACCATALYST=YES took effect during xcodebuild archive." >&2
  exit 1
fi

echo
echo "==> ExecutorchLib.xcframework updated with the maccatalyst slice."
echo "    Commit $XCFRAMEWORK_DST and the in-repo edits, then proceed to:"
echo "    scripts/maccatalyst/04-verify-example-app.sh"
