#!/bin/bash
#
# Merge the per-target .a archives produced by 01-build-upstream-libs.sh into
# the consolidated lib*_maccatalyst.a files the ExecutorchLib xcodeproj links
# against, then verify each artifact is single-arch arm64 with platform
# MACCATALYST.
#
# Composition mirrors upstream's executorch/scripts/build_apple_frameworks.sh
# (FRAMEWORK_* definitions) — that's how iOS and macOS xcframeworks are built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

ET_BUILD="$BUILD_DIR/executorch/cmake-out-maccatalyst"
PTP_BUILD="$BUILD_DIR/pthreadpool/cmake-out-maccatalyst"

ET_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/executorch"
PTP_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/pthreadpool/maccatalyst-arm64-release"
CPUINFO_LIB="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a"

mkdir -p "$ET_LIBS_DIR" "$PTP_LIBS_DIR"

LIBTOOL="$(xcrun --sdk macosx --find libtool)"

# Resolve a .a basename to its absolute path inside the ExecuTorch build.
# Errors if missing or ambiguous so we fail fast on upstream layout drift.
find_lib() {
  local basename="$1"
  local matches
  matches="$(find "$ET_BUILD" -name "$basename" -type f)"
  if [ -z "$matches" ]; then
    echo "ERROR: $basename not found under $ET_BUILD" >&2
    return 1
  fi
  if [ "$(echo "$matches" | wc -l | tr -d ' ')" != "1" ]; then
    echo "ERROR: ambiguous match for $basename:" >&2
    echo "$matches" >&2
    return 1
  fi
  printf '%s' "$matches"
}

# Resolve each basename via find_lib and libtool-merge them into $1.
merge() {
  local out="$1"; shift
  local sources=()
  local name
  for name in "$@"; do
    sources+=("$(find_lib "$name")")
  done
  echo "==> $(basename "$out")"
  local s
  for s in "${sources[@]}"; do
    echo "    + ${s#$ET_BUILD/}"
  done
  rm -f "$out"
  "$LIBTOOL" -static -o "$out" "${sources[@]}"
}

# --- libexecutorch_maccatalyst.a ------------------------------------------
# Note: libextension_apple.a (Swift wrapper) is intentionally omitted on
# Catalyst — see EXECUTORCH_BUILD_EXTENSION_APPLE=OFF in 01.
merge "$ET_LIBS_DIR/libexecutorch_maccatalyst.a" \
  libexecutorch.a \
  libexecutorch_core.a \
  libextension_data_loader.a \
  libextension_flat_tensor.a \
  libextension_module.a \
  libextension_named_data_map.a \
  libextension_tensor.a

# --- libexecutorch_llm_maccatalyst.a --------------------------------------
merge "$ET_LIBS_DIR/libexecutorch_llm_maccatalyst.a" \
  libabsl_base.a \
  libabsl_city.a \
  libabsl_decode_rust_punycode.a \
  libabsl_demangle_internal.a \
  libabsl_demangle_rust.a \
  libabsl_examine_stack.a \
  libabsl_graphcycles_internal.a \
  libabsl_hash.a \
  libabsl_int128.a \
  libabsl_kernel_timeout_internal.a \
  libabsl_leak_check.a \
  libabsl_log_globals.a \
  libabsl_log_internal_check_op.a \
  libabsl_log_internal_format.a \
  libabsl_log_internal_globals.a \
  libabsl_log_internal_log_sink_set.a \
  libabsl_log_internal_message.a \
  libabsl_log_internal_nullguard.a \
  libabsl_log_internal_proto.a \
  libabsl_log_severity.a \
  libabsl_log_sink.a \
  libabsl_low_level_hash.a \
  libabsl_malloc_internal.a \
  libabsl_raw_hash_set.a \
  libabsl_raw_logging_internal.a \
  libabsl_spinlock_wait.a \
  libabsl_stacktrace.a \
  libabsl_str_format_internal.a \
  libabsl_strerror.a \
  libabsl_strings.a \
  libabsl_strings_internal.a \
  libabsl_symbolize.a \
  libabsl_synchronization.a \
  libabsl_throw_delegate.a \
  libabsl_time.a \
  libabsl_time_zone.a \
  libabsl_tracing_internal.a \
  libabsl_utf8_for_code_point.a \
  libextension_llm_runner.a \
  libpcre2-8.a \
  libre2.a \
  libregex_lookahead.a \
  libsentencepiece.a \
  libtokenizers.a

# --- libthreadpool_maccatalyst.a ------------------------------------------
merge "$ET_LIBS_DIR/libthreadpool_maccatalyst.a" \
  libcpuinfo.a \
  libextension_threadpool.a \
  libpthreadpool.a

