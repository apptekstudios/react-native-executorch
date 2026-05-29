#!/bin/bash
#
# Re-run `pod install` for every example app under apps/ so each Pods/
# project picks up the freshly-rebuilt ExecutorchLib.xcframework and the
# *.a archives under packages/react-native-executorch/third-party/ios/libs/.
# Then print one `open` command per app's .xcworkspace so they can be
# launched into Xcode in a single copy-paste batch.
#
# Run from anywhere; paths resolve relative to this script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPS_DIR="$REPO_ROOT/apps"

if [ ! -d "$APPS_DIR" ]; then
  echo "ERROR: apps directory not found at $APPS_DIR" >&2
  exit 1
fi

declare -a workspaces=()

for app_dir in "$APPS_DIR"/*/; do
  app_name="$(basename "$app_dir")"
  ios_dir="${app_dir}ios"

  if [ ! -f "$ios_dir/Podfile" ]; then
    # Skip anything that isn't a real iOS-enabled RN app (e.g. helper dirs).
    continue
  fi

  echo
  echo "############################################################"
  echo "# pod install: $app_name"
  echo "############################################################"
  (cd "$ios_dir" && pod install)

  workspace="$(find "$ios_dir" -maxdepth 1 -name "*.xcworkspace" -type d | head -n 1)"
  if [ -z "$workspace" ]; then
    echo "WARN: no .xcworkspace produced under $ios_dir" >&2
    continue
  fi
  workspaces+=("$workspace")
done

if [ "${#workspaces[@]}" -eq 0 ]; then
  echo
  echo "No example apps with a Podfile were found under $APPS_DIR." >&2
  exit 1
fi

echo
echo "==> All example app pods reinstalled."
echo
echo "Open in Xcode:"
for ws in "${workspaces[@]}"; do
  printf '  open %q\n' "$ws"
done
