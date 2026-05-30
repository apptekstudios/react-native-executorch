#!/bin/bash
#
# Build ExecuTorch + pthreadpool + the consolidated ExecutorchLib.xcframework
# in a single pass: clone the upstream sources, apply the tokenizer overlays,
# run three platform cmake builds (iOS device + iOS Simulator + Mac Catalyst),
# libtool-merge the per-target archives into the consolidated
# lib*_{slice}.a files the bridge links against, and repackage the
# xcframework.
#
# Behaviour:
#   * Every action is a numbered step. The current step is announced before it
#     runs, finished steps print a green check, the active step is the one
#     reported in the failure banner.
#   * ERR trap surfaces "FAILED at step N/M: <name>" with the exit code and an
#     exact resume command.
#   * `--from N` / `--to N` (or `--only N[,M,…]`) gate which steps run, so a
#     fault on a 60-minute step doesn't force re-running the cheap setup.
#   * `--list` prints the step table without running anything.
#   * Environment overrides: EXECUTORCH_REF, TOKENIZERS_REF, PTHREADPOOL_REF,
#     EXECUTORCH_PYTHON, IOS_DEPLOYMENT_TARGET, MACABI_DEPLOYMENT_TARGET.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Paths + config
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
INSTALL_DIR="$BUILD_DIR/install"
ET_SRC="$BUILD_DIR/executorch"
PTP_SRC="$BUILD_DIR/pthreadpool"
TK_SRC="$ET_SRC/extension/llm/tokenizers"
TK_OVERLAY_DIR="$SCRIPT_DIR/patches/tokenizers"

ET_LIBS_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/executorch"
PTP_LIBS_BASE="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/pthreadpool"
CPUINFO_LIB="$REPO_ROOT/packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a"
TK_HEADERS_DST="$REPO_ROOT/packages/react-native-executorch/third-party/include/pytorch/tokenizers"

EXECUTORCH_LIB_DIR="$REPO_ROOT/packages/react-native-executorch/third-party/ios/ExecutorchLib"
XCFRAMEWORK_DST="$REPO_ROOT/packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework"

EXECUTORCH_REPO="https://github.com/pytorch/executorch.git"
EXECUTORCH_REF="${EXECUTORCH_REF:-v1.3.0}"
TOKENIZERS_REF="${TOKENIZERS_REF:-origin/main}"
PTHREADPOOL_REPO="https://github.com/Maratyszcza/pthreadpool.git"
PTHREADPOOL_REF="${PTHREADPOOL_REF:-master}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
MACABI_DEPLOYMENT_TARGET="${MACABI_DEPLOYMENT_TARGET:-17.0}"

# ──────────────────────────────────────────────────────────────────────────────
# Step tracking + error reporting
# ──────────────────────────────────────────────────────────────────────────────