# --- libbackend_coreml_maccatalyst.a --------------------------------------
merge "$ET_LIBS_DIR/libbackend_coreml_maccatalyst.a" \
  libcoreml_util.a \
  libcoreml_inmemoryfs.a \
  libcoremldelegate.a

# --- libbackend_mps_maccatalyst.a -----------------------------------------
merge "$ET_LIBS_DIR/libbackend_mps_maccatalyst.a" \
  libmpsdelegate.a

# --- libbackend_xnnpack_maccatalyst.a -------------------------------------
merge "$ET_LIBS_DIR/libbackend_xnnpack_maccatalyst.a" \
  libXNNPACK.a \
  libkleidiai.a \
  libxnnpack_backend.a \
  libxnnpack-microkernels-prod.a

# --- libkernels_llm_maccatalyst.a -----------------------------------------
merge "$ET_LIBS_DIR/libkernels_llm_maccatalyst.a" \
  libcustom_ops.a

# --- libkernels_optimized_maccatalyst.a -----------------------------------
merge "$ET_LIBS_DIR/libkernels_optimized_maccatalyst.a" \
  libcpublas.a \
  liboptimized_kernels.a \
  liboptimized_native_cpu_ops_lib.a \
  libportable_kernels.a

# --- libkernels_quantized_maccatalyst.a -----------------------------------
merge "$ET_LIBS_DIR/libkernels_quantized_maccatalyst.a" \
  libquantized_kernels.a \
  libquantized_ops_lib.a

# --- libkernels_torchao_maccatalyst.a -------------------------------------
merge "$ET_LIBS_DIR/libkernels_torchao_maccatalyst.a" \
  libtorchao_ops_executorch.a \
  libtorchao_kernels_aarch64.a

# --- pthreadpool (linked directly by the podspec) -------------------------
echo
echo "==> pthreadpool"
cp "$PTP_BUILD/libpthreadpool.a" "$PTP_LIBS_DIR/libpthreadpool.a"
echo "    -> $PTP_LIBS_DIR/libpthreadpool.a"

# --- Verify each staged .a ------------------------------------------------
verify() {
  local lib="$1"
  echo
  echo "==> verify $(basename "$lib")"
  local archs
  archs="$(lipo -archs "$lib" 2>&1)"
  echo "    archs: $archs"
  if [ "$archs" != "arm64" ]; then
    echo "ERROR: expected arm64 only" >&2
    exit 1
  fi
  # platform 6 == MACCATALYST. Every LC_BUILD_VERSION should reference it.
  local platform
  platform="$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{flag=1} flag && /platform/{print $2; flag=0}' | sort -u)"
  echo "    platform: $platform"
  if ! echo "$platform" | grep -qE "(^|[^0-9])6([^0-9]|$)|MACCATALYST"; then
    echo "ERROR: expected platform MACCATALYST (6); inspect with 'otool -l $lib | grep -A3 LC_BUILD_VERSION'" >&2
    exit 1
  fi
}

for f in \
  libexecutorch_maccatalyst.a \
  libexecutorch_llm_maccatalyst.a \
  libthreadpool_maccatalyst.a \
  libbackend_coreml_maccatalyst.a \
  libbackend_mps_maccatalyst.a \
  libbackend_xnnpack_maccatalyst.a \
  libkernels_llm_maccatalyst.a \
  libkernels_optimized_maccatalyst.a \
  libkernels_quantized_maccatalyst.a \
  libkernels_torchao_maccatalyst.a; do
  verify "$ET_LIBS_DIR/$f"
done
verify "$PTP_LIBS_DIR/libpthreadpool.a"

# --- cpuinfo --------------------------------------------------------------
# cpuinfo is shared with the iOS/simulator slices as a single fat lib in this
# repo. We require an arm64 slice but don't enforce platform — if linking
# fails at step 4 with a platform mismatch, rebuild cpuinfo as a fat lib
# carrying a Catalyst slice using the same flags as 01.
echo
echo "==> Verifying cpuinfo (shared between iOS / Catalyst)"
echo "    $CPUINFO_LIB"
echo "    archs: $(lipo -archs "$CPUINFO_LIB")"
if ! lipo -archs "$CPUINFO_LIB" | grep -q "arm64"; then
  echo "ERROR: $CPUINFO_LIB has no arm64 slice — rebuild it for Mac Catalyst arm64." >&2
  exit 1
fi

echo
echo "==> All Mac Catalyst static libs staged and verified."
echo "    Next: scripts/maccatalyst/03-build-xcframework.sh"
