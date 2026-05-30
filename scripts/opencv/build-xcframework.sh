#!/usr/bin/env bash
#
# Rebuild packages/react-native-executorch/third-party/ios/opencv2.xcframework
# with iOS device + simulator + Mac Catalyst slices, then commit it.
#
# This replaces the external `opencv-rne` pod (~> 4.11.0) that the podspecs
# used to depend on — that pod ships only iOS device + simulator slices,
# so Mac Catalyst builds failed at the "[CP] Copy XCFrameworks" phase.
#
# Run from anywhere; paths resolve relative to this script's location.

set -euo pipefail

# 4.13.0 (vs. the old pod's 4.11.0) picks up the gen_objc.py /private/var
# path-filter fix from https://github.com/opencv/opencv/pull/26713, without
# which the iOS Obj-C bindings for imgproc are silently skipped when
# building under /private/tmp.
OPENCV_TAG="${OPENCV_TAG:-4.13.0}"

# Default archs match the rest of this repo's arm64-only policy
# (EXCLUDED_ARCHS[sdk=iphonesimulator*]=x86_64 in the podspec). Override
# per-slice via env if you need x86_64 for some host configuration.
IPHONEOS_ARCHS="${IPHONEOS_ARCHS:-arm64}"
IPHONESIMULATOR_ARCHS="${IPHONESIMULATOR_ARCHS:-arm64}"
CATALYST_ARCHS="${CATALYST_ARCHS:-arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
OPENCV_SRC="$BUILD_DIR/opencv"
OPENCV_BUILD="$BUILD_DIR/opencv-xcframework-out"
OUT_XCFRAMEWORK="$REPO_ROOT/packages/react-native-executorch/third-party/ios/opencv2.xcframework"

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "error: $PYTHON not found on PATH (set PYTHON=... to override)" >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "error: Xcode command-line tools not installed (run 'xcode-select --install')" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found on PATH (run 'brew install cmake')" >&2
  exit 1
fi

# OpenCV's gen_objc.py / gen2.py use a `#!/usr/bin/env python` shebang.
# On macOS only `python3` exists by default, and xcodebuild script phases
# don't inherit our PYTHON override — so we expose a `python` shim on PATH.
if ! command -v python >/dev/null 2>&1; then
  SHIM_DIR="$(mktemp -d)"
  trap 'rm -rf "$SHIM_DIR"' EXIT
  ln -sf "$(command -v "$PYTHON")" "$SHIM_DIR/python"
  PATH="$SHIM_DIR:$PATH"
  export PATH
  echo "==> Added python -> $PYTHON shim at $SHIM_DIR"
fi

mkdir -p "$BUILD_DIR"

echo "==> Building opencv2.xcframework"
echo "    OpenCV    : $OPENCV_TAG"
echo "    archs/ios : $IPHONEOS_ARCHS"
echo "    archs/sim : $IPHONESIMULATOR_ARCHS"
echo "    archs/cat : $CATALYST_ARCHS"
echo "    source    : $OPENCV_SRC"
echo "    build     : $OPENCV_BUILD"
echo "    output    : $OUT_XCFRAMEWORK"
echo

if [ -d "$OPENCV_SRC/.git" ]; then
  echo "==> Reusing existing checkout, fetching tag $OPENCV_TAG"
  git -C "$OPENCV_SRC" fetch --depth 1 origin "refs/tags/$OPENCV_TAG:refs/tags/$OPENCV_TAG"
  git -C "$OPENCV_SRC" checkout --force "$OPENCV_TAG"
  git -C "$OPENCV_SRC" clean -fdx
else
  echo "==> Cloning OpenCV $OPENCV_TAG into $OPENCV_SRC"
  rm -rf "$OPENCV_SRC"
  git clone --depth 1 --branch "$OPENCV_TAG" https://github.com/opencv/opencv.git "$OPENCV_SRC"
fi

echo "==> Cleaning previous build output"
rm -rf "$OPENCV_BUILD"

echo "==> Building xcframework (this takes a while)"
# Module exclusions match what the existing opencv-rne pod shipped — keeps
# core + imgproc + imgcodecs etc., drops modules this repo doesn't link.
# `<opencv2/opencv.hpp>` (the umbrella header used across the codebase) is
# guarded per-module so excluded modules don't break consumers.
(
  cd "$OPENCV_SRC"
  "$PYTHON" platforms/apple/build_xcframework.py \
    --out "$OPENCV_BUILD" \
    --iphoneos_archs "$IPHONEOS_ARCHS" \
    --iphonesimulator_archs "$IPHONESIMULATOR_ARCHS" \
    --catalyst_archs "$CATALYST_ARCHS" \
    --build_only_specified_archs \
    --without dnn --without ml --without video --without videoio \
    --without highgui --without photo --without stitching \
    --without objdetect --without features2d --without calib3d \
    --without flann --without gapi \
    --without objc \
    --disable KLEIDICV
  # --without objc drops OpenCV's auto-generated Obj-C bindings (MatConverters,
  # Mat.mm, etc.). They include UIImage <-> cv::Mat helpers (MatToUIImage /
  # UIImageToMat) whose C++ implementations OpenCV only compiles when
  # CMAKE_SYSTEM_NAME == iOS, which is false for Catalyst (SDKROOT=macosx) —
  # so on Catalyst the Obj-C wrappers reference undefined symbols. The bridge
  # uses raw C++ cv::Mat directly and doesn't need the Obj-C surface.
  # KLEIDICV is ARM's optimized vision HAL. Its source uses `-mllvm
  # -inline-threshold=10000`, which clang rejects under `-fembed-bitcode`
  # (OpenCV's Catalyst build path injects bitcode flags). We don't need
  # this perf-only library — disabling it drops one source of build pain
  # without losing any imgproc/core API the consumers use.
)

if [ ! -d "$OPENCV_BUILD/opencv2.xcframework" ]; then
  echo "error: build did not produce $OPENCV_BUILD/opencv2.xcframework" >&2
  exit 1
fi

echo
echo "==> Replacing $OUT_XCFRAMEWORK"
rm -rf "$OUT_XCFRAMEWORK"
mkdir -p "$(dirname "$OUT_XCFRAMEWORK")"
cp -R "$OPENCV_BUILD/opencv2.xcframework" "$OUT_XCFRAMEWORK"

echo
echo "==> Slices in the new xcframework:"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$OUT_XCFRAMEWORK/Info.plist" \
  | grep -E "LibraryIdentifier|SupportedPlatform" | sed 's/^/    /'

echo
echo "==> Done. Review and commit with:"
echo "    git add $OUT_XCFRAMEWORK"
echo "    git commit -m 'opencv: vendor opencv2.xcframework with maccatalyst slice'"