# Each entry: "<short-id>|<human description>|<function name>".
STEPS=(
  "prereqs|Verify host toolchain (xcode-select, ninja, python)|step_prereqs"
  "sync-executorch|Clone or sync ExecuTorch to $EXECUTORCH_REF|step_sync_executorch"
  "patch-flatc|Pin flatc host deployment target to macOS 12.0|step_patch_flatc"
  "sync-tokenizers|Bump tokenizers submodule to $TOKENIZERS_REF|step_sync_tokenizers"
  "overlay-tokenizers|Overlay local tokenizer ops (Bert/Metaspace/WordPiece/…)|step_overlay_tokenizers"
  "python-venv|Bootstrap ExecuTorch Python venv + install_requirements.sh|step_python_venv"
  "sync-pthreadpool|Clone or sync pthreadpool|step_sync_pthreadpool"
  "build-et-ios|Build ExecuTorch for iOS device (arm64, PLATFORM=OS64)|step_build_et_ios"
  "build-et-sim|Build ExecuTorch for iOS Simulator (arm64, PLATFORM=SIMULATORARM64)|step_build_et_sim"
  "build-et-cat|Build ExecuTorch for Mac Catalyst (arm64, PLATFORM=MAC_CATALYST_ARM64)|step_build_et_cat"
  "build-ptp-ios|Build pthreadpool for iOS device|step_build_ptp_ios"
  "build-ptp-sim|Build pthreadpool for iOS Simulator|step_build_ptp_sim"
  "build-ptp-cat|Build pthreadpool for Mac Catalyst|step_build_ptp_cat"
  "stage-ios|Stage iOS slice (libtool-merge + verify Mach-O platform)|step_stage_ios"
  "stage-sim|Stage iOS Simulator slice (libtool-merge + verify Mach-O platform)|step_stage_sim"
  "stage-cat|Stage Mac Catalyst slice (libtool-merge + verify Mach-O platform)|step_stage_cat"
  "verify-cpuinfo|Verify cpuinfo lib carries arm64|step_verify_cpuinfo"
  "vendor-headers|Re-vendor overlaid tokenizers headers into the bundled include tree|step_vendor_headers"
  "xcf-build|Run ExecutorchLib/build.sh to (re)build the xcframework|step_xcf_build"
  "xcf-install|Replace third-party/ios/ExecutorchLib.xcframework|step_xcf_install"
  "xcf-verify|Verify Info.plist lists all three slices|step_xcf_verify"
)
TOTAL_STEPS=${#STEPS[@]}

step_field() { printf '%s' "${1%%|*}"; }
step_desc()  { local s="${1#*|}"; printf '%s' "${s%%|*}"; }
step_fn()    { printf '%s' "${1##*|}"; }

# Terminal styling — only emit ANSI when stdout is a TTY.
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_BOLD=; C_DIM=; C_GREEN=; C_RED=; C_YELLOW=; C_CYAN=; C_RESET=
fi

CURRENT_STEP_NUM=0
CURRENT_STEP_ID=""
CURRENT_STEP_DESC=""
COMPLETED_STEPS=()
SKIPPED_STEPS=()

START_AT=1
STOP_AT=$TOTAL_STEPS
ONLY_LIST=""

print_step_table() {
  printf "%sStep table%s\n" "$C_BOLD" "$C_RESET"
  local i=1
  for entry in "${STEPS[@]}"; do
    printf "  %s%2d.%s %-22s %s\n" "$C_DIM" "$i" "$C_RESET" "$(step_field "$entry")" "$(step_desc "$entry")"
    i=$((i + 1))
  done
}

on_error() {
  local ec=$1
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_RED$C_BOLD" "$C_RESET" >&2
  printf "%s✗ FAILED at step %d/%d: %s%s\n" "$C_RED$C_BOLD" "$CURRENT_STEP_NUM" "$TOTAL_STEPS" "$CURRENT_STEP_ID" "$C_RESET" >&2
  printf "%s  %s%s\n" "$C_RED" "$CURRENT_STEP_DESC" "$C_RESET" >&2
  printf "%s  exit code: %d%s\n" "$C_RED" "$ec" "$C_RESET" >&2
  if [ "${#COMPLETED_STEPS[@]}" -gt 0 ]; then
    printf "%s  completed: %s%s\n" "$C_DIM" "${COMPLETED_STEPS[*]}" "$C_RESET" >&2
  fi
  printf "%s  resume:   %s --from %d%s\n" "$C_YELLOW" "$0" "$CURRENT_STEP_NUM" "$C_RESET" >&2
  printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_RED$C_BOLD" "$C_RESET" >&2
  exit "$ec"
}
trap 'on_error $?' ERR

# Should the step at (1-based) index $1 run, given the user's flags?
should_run() {
  local n=$1
  if [ -n "$ONLY_LIST" ]; then
    case ",$ONLY_LIST," in *",$n,"*) return 0 ;; *) return 1 ;; esac
  fi
  if [ "$n" -lt "$START_AT" ] || [ "$n" -gt "$STOP_AT" ]; then
    return 1
  fi
  return 0
}

# Banner-style invocation for a numbered step. Updates CURRENT_STEP_* before
# dispatching, then appends to COMPLETED_STEPS once the function returns.
run_step() {
  local n=$1
  local entry="${STEPS[$((n - 1))]}"
  local id desc fn
  id="$(step_field "$entry")"
  desc="$(step_desc "$entry")"
  fn="$(step_fn "$entry")"

  if ! should_run "$n"; then
    printf "%s───%s %s[SKIP %2d/%d]%s %s%s%s\n" \
      "$C_DIM" "$C_RESET" "$C_DIM" "$n" "$TOTAL_STEPS" "$C_RESET" "$C_DIM" "$desc" "$C_RESET"
    SKIPPED_STEPS+=("$n")
    return 0
  fi

  CURRENT_STEP_NUM=$n
  CURRENT_STEP_ID=$id
  CURRENT_STEP_DESC=$desc
  printf "\n%s━━━ Step %d/%d: %s%s\n" "$C_BOLD$C_CYAN" "$n" "$TOTAL_STEPS" "$id" "$C_RESET"
  printf "%s    %s%s\n" "$C_CYAN" "$desc" "$C_RESET"
  "$fn"
  COMPLETED_STEPS+=("$n:$id")
  printf "%s✓ done%s %s(%d/%d)%s\n" "$C_GREEN" "$C_RESET" "$C_DIM" "$n" "$TOTAL_STEPS" "$C_RESET"
}

