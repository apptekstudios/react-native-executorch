#!/bin/bash
#
# Copy the Mac Catalyst .a files produced by 01-build-upstream-libs.sh into
# the in-repo locations the xcframework build expects, then verify each
# artifact is single-arch arm64 with platform == MACCATALYST.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

ET_BUILD="$BUILD_DIR/executorch/cmake-out-maccatalyst"
PTP_BUILD="$BUILD_DIR/pthreadpool/cmake-out-maccatalyst"

ET_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/executorch"
PTP_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/pthreadpool/maccatalyst-arm64-release"
CPUINFO_LIB="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a"

mkdir -p "$PTP_LIBS_DIR"

# --- Maps upstream output name -> in-repo target name ---------------------
# Adjust the left-hand side if upstream changes its CMake target names. The
# right-hand side matches the OTHER_LDFLAGS[sdk=macosx*] block in
# third-party/ios/ExecutorchLib/ExecutorchLib.xcodeproj/project.pbxproj.
declare -a STAGING=(
  "$ET_BUILD/libexecutorch.a:libexecutorch_maccatalyst.a"
  "$ET_BUILD/extension/llm/libexecutorch_llm.a:libexecutorch_llm_maccatalyst.a"
  "$ET_BUILD/backends/xnnpack/libxnnpack_backend.a:libbackend_xnnpack_maccatalyst.a"
  "$ET_BUILD/backends/apple/coreml/libcoreml_backend.a:libbackend_coreml_maccatalyst.a"
  "$ET_BUILD/backends/apple/mps/libmps_backend.a:libbackend_mps_maccatalyst.a"
  "$ET_BUILD/kernels/optimized/liboptimized_kernels.a:libkernels_optimized_maccatalyst.a"
  "$ET_BUILD/kernels/quantized/libquantized_kernels.a:libkernels_quantized_maccatalyst.a"
  "$ET_BUILD/extension/llm/custom_ops/libcustom_ops.a:libkernels_llm_maccatalyst.a"
  "$ET_BUILD/kernels/torchao/libtorchao_kernels.a:libkernels_torchao_maccatalyst.a"
  "$ET_BUILD/extension/threadpool/libextension_threadpool.a:libthreadpool_maccatalyst.a"
)

echo "==> Staging ExecuTorch libs into $ET_LIBS_DIR"
for entry in "${STAGING[@]}"; do
  src="${entry%%:*}"
  dst="${entry##*:}"
  if [ ! -f "$src" ]; then
    echo "ERROR: missing $src" >&2
    echo "       Inspect $ET_BUILD for the actual filename and update STAGING[] above." >&2
    exit 1
  fi
  cp "$src" "$ET_LIBS_DIR/$dst"
  echo "    $src"
  echo "      -> $ET_LIBS_DIR/$dst"
done

echo
echo "==> Staging pthreadpool into $PTP_LIBS_DIR"
cp "$PTP_BUILD/libpthreadpool.a" "$PTP_LIBS_DIR/libpthreadpool.a"
echo "    -> $PTP_LIBS_DIR/libpthreadpool.a"

# --- Verify each staged .a ------------------------------------------------
verify() {
  local lib="$1"
  echo
  echo "==> $lib"
  local archs
  archs="$(lipo -archs "$lib" 2>&1)"
  echo "    archs: $archs"
  if [ "$archs" != "arm64" ]; then
    echo "ERROR: expected arm64 only" >&2
    exit 1
  fi
  # platform 6 == MACCATALYST. We grep otool output for the platform line.
  local platform
  platform="$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{flag=1} flag && /platform/{print $2; flag=0}' | sort -u)"
  echo "    platform: $platform"
  if ! echo "$platform" | grep -qE "(^|[^0-9])6([^0-9]|$)|MACCATALYST"; then
    echo "ERROR: expected platform MACCATALYST (6); inspect with 'otool -l $lib | grep -A3 LC_BUILD_VERSION'" >&2
    exit 1
  fi
}

for entry in "${STAGING[@]}"; do
  dst="${entry##*:}"
  verify "$ET_LIBS_DIR/$dst"
done
verify "$PTP_LIBS_DIR/libpthreadpool.a"

# --- cpuinfo ---------------------------------------------------------------
echo
echo "==> Verifying cpuinfo (shared between iOS / Catalyst)"
echo "    $CPUINFO_LIB"
echo "    archs: $(lipo -archs "$CPUINFO_LIB")"
if ! lipo -archs "$CPUINFO_LIB" | grep -q "arm64"; then
  echo "ERROR: $CPUINFO_LIB has no arm64 slice — rebuild it for Mac Catalyst arm64." >&2
  exit 1
fi
# We deliberately don't enforce platform==MACCATALYST here: cpuinfo is used
# for both iOS and Catalyst, and the existing fat binary may legitimately
# carry an iOS platform marker. If linking fails at step 4 with a platform
# mismatch, rebuild cpuinfo as a fat lib using the same flags as 01.

echo
echo "==> All Mac Catalyst static libs staged and verified."
echo "    Next: scripts/maccatalyst/03-build-xcframework.sh"
