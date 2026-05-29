#!/bin/bash
#
# Merge the per-target .a archives produced by 01-build-upstream-libs.sh into
# the consolidated lib*_{ios,simulator,maccatalyst}.a files the ExecutorchLib
# xcodeproj links against, then verify each artifact is single-arch arm64
# with the right Mach-O platform.
#
# Composition mirrors upstream's executorch/scripts/build_apple_frameworks.sh
# (FRAMEWORK_* definitions) — that's how iOS and macOS xcframeworks are built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

ET_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/executorch"
PTP_LIBS_BASE="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/pthreadpool"
CPUINFO_LIB="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a"

mkdir -p "$ET_LIBS_DIR"

LIBTOOL="$(xcrun --sdk macosx --find libtool)"

# Resolve a .a basename to its absolute path inside the per-platform build.
# Errors if missing or ambiguous so we fail fast on upstream layout drift.
find_lib() {
  local et_build="$1"
  local basename="$2"
  local matches
  matches="$(find "$et_build" -name "$basename" -type f)"
  if [ -z "$matches" ]; then
    echo "ERROR: $basename not found under $et_build" >&2
    return 1
  fi
  if [ "$(echo "$matches" | wc -l | tr -d ' ')" != "1" ]; then
    echo "ERROR: ambiguous match for $basename:" >&2
    echo "$matches" >&2
    return 1
  fi
  printf '%s' "$matches"
}

# Resolve each basename via find_lib and libtool-merge them into $out.
# Args: et_build out basename...
merge() {
  local et_build="$1"; shift
  local out="$1"; shift
  local sources=()
  local name
  for name in "$@"; do
    sources+=("$(find_lib "$et_build" "$name")")
  done
  echo "==> $(basename "$out")"
  local s
  for s in "${sources[@]}"; do
    echo "    + ${s#$et_build/}"
  done
  rm -f "$out"
  "$LIBTOOL" -static -o "$out" "${sources[@]}"
}

# Verify a single .a is single-arch arm64 and on the expected Mach-O platform.
# Args: lib_path expected_platform_code expected_platform_name
verify() {
  local lib="$1"
  local expected_code="$2"
  local expected_name="$3"
  echo
  echo "==> verify $(basename "$lib")"
  local archs
  archs="$(lipo -archs "$lib" 2>&1)"
  echo "    archs: $archs"
  if [ "$archs" != "arm64" ]; then
    echo "ERROR: expected arm64 only" >&2
    exit 1
  fi
  local platform
  platform="$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{flag=1} flag && /platform/{print $2; flag=0}' | sort -u)"
  echo "    platform: $platform (want $expected_code / $expected_name)"
  if ! echo "$platform" | grep -qE "(^|[^0-9])${expected_code}([^0-9]|$)|${expected_name}"; then
    echo "ERROR: expected platform $expected_name ($expected_code); inspect with 'otool -l $lib | grep -A3 LC_BUILD_VERSION'" >&2
    exit 1
  fi
}