# ──────────────────────────────────────────────────────────────────────────────
# Step implementations
# ──────────────────────────────────────────────────────────────────────────────

step_prereqs() {
  if ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: ninja not found on PATH (brew install ninja)" >&2
    return 1
  fi
  MACOSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
  IPHONEOS_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
  IPHONESIM_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  CC_MACOS="$(xcrun --sdk macosx --find clang)"
  CXX_MACOS="$(xcrun --sdk macosx --find clang++)"
  CC_IOS="$(xcrun --sdk iphoneos --find clang)"
  CXX_IOS="$(xcrun --sdk iphoneos --find clang++)"
  CC_SIM="$(xcrun --sdk iphonesimulator --find clang)"
  CXX_SIM="$(xcrun --sdk iphonesimulator --find clang++)"
  LIBTOOL="$(xcrun --sdk macosx --find libtool)"
  ET_PYTHON="$(pick_python)" || {
    echo "ERROR: ExecuTorch needs Python >=3.10,<3.14 (brew install python@3.12 or set EXECUTORCH_PYTHON)" >&2
    return 1
  }
  mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$ET_LIBS_DIR"
  printf "    macOS clang     : %s\n" "$CC_MACOS"
  printf "    iOS clang       : %s\n" "$CC_IOS"
  printf "    sim clang       : %s\n" "$CC_SIM"
  printf "    libtool         : %s\n" "$LIBTOOL"
  printf "    python          : %s (%s)\n" "$ET_PYTHON" "$($ET_PYTHON --version)"
  printf "    executorch ref  : %s\n" "$EXECUTORCH_REF"
  printf "    tokenizers ref  : %s\n" "$TOKENIZERS_REF"
  printf "    pthreadpool ref : %s\n" "$PTHREADPOOL_REF"
}

pick_python() {
  if [ -n "${EXECUTORCH_PYTHON:-}" ]; then
    command -v "$EXECUTORCH_PYTHON" || return 1
    return 0
  fi
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"; return 0
    fi
  done
  if python3 -c 'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] < (3,14) else 1)' 2>/dev/null; then
    command -v python3; return 0
  fi
  return 1
}

step_sync_executorch() {
  if [ ! -d "$ET_SRC/.git" ]; then
    # Do NOT use --recursive: some historical refs have `shim/` as a tracked
    # directory while HEAD has it as a submodule, so submodule-at-HEAD files
    # conflict with the ref's tracked content during `git checkout`. Init
    # submodules AFTER the ref is checked out.
    git clone --no-recurse-submodules "$EXECUTORCH_REPO" "$ET_SRC"
  fi
  local current desired
  current="$(git -C "$ET_SRC" rev-parse HEAD)"
  desired="$(git -C "$ET_SRC" rev-parse "$EXECUTORCH_REF" 2>/dev/null || true)"
  if [ -z "$desired" ] || [ "$current" != "$desired" ]; then
    git -C "$ET_SRC" fetch --tags --force origin
    git -C "$ET_SRC" checkout "$EXECUTORCH_REF"
    git -C "$ET_SRC" submodule update --init --recursive
  fi
  printf "    HEAD: %s (%s)\n" "$(git -C "$ET_SRC" rev-parse --short HEAD)" "$(git -C "$ET_SRC" log -1 --format=%s)"
}

step_patch_flatc() {
  # Xcode 26 / SDK 26 host clang rejects -mmacosx-version-min=17.0 ("invalid
  # version number") because macOS 17 doesn't exist. Force the flatc/flatcc
  # sub-build to target macOS 12.0 instead. Idempotent.
  local file="$ET_SRC/third-party/CMakeLists.txt"
  if grep -q '\-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=\${CMAKE_OSX_DEPLOYMENT_TARGET}' "$file"; then
    perl -i -pe 's|-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$\{CMAKE_OSX_DEPLOYMENT_TARGET\}|-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=12.0|g' "$file"
    printf "    patched %s\n" "$file"
  else
    printf "    %salready patched (no-op)%s\n" "$C_DIM" "$C_RESET"
  fi
}

step_sync_tokenizers() {
  git -C "$TK_SRC" fetch --force origin
  # Reset before checkout so a prior overlay (uncommitted .h/.cpp edits) doesn't
  # block the checkout. Overlay is re-applied immediately afterwards in the
  # next step.
  git -C "$TK_SRC" reset --hard HEAD
  git -C "$TK_SRC" -c advice.detachedHead=false checkout "$TOKENIZERS_REF"
  printf "    HEAD: %s (%s)\n" "$(git -C "$TK_SRC" rev-parse --short HEAD)" "$(git -C "$TK_SRC" log -1 --format=%s)"
}

step_overlay_tokenizers() {
  # Pairs of <overlay-basename> -> <relative path inside the tokenizers source>.
  # ExecuTorch v1.3.0 ships meta-pytorch/tokenizers @ b642403 which lacks most
  # of the normalizers / pre-tokenizers / decoders / post-processors real HF
  # tokenizer.json files use. These overlays add the missing ones in-tree
  # before compilation; see ../patches/tokenizers/ for sources.
  local overlay_pairs=(
    "normalizer.h:include/pytorch/tokenizers/normalizer.h"
    "normalizer.cpp:src/normalizer.cpp"
    "pre_tokenizer.h:include/pytorch/tokenizers/pre_tokenizer.h"
    "pre_tokenizer.cpp:src/pre_tokenizer.cpp"
    "token_decoder.h:include/pytorch/tokenizers/token_decoder.h"
    "token_decoder.cpp:src/token_decoder.cpp"
    "post_processor.h:include/pytorch/tokenizers/post_processor.h"
    "post_processor.cpp:src/post_processor.cpp"
    "hf_tokenizer.cpp:src/hf_tokenizer.cpp"
  )
  local pair src dst
  for pair in "${overlay_pairs[@]}"; do
    src="$TK_OVERLAY_DIR/${pair%%:*}"
    dst="$TK_SRC/${pair##*:}"
    if [ ! -f "$src" ]; then
      echo "ERROR: overlay source missing: $src" >&2
      return 1
    fi
    cp "$src" "$dst"
    printf "    + %s -> %s\n" "${pair%%:*}" "${pair##*:}"
  done
}

step_python_venv() {
  if [ -d "$ET_SRC/.venv" ] && [ -x "$ET_SRC/.venv/bin/python" ]; then
    if ! "$ET_SRC/.venv/bin/python" -c \
        'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] < (3,14) else 1)' 2>/dev/null; then
      printf "    existing .venv uses unsupported Python; recreating\n"
      rm -rf "$ET_SRC/.venv"
    fi
  fi
  if [ ! -d "$ET_SRC/.venv" ]; then
    "$ET_PYTHON" -m venv "$ET_SRC/.venv"
    # shellcheck disable=SC1091
    source "$ET_SRC/.venv/bin/activate"
    pip install --upgrade pip
    (cd "$ET_SRC" && ./install_requirements.sh)
    deactivate
  fi
  VENV_PYTHON="$ET_SRC/.venv/bin/python"
  printf "    venv python: %s (%s)\n" "$VENV_PYTHON" "$($VENV_PYTHON --version)"
}

step_sync_pthreadpool() {
  if [ ! -d "$PTP_SRC/.git" ]; then
    git clone --depth 1 --branch "$PTHREADPOOL_REF" "$PTHREADPOOL_REPO" "$PTP_SRC"
  fi
  printf "    HEAD: %s\n" "$(git -C "$PTP_SRC" rev-parse --short HEAD)"
}

# Args: name PLATFORM deployment_target
build_executorch_platform() {
  local name=$1 platform=$2 deployment_target=$3
  local et_build="$ET_SRC/cmake-out-$name"
  printf "    PLATFORM=%s DEPLOYMENT_TARGET=%s\n" "$platform" "$deployment_target"
  rm -rf "$et_build"
  cmake -S "$ET_SRC" -B "$et_build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$et_build" \
    -DCMAKE_TOOLCHAIN_FILE="$ET_SRC/third-party/ios-cmake/ios.toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/$name" \
    -DEXECUTORCH_BUILD_PRESET_FILE="$ET_SRC/tools/cmake/preset/macos.cmake" \
    -DPLATFORM="$platform" \
    -DDEPLOYMENT_TARGET="$deployment_target" \
    -DENABLE_VISIBILITY=ON \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DPython3_EXECUTABLE="$VENV_PYTHON" \
    -DPython_EXECUTABLE="$VENV_PYTHON" \
    -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF \
    -DEXECUTORCH_COREML_BUILD_EXECUTOR_RUNNER=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_APPLE=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_LLM_APPLE=OFF
  cmake --build "$et_build"
  rm -rf "$INSTALL_DIR/$name"
  cmake --install "$et_build" --prefix "$INSTALL_DIR/$name"
}