# --- Per-platform staging --------------------------------------------------
# Args: name (ios/simulator/maccatalyst)
stage_platform() {
  local name="$1"
  local et_build="$BUILD_DIR/executorch/cmake-out-$name"
  local ptp_build="$BUILD_DIR/pthreadpool/cmake-out-$name"

  if [ ! -d "$et_build" ]; then
    echo "ERROR: ExecuTorch build for $name not found at $et_build" >&2
    echo "       Run 01-build-upstream-libs.sh first." >&2
    exit 1
  fi
  if [ ! -d "$ptp_build" ]; then
    echo "ERROR: pthreadpool build for $name not found at $ptp_build" >&2
    exit 1
  fi

  echo
  echo "############################################################"
  echo "# Staging $name slice"
  echo "############################################################"

  # libexecutorch_<name>.a — core ExecuTorch + module/extension archives.
  # Note: libextension_apple.a (Swift wrapper) is intentionally omitted —
  # see EXECUTORCH_BUILD_EXTENSION_APPLE=OFF in 01.
  merge "$et_build" "$ET_LIBS_DIR/libexecutorch_${name}.a" \
    libexecutorch.a \
    libexecutorch_core.a \
    libextension_data_loader.a \
    libextension_flat_tensor.a \
    libextension_module.a \
    libextension_named_data_map.a \
    libextension_tensor.a

  # libexecutorch_llm_<name>.a — LLM runner + tokenizers + abseil + sentencepiece.
  merge "$et_build" "$ET_LIBS_DIR/libexecutorch_llm_${name}.a" \
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
    libextension_memory_allocator.a \
    libpcre2-8.a \
    libre2.a \
    libregex_lookahead.a \
    libsentencepiece.a \
    libtokenizers.a

  # libthreadpool_<name>.a — cpuinfo + extension_threadpool + pthreadpool.
  merge "$et_build" "$ET_LIBS_DIR/libthreadpool_${name}.a" \
    libcpuinfo.a \
    libextension_threadpool.a \
    libpthreadpool.a

  merge "$et_build" "$ET_LIBS_DIR/libbackend_coreml_${name}.a" \
    libcoreml_util.a \
    libcoreml_inmemoryfs.a \
    libcoremldelegate.a

  merge "$et_build" "$ET_LIBS_DIR/libbackend_mps_${name}.a" \
    libmpsdelegate.a

  merge "$et_build" "$ET_LIBS_DIR/libbackend_xnnpack_${name}.a" \
    libXNNPACK.a \
    libkleidiai.a \
    libxnnpack_backend.a \
    libxnnpack-microkernels-prod.a

  merge "$et_build" "$ET_LIBS_DIR/libkernels_llm_${name}.a" \
    libcustom_ops.a

  merge "$et_build" "$ET_LIBS_DIR/libkernels_optimized_${name}.a" \
    libcpublas.a \
    liboptimized_kernels.a \
    liboptimized_native_cpu_ops_lib.a \
    libportable_kernels.a

  merge "$et_build" "$ET_LIBS_DIR/libkernels_quantized_${name}.a" \
    libquantized_kernels.a \
    libquantized_ops_lib.a

  merge "$et_build" "$ET_LIBS_DIR/libkernels_torchao_${name}.a" \
    libtorchao_ops_executorch.a \
    libtorchao_kernels_aarch64.a

  # pthreadpool standalone (linked directly by the podspec). Per-platform
  # subdir under the existing layout.
  local ptp_dst_dir
  case "$name" in
    ios)         ptp_dst_dir="$PTP_LIBS_BASE/physical-arm64-release" ;;
    simulator)   ptp_dst_dir="$PTP_LIBS_BASE/simulator-arm64-debug" ;;
    maccatalyst) ptp_dst_dir="$PTP_LIBS_BASE/maccatalyst-arm64-release" ;;
    *)
      echo "ERROR: unknown platform name '$name'" >&2
      exit 1
      ;;
  esac
  mkdir -p "$ptp_dst_dir"
  echo
  echo "==> pthreadpool ($name)"
  cp "$ptp_build/libpthreadpool.a" "$ptp_dst_dir/libpthreadpool.a"
  echo "    -> $ptp_dst_dir/libpthreadpool.a"

  # Verify each merged .a is single-arch arm64 with the right Mach-O platform.
  # Mach-O platform codes: 2=IOS, 6=MACCATALYST, 7=IOS_SIMULATOR.
  local plat_code plat_name
  case "$name" in
    ios)         plat_code=2; plat_name="IOS" ;;
    simulator)   plat_code=7; plat_name="IOSSIMULATOR" ;;
    maccatalyst) plat_code=6; plat_name="MACCATALYST" ;;
  esac

  for f in \
    libexecutorch_${name}.a \
    libexecutorch_llm_${name}.a \
    libthreadpool_${name}.a \
    libbackend_coreml_${name}.a \
    libbackend_mps_${name}.a \
    libbackend_xnnpack_${name}.a \
    libkernels_llm_${name}.a \
    libkernels_optimized_${name}.a \
    libkernels_quantized_${name}.a \
    libkernels_torchao_${name}.a; do
    verify "$ET_LIBS_DIR/$f" "$plat_code" "$plat_name"
  done
  verify "$ptp_dst_dir/libpthreadpool.a" "$plat_code" "$plat_name"
}

stage_platform "ios"
stage_platform "simulator"
stage_platform "maccatalyst"

# --- cpuinfo --------------------------------------------------------------
# cpuinfo is shared across slices as a single fat lib in this repo. We require
# an arm64 slice but don't enforce platform — if linking fails at step 4 with
# a platform mismatch, rebuild cpuinfo as a fat lib carrying the appropriate
# slices using the same flags as 01.
echo
echo "==> Verifying cpuinfo (shared across iOS / simulator / Catalyst)"
echo "    $CPUINFO_LIB"
echo "    archs: $(lipo -archs "$CPUINFO_LIB")"
if ! lipo -archs "$CPUINFO_LIB" | grep -q "arm64"; then
  echo "ERROR: $CPUINFO_LIB has no arm64 slice — rebuild it for all needed platforms." >&2
  exit 1
fi

echo
echo "==> Re-vendoring tokenizers headers from the install tree"
# The 01 script overlays our own normalizer.{h,cpp} on top of the tokenizers
# submodule before building. `cmake --install` then copies the overlaid header
# into install/<name>/include/pytorch/tokenizers/. Mirror it back into the
# bundled headers so consumer code sees the API the libs were compiled with.
# Headers are platform-independent — picking simulator is arbitrary.
TK_HEADERS_SRC="$BUILD_DIR/install/simulator/include/pytorch/tokenizers"
TK_HEADERS_DST="$REPO_ROOT/packages/react-native-executorch/third-party/include/pytorch/tokenizers"
for hdr in normalizer.h pre_tokenizer.h token_decoder.h post_processor.h; do
  if [ ! -f "$TK_HEADERS_SRC/$hdr" ]; then
    echo "ERROR: $TK_HEADERS_SRC/$hdr missing — rerun 01 first" >&2
    exit 1
  fi
  cp "$TK_HEADERS_SRC/$hdr" "$TK_HEADERS_DST/$hdr"
  echo "    -> $TK_HEADERS_DST/$hdr"
done

echo
echo "==> All three slices staged and verified."
echo "    Next: scripts/executorch/03-build-xcframework.sh"