# Args: name triple sysroot cc cxx
build_pthreadpool_platform() {
  local name=$1 triple=$2 sysroot=$3 cc=$4 cxx=$5
  local ptp_build="$PTP_SRC/cmake-out-$name"
  printf "    target=%s sysroot=%s\n" "$triple" "$sysroot"
  rm -rf "$ptp_build"
  local cflags="-target $triple -isysroot $sysroot -fembed-bitcode-marker"
  cmake -S "$PTP_SRC" -B "$ptp_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_CXX_COMPILER="$cxx" \
    -DCMAKE_C_FLAGS="$cflags" \
    -DCMAKE_CXX_FLAGS="$cflags" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DPTHREADPOOL_BUILD_TESTS=OFF \
    -DPTHREADPOOL_BUILD_BENCHMARKS=OFF
  cmake --build "$ptp_build" --config Release -j
  if [ ! -f "$ptp_build/libpthreadpool.a" ]; then
    echo "ERROR: libpthreadpool.a was not produced at $ptp_build" >&2
    return 1
  fi
}

# The venv path is set by step_python_venv but the per-platform build needs
# it too when starting mid-stream via --from. Re-resolve it lazily.
ensure_venv_python() {
  if [ -z "${VENV_PYTHON:-}" ]; then
    if [ -x "$ET_SRC/.venv/bin/python" ]; then
      VENV_PYTHON="$ET_SRC/.venv/bin/python"
    else
      echo "ERROR: no python venv under $ET_SRC/.venv — run step python-venv first" >&2
      return 1
    fi
  fi
}

ensure_sysroots() {
  if [ -z "${MACOSX_SYSROOT:-}" ]; then
    MACOSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
    IPHONEOS_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
    IPHONESIM_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    CC_MACOS="$(xcrun --sdk macosx --find clang)"
    CXX_MACOS="$(xcrun --sdk macosx --find clang++)"
    CC_IOS="$(xcrun --sdk iphoneos --find clang)"
    CXX_IOS="$(xcrun --sdk iphoneos --find clang++)"
    CC_SIM="$(xcrun --sdk iphonesimulator --find clang)"
    CXX_SIM="$(xcrun --sdk iphonesimulator --find clang++)"
    LIBTOOL="$(xcrun --sdk macosx --find libtool)"
  fi
}

step_build_et_ios() { ensure_venv_python; build_executorch_platform "ios"         "OS64"               "$IOS_DEPLOYMENT_TARGET"; }
step_build_et_sim() { ensure_venv_python; build_executorch_platform "simulator"   "SIMULATORARM64"     "$IOS_DEPLOYMENT_TARGET"; }
step_build_et_cat() { ensure_venv_python; build_executorch_platform "maccatalyst" "MAC_CATALYST_ARM64" "$MACABI_DEPLOYMENT_TARGET"; }

step_build_ptp_ios() {
  ensure_sysroots
  build_pthreadpool_platform "ios" "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" "$IPHONEOS_SYSROOT" "$CC_IOS" "$CXX_IOS"
}
step_build_ptp_sim() {
  ensure_sysroots
  build_pthreadpool_platform "simulator" "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" "$IPHONESIM_SYSROOT" "$CC_SIM" "$CXX_SIM"
}
step_build_ptp_cat() {
  ensure_sysroots
  build_pthreadpool_platform "maccatalyst" "arm64-apple-ios${MACABI_DEPLOYMENT_TARGET}-macabi" "$MACOSX_SYSROOT" "$CC_MACOS" "$CXX_MACOS"
}

# ── Staging helpers (from the old 02 script) ─────────────────────────────────

find_lib() {
  local et_build=$1 basename=$2 matches
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

merge() {
  local et_build=$1; shift
  local out=$1; shift
  local sources=() name
  for name in "$@"; do
    sources+=("$(find_lib "$et_build" "$name")")
  done
  printf "    %s\n" "$(basename "$out")"
  local s
  for s in "${sources[@]}"; do
    printf "        + %s\n" "${s#$et_build/}"
  done
  rm -f "$out"
  "$LIBTOOL" -static -o "$out" "${sources[@]}"
}

# Args: lib_path expected_platform_code expected_platform_name
verify_mach_o() {
  local lib=$1 expected_code=$2 expected_name=$3
  if [ ! -f "$lib" ]; then
    echo "ERROR: missing $lib" >&2; return 1
  fi
  local archs platform
  archs="$(lipo -archs "$lib" 2>&1)"
  if [ "$archs" != "arm64" ]; then
    echo "ERROR: $(basename "$lib") archs='$archs', expected 'arm64'" >&2
    return 1
  fi
  platform="$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{flag=1} flag && /platform/{print $2; flag=0}' | sort -u)"
  if ! echo "$platform" | grep -qE "(^|[^0-9])${expected_code}([^0-9]|$)|${expected_name}"; then
    echo "ERROR: $(basename "$lib") platform='$platform', expected $expected_name ($expected_code)" >&2
    echo "       inspect with: otool -l $lib | grep -A3 LC_BUILD_VERSION" >&2
    return 1
  fi
  printf "    ✓ %-44s archs=%-6s platform=%s\n" "$(basename "$lib")" "$archs" "$platform"
}

# Args: name (ios/simulator/maccatalyst)
stage_slice() {
  local name=$1
  ensure_sysroots
  local et_build="$BUILD_DIR/executorch/cmake-out-$name"
  local ptp_build="$BUILD_DIR/pthreadpool/cmake-out-$name"
  if [ ! -d "$et_build" ]; then
    echo "ERROR: ExecuTorch build for $name not found at $et_build (run earlier step)" >&2
    return 1
  fi
  if [ ! -d "$ptp_build" ]; then
    echo "ERROR: pthreadpool build for $name not found at $ptp_build (run earlier step)" >&2
    return 1
  fi

  # libexecutorch_<name>.a — core ExecuTorch + module/extension archives.
  # libextension_apple.a (Swift wrapper) is intentionally omitted; the bridge
  # uses the C++ API directly. See EXECUTORCH_BUILD_EXTENSION_APPLE=OFF above.
  merge "$et_build" "$ET_LIBS_DIR/libexecutorch_${name}.a" \
    libexecutorch.a libexecutorch_core.a \
    libextension_data_loader.a libextension_flat_tensor.a \
    libextension_module.a libextension_named_data_map.a libextension_tensor.a

  # libexecutorch_llm_<name>.a — LLM runner + tokenizers + abseil + sentencepiece.
  merge "$et_build" "$ET_LIBS_DIR/libexecutorch_llm_${name}.a" \
    libabsl_base.a libabsl_city.a libabsl_decode_rust_punycode.a \
    libabsl_demangle_internal.a libabsl_demangle_rust.a libabsl_examine_stack.a \
    libabsl_graphcycles_internal.a libabsl_hash.a libabsl_int128.a \
    libabsl_kernel_timeout_internal.a libabsl_leak_check.a libabsl_log_globals.a \
    libabsl_log_internal_check_op.a libabsl_log_internal_format.a \
    libabsl_log_internal_globals.a libabsl_log_internal_log_sink_set.a \
    libabsl_log_internal_message.a libabsl_log_internal_nullguard.a \
    libabsl_log_internal_proto.a libabsl_log_severity.a libabsl_log_sink.a \
    libabsl_low_level_hash.a libabsl_malloc_internal.a libabsl_raw_hash_set.a \
    libabsl_raw_logging_internal.a libabsl_spinlock_wait.a libabsl_stacktrace.a \
    libabsl_str_format_internal.a libabsl_strerror.a libabsl_strings.a \
    libabsl_strings_internal.a libabsl_symbolize.a libabsl_synchronization.a \
    libabsl_throw_delegate.a libabsl_time.a libabsl_time_zone.a \
    libabsl_tracing_internal.a libabsl_utf8_for_code_point.a \
    libextension_llm_runner.a libextension_memory_allocator.a \
    libpcre2-8.a libre2.a libregex_lookahead.a libsentencepiece.a libtokenizers.a

  merge "$et_build" "$ET_LIBS_DIR/libthreadpool_${name}.a" \
    libcpuinfo.a libextension_threadpool.a libpthreadpool.a
  merge "$et_build" "$ET_LIBS_DIR/libbackend_coreml_${name}.a" \
    libcoreml_util.a libcoreml_inmemoryfs.a libcoremldelegate.a
  merge "$et_build" "$ET_LIBS_DIR/libbackend_mps_${name}.a" libmpsdelegate.a
  merge "$et_build" "$ET_LIBS_DIR/libbackend_xnnpack_${name}.a" \
    libXNNPACK.a libkleidiai.a libxnnpack_backend.a libxnnpack-microkernels-prod.a
  merge "$et_build" "$ET_LIBS_DIR/libkernels_llm_${name}.a" libcustom_ops.a
  merge "$et_build" "$ET_LIBS_DIR/libkernels_optimized_${name}.a" \
    libcpublas.a liboptimized_kernels.a liboptimized_native_cpu_ops_lib.a libportable_kernels.a
  merge "$et_build" "$ET_LIBS_DIR/libkernels_quantized_${name}.a" \
    libquantized_kernels.a libquantized_ops_lib.a
  merge "$et_build" "$ET_LIBS_DIR/libkernels_torchao_${name}.a" \
    libtorchao_ops_executorch.a libtorchao_kernels_aarch64.a

  # pthreadpool standalone (linked directly by the podspec).
  local ptp_dst_dir
  case "$name" in
    ios)         ptp_dst_dir="$PTP_LIBS_BASE/physical-arm64-release" ;;
    simulator)   ptp_dst_dir="$PTP_LIBS_BASE/simulator-arm64-debug" ;;
    maccatalyst) ptp_dst_dir="$PTP_LIBS_BASE/maccatalyst-arm64-release" ;;
    *) echo "ERROR: unknown slice '$name'" >&2; return 1 ;;
  esac
  mkdir -p "$ptp_dst_dir"
  cp "$ptp_build/libpthreadpool.a" "$ptp_dst_dir/libpthreadpool.a"
  printf "    pthreadpool -> %s\n" "$ptp_dst_dir/libpthreadpool.a"

  # Verify each merged .a is single-arch arm64 with the right Mach-O platform.
  # Mach-O platform codes: 2=IOS, 6=MACCATALYST, 7=IOS_SIMULATOR.
  local plat_code plat_name
  case "$name" in
    ios)         plat_code=2; plat_name="IOS" ;;
    simulator)   plat_code=7; plat_name="IOSSIMULATOR" ;;
    maccatalyst) plat_code=6; plat_name="MACCATALYST" ;;
  esac
  local f
  for f in \
    libexecutorch_${name}.a libexecutorch_llm_${name}.a libthreadpool_${name}.a \
    libbackend_coreml_${name}.a libbackend_mps_${name}.a libbackend_xnnpack_${name}.a \
    libkernels_llm_${name}.a libkernels_optimized_${name}.a \
    libkernels_quantized_${name}.a libkernels_torchao_${name}.a; do
    verify_mach_o "$ET_LIBS_DIR/$f" "$plat_code" "$plat_name"
  done
  verify_mach_o "$ptp_dst_dir/libpthreadpool.a" "$plat_code" "$plat_name"
}

step_stage_ios() { stage_slice "ios"; }
step_stage_sim() { stage_slice "simulator"; }
step_stage_cat() { stage_slice "maccatalyst"; }

step_verify_cpuinfo() {
  # cpuinfo is shared across slices as a single fat lib in this repo. We
  # require an arm64 slice but don't enforce platform — if linking fails at
  # the xcframework step with a platform mismatch, rebuild cpuinfo as a fat
  # lib carrying all needed slices.
  printf "    %s\n" "$CPUINFO_LIB"
  printf "    archs: %s\n" "$(lipo -archs "$CPUINFO_LIB")"
  if ! lipo -archs "$CPUINFO_LIB" | grep -q "arm64"; then
    echo "ERROR: $CPUINFO_LIB has no arm64 slice" >&2
    return 1
  fi
}

step_vendor_headers() {
  # The overlay copied our normalizer.{h,cpp} etc. on top of the tokenizers
  # source; `cmake --install` then copied the overlaid header to
  # install/<slice>/include/pytorch/tokenizers/. Mirror it back into the
  # bundled headers so consumer code sees the API the libs were compiled
  # against. Headers are platform-independent — picking simulator is arbitrary.
  local src_root="$INSTALL_DIR/simulator/include/pytorch/tokenizers"
  local hdr
  for hdr in normalizer.h pre_tokenizer.h token_decoder.h post_processor.h; do
    if [ ! -f "$src_root/$hdr" ]; then
      echo "ERROR: $src_root/$hdr missing — rerun the build steps for the simulator slice" >&2
      return 1
    fi
    cp "$src_root/$hdr" "$TK_HEADERS_DST/$hdr"
    printf "    -> %s\n" "$TK_HEADERS_DST/$hdr"
  done
}

step_xcf_build() {
  if [ ! -d "$EXECUTORCH_LIB_DIR" ]; then
    echo "ERROR: $EXECUTORCH_LIB_DIR not present" >&2; return 1
  fi
  (cd "$EXECUTORCH_LIB_DIR" && ./build.sh)
  if [ ! -d "$EXECUTORCH_LIB_DIR/output/ExecutorchLib.xcframework" ]; then
    echo "ERROR: build.sh did not produce output/ExecutorchLib.xcframework" >&2
    return 1
  fi
}

step_xcf_install() {
  printf "    -> %s\n" "$XCFRAMEWORK_DST"
  rm -rf "$XCFRAMEWORK_DST"
  cp -R "$EXECUTORCH_LIB_DIR/output/ExecutorchLib.xcframework" "$XCFRAMEWORK_DST"
}

step_xcf_verify() {
  local plist="$XCFRAMEWORK_DST/Info.plist"
  if [ ! -f "$plist" ]; then
    echo "ERROR: $plist missing" >&2; return 1
  fi
  printf "    %sInfo.plist:%s\n" "$C_DIM" "$C_RESET"
  plutil -p "$plist" | sed 's/^/      /'
  local slot
  for slot in ios-arm64 ios-arm64-simulator ios-arm64-maccatalyst; do
    if ! plutil -p "$plist" | grep -q "\"LibraryIdentifier\" => \"$slot\""; then
      echo "ERROR: $plist is missing slice $slot" >&2
      return 1
    fi
    printf "    ✓ %s\n" "$slot"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI parsing + main
# ──────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [--from N] [--to N] [--only N[,M,...]] [--list] [--help]

Step-tracking driver for the ExecuTorch + xcframework build pipeline.

Options:
  --from N          start at step N (1-based; default 1)
  --to N            stop after step N (default $TOTAL_STEPS)
  --only N[,M,...]  run only the listed steps (overrides --from/--to)
  --list            print the step table and exit
  --help            show this help

Environment overrides:
  EXECUTORCH_REF, TOKENIZERS_REF, PTHREADPOOL_REF, EXECUTORCH_PYTHON,
  IOS_DEPLOYMENT_TARGET, MACABI_DEPLOYMENT_TARGET

On failure, the trap prints "FAILED at step N/M: <id>" with the exit code and
a ready-made --from N command to resume after fixing the root cause.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)   START_AT=${2:?--from needs a value}; shift 2 ;;
    --to)     STOP_AT=${2:?--to needs a value}; shift 2 ;;
    --only)   ONLY_LIST=${2:?--only needs a value}; shift 2 ;;
    --list)   print_step_table; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$START_AT" -lt 1 ] || [ "$START_AT" -gt "$TOTAL_STEPS" ]; then
  echo "ERROR: --from $START_AT out of range (1..$TOTAL_STEPS)" >&2; exit 2
fi
if [ "$STOP_AT" -lt 1 ] || [ "$STOP_AT" -gt "$TOTAL_STEPS" ]; then
  echo "ERROR: --to $STOP_AT out of range (1..$TOTAL_STEPS)" >&2; exit 2
fi

printf "%s┌─────────────────────────────────────────────────────────────┐%s\n" "$C_BOLD$C_CYAN" "$C_RESET"
printf "%s│ ExecuTorch + xcframework build — %d steps                  │%s\n" "$C_BOLD$C_CYAN" "$TOTAL_STEPS" "$C_RESET"
printf "%s└─────────────────────────────────────────────────────────────┘%s\n" "$C_BOLD$C_CYAN" "$C_RESET"

for n in $(seq 1 "$TOTAL_STEPS"); do
  run_step "$n"
done

printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_GREEN$C_BOLD" "$C_RESET"
printf "%s✓ All %d steps complete%s\n" "$C_GREEN$C_BOLD" "${#COMPLETED_STEPS[@]}" "$C_RESET"
if [ "${#SKIPPED_STEPS[@]}" -gt 0 ]; then
  printf "%s  skipped: %s%s\n" "$C_DIM" "${SKIPPED_STEPS[*]}" "$C_RESET"
fi
printf "%s  next:   %s/02-reinstall-pods-for-example-apps.sh%s\n" "$C_DIM" "$SCRIPT_DIR" "$C_RESET"
printf "%s          %s/03-test-bare-rn-build.sh%s\n" "$C_DIM" "$SCRIPT_DIR" "$C_RESET"
printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_GREEN$C_BOLD" "$C_RESET"
