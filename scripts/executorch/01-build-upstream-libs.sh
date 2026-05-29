#!/bin/bash
#
# Build ExecuTorch + pthreadpool static libraries for all three Apple
# platforms (iOS device, iOS Simulator, Mac Catalyst — arm64 only). Output
# lands in scripts/executorch/.build/, ready for 02-stage-and-verify-libs.sh
# to libtool-merge into the repo.
#
# Run from anywhere; paths resolve relative to this script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
INSTALL_DIR="$BUILD_DIR/install"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

# --- Configuration ---------------------------------------------------------
EXECUTORCH_REPO="https://github.com/pytorch/executorch.git"
# v1.3.0 is the unified ref for all three slices. Bridge consumer code is
# expected to match this API. Bumping this without updating the bridge will
# break the build at link time.
EXECUTORCH_REF="${EXECUTORCH_REF:-v1.3.0}"

# Override the tokenizers submodule pin that ExecuTorch v1.3.0 ships with
# (b642403, ~= v1.0.1+19). Latest meta-pytorch/tokenizers main carries memory
# safety + thread-safety fixes; HEAD as of this commit is 4834da0. The overlay
# step further down adds a local normalizer.{h,cpp} with the extra normalizer
# types HF tokenizer.json files commonly use (BertNormalizer, Lowercase, NFD,
# StripAccents, Nmt, ByteLevel, Precompiled). Without those, loading a real
# HuggingFace tokenizer.json hits "Unsupported Normalizer type: ..." and the
# load fails with error code 122 at the JS layer.
TOKENIZERS_REF="${TOKENIZERS_REF:-origin/main}"

PTHREADPOOL_REPO="https://github.com/Maratyszcza/pthreadpool.git"
PTHREADPOOL_REF="${PTHREADPOOL_REF:-master}"

# Deployment targets per slice (match the bare-rn app's iOS minimum so that
# Catalyst, iOS, and the simulator are mutually link-compatible).
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
MACABI_DEPLOYMENT_TARGET="${MACABI_DEPLOYMENT_TARGET:-17.0}"

MACOSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
IPHONEOS_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIM_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"

CC_MACOS="$(xcrun --sdk macosx --find clang)"
CXX_MACOS="$(xcrun --sdk macosx --find clang++)"
CC_IOS="$(xcrun --sdk iphoneos --find clang)"
CXX_IOS="$(xcrun --sdk iphoneos --find clang++)"
CC_SIM="$(xcrun --sdk iphonesimulator --find clang)"
CXX_SIM="$(xcrun --sdk iphonesimulator --find clang++)"

if ! command -v ninja >/dev/null 2>&1; then
  echo "ERROR: ninja not found on PATH." >&2
  echo "       The ExecuTorch sub-build uses the Ninja generator because" >&2
  echo "       Xcode + ios.toolchain.cmake + MAC_CATALYST_ARM64 has structural" >&2
  echo "       gaps (see comment in this script near 'cmake -S ... -G Ninja')." >&2
  echo "       Install with: brew install ninja" >&2
  exit 1
fi

echo "==> Toolchains"
echo "    macOS clang     : $CC_MACOS"
echo "    iOS clang       : $CC_IOS"
echo "    sim clang       : $CC_SIM"
echo "    executorch ref  : $EXECUTORCH_REF"
echo "    tokenizers ref  : $TOKENIZERS_REF"
echo "    pthreadpool ref : $PTHREADPOOL_REF"
echo

# --- ExecuTorch source checkout (shared across platforms) ------------------
ET_SRC="$BUILD_DIR/executorch"

if [ ! -d "$ET_SRC/.git" ]; then
  echo "==> Cloning ExecuTorch"
  # Important: do NOT use --recursive here. Some refs have `shim/` as a regular
  # tracked directory while HEAD has it as a submodule, so submodule-at-HEAD
  # files conflict with the ref's tracked content during `git checkout`. Init
  # submodules AFTER the ref is checked out.
  git clone --no-recurse-submodules "$EXECUTORCH_REPO" "$ET_SRC"
fi

CURRENT_REF="$(git -C "$ET_SRC" rev-parse HEAD)"
DESIRED_REF="$(git -C "$ET_SRC" rev-parse "$EXECUTORCH_REF" 2>/dev/null || true)"
if [ -z "$DESIRED_REF" ] || [ "$CURRENT_REF" != "$DESIRED_REF" ]; then
  echo "==> Syncing ExecuTorch to $EXECUTORCH_REF"
  git -C "$ET_SRC" fetch --tags --force origin
  git -C "$ET_SRC" checkout "$EXECUTORCH_REF"
  git -C "$ET_SRC" submodule update --init --recursive
fi

# --- Bump tokenizers submodule + apply overlays ----------------------------
# ExecuTorch v1.3.0 pins meta-pytorch/tokenizers at b642403, which lacks
# BertNormalizer / Lowercase / NFD / StripAccents / Nmt / ByteLevel /
# Precompiled (normalizers) and BertPreTokenizer (pre-tokenizers). We bump to
# TOKENIZERS_REF (default origin/main) and overlay our own normalizer.{h,cpp}
# + pre_tokenizer.{h,cpp} from scripts/executorch/patches/tokenizers/ to add
# those types. The overlay is idempotent: re-running this script always
# copies the patch tree on top regardless of prior state.
TK_SRC="$ET_SRC/extension/llm/tokenizers"
TK_OVERLAY_DIR="$SCRIPT_DIR/patches/tokenizers"

echo
echo "==> Bumping tokenizers submodule to $TOKENIZERS_REF"
git -C "$TK_SRC" fetch --force origin
# Reset before checkout so a prior overlay (uncommitted changes to
# normalizer.{h,cpp}) doesn't block the checkout. The overlay is re-applied
# immediately afterwards, so wiping it here is safe.
git -C "$TK_SRC" reset --hard HEAD
git -C "$TK_SRC" -c advice.detachedHead=false checkout "$TOKENIZERS_REF"
echo "    tokenizers HEAD: $(git -C "$TK_SRC" rev-parse --short HEAD) ($(git -C "$TK_SRC" log -1 --format=%s))"

echo "==> Overlaying tokenizers sources from $TK_OVERLAY_DIR"
# Pairs of <overlay-basename> -> <relative path inside tokenizers source tree>.
overlay_pairs=(
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
for pair in "${overlay_pairs[@]}"; do
  src="$TK_OVERLAY_DIR/${pair%%:*}"
  dst="$TK_SRC/${pair##*:}"
  if [ ! -f "$src" ]; then
    echo "ERROR: overlay source missing: $src" >&2
    exit 1
  fi
  cp "$src" "$dst"
  echo "    + ${pair%%:*} -> ${pair##*:}"
done

# Patch upstream third-party/CMakeLists.txt so the host macOS flatc/flatcc
# subbuilds don't inherit the project's iOS DEPLOYMENT_TARGET (17.0). On
# Xcode 26 / SDK 26 the host clang rejects -mmacosx-version-min=17.0
# ("invalid version number") because macOS 17 doesn't exist. We force the
# subbuild to use the valid macOS target 12.0 instead. Idempotent.
FLATC_PATCH_FILE="$ET_SRC/third-party/CMakeLists.txt"
if grep -q '\-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=\${CMAKE_OSX_DEPLOYMENT_TARGET}' "$FLATC_PATCH_FILE"; then
  echo "==> Patching $FLATC_PATCH_FILE: pin flatc host deployment target to 12.0"
  # Use perl for portability across BSD/GNU sed.
  perl -i -pe 's|-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$\{CMAKE_OSX_DEPLOYMENT_TARGET\}|-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=12.0|g' "$FLATC_PATCH_FILE"
fi

# --- ExecuTorch Python venv (shared) ---------------------------------------
pick_python() {
  if [ -n "${EXECUTORCH_PYTHON:-}" ]; then
    command -v "$EXECUTORCH_PYTHON" || return 1
    return 0
  fi
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  if python3 -c 'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] < (3,14) else 1)' 2>/dev/null; then
    command -v python3
    return 0
  fi
  return 1
}

ET_PYTHON="$(pick_python)" || {
  echo "ERROR: No compatible Python found. ExecuTorch requires >=3.10,<3.14." >&2
  echo "       Install one (e.g. \`brew install python@3.12\`) or set EXECUTORCH_PYTHON." >&2
  exit 1
}
echo "==> ExecuTorch Python: $ET_PYTHON ($($ET_PYTHON --version))"

if [ -d "$ET_SRC/.venv" ] && [ -x "$ET_SRC/.venv/bin/python" ]; then
  if ! "$ET_SRC/.venv/bin/python" -c 'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] < (3,14) else 1)' 2>/dev/null; then
    echo "==> Existing .venv uses an unsupported Python; recreating"
    rm -rf "$ET_SRC/.venv"
  fi
fi

if [ ! -d "$ET_SRC/.venv" ]; then
  echo "==> Bootstrapping ExecuTorch Python deps (one-time)"
  "$ET_PYTHON" -m venv "$ET_SRC/.venv"
  # shellcheck disable=SC1091
  source "$ET_SRC/.venv/bin/activate"
  pip install --upgrade pip
  (cd "$ET_SRC" && ./install_requirements.sh)
  deactivate
fi
VENV_PYTHON="$ET_SRC/.venv/bin/python"

# --- pthreadpool clone (shared) --------------------------------------------
PTP_SRC="$BUILD_DIR/pthreadpool"
if [ ! -d "$PTP_SRC/.git" ]; then
  echo "==> Cloning pthreadpool ($PTHREADPOOL_REF)"
  git clone --depth 1 --branch "$PTHREADPOOL_REF" "$PTHREADPOOL_REPO" "$PTP_SRC"
fi

# --- Per-platform build functions ------------------------------------------
# Args: name PLATFORM deployment_target
# PLATFORM is the ios.toolchain.cmake value (OS64 / SIMULATORARM64 /
# MAC_CATALYST_ARM64).
build_executorch_platform() {
  local name="$1"
  local platform="$2"
  local deployment_target="$3"
  local et_build="$ET_SRC/cmake-out-$name"

  echo
  echo "==> Building ExecuTorch for $name (PLATFORM=$platform, arm64)"
  rm -rf "$et_build"

  # Ninja generator (not Xcode) because ios.toolchain.cmake only injects the
  # macabi target triple + iOSSupport include/framework paths in its non-Xcode
  # branch (see line 901 of ios.toolchain.cmake). Under Xcode + this toolchain
  # the build defaults to platform 1 (MACOS) for Catalyst.
  #
  # ENABLE_VISIBILITY=ON is mandatory: without it the toolchain sets
  # -fvisibility=hidden and every internal symbol becomes a local 't' (not 'T'),
  # so consumer code can't link against ExecuTorch.
  #
  # CMAKE_MACOSX_BUNDLE=OFF: sentencepiece's CMakeLists treats Catalyst as
  # macOS and defaults executables to MACOSX_BUNDLE without a BUNDLE
  # DESTINATION. Upstream's macos preset sets this to OFF; we mirror it.
  #
  # EXTENSION_APPLE / EXTENSION_LLM_APPLE are the Swift wrapper modules — the
  # bridge uses the C++ API directly, and the Swift wrappers tangle the build
  # with project-wide C-only flags leaking into swiftc.
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

  echo
  echo "==> Installing ExecuTorch headers/libs for $name into $INSTALL_DIR/$name"
  rm -rf "$INSTALL_DIR/$name"
  cmake --install "$et_build" --prefix "$INSTALL_DIR/$name"
}

# Args: name triple sysroot cc cxx
build_pthreadpool_platform() {
  local name="$1"
  local triple="$2"
  local sysroot="$3"
  local cc="$4"
  local cxx="$5"
  local ptp_build="$PTP_SRC/cmake-out-$name"

  echo
  echo "==> Building pthreadpool for $name (target=$triple)"
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
    exit 1
  fi
  echo "    -> $ptp_build/libpthreadpool.a"
}

# --- Build all three platforms ---------------------------------------------
# Each ExecuTorch build is ~30-60 min wall clock.

build_executorch_platform "ios"         "OS64"                "$IOS_DEPLOYMENT_TARGET"
build_executorch_platform "simulator"   "SIMULATORARM64"      "$IOS_DEPLOYMENT_TARGET"
build_executorch_platform "maccatalyst" "MAC_CATALYST_ARM64"  "$MACABI_DEPLOYMENT_TARGET"

build_pthreadpool_platform "ios"         "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"           "$IPHONEOS_SYSROOT"   "$CC_IOS"   "$CXX_IOS"
build_pthreadpool_platform "simulator"   "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" "$IPHONESIM_SYSROOT"  "$CC_SIM"   "$CXX_SIM"
build_pthreadpool_platform "maccatalyst" "arm64-apple-ios${MACABI_DEPLOYMENT_TARGET}-macabi" "$MACOSX_SYSROOT"     "$CC_MACOS" "$CXX_MACOS"

echo
echo "==> All three platforms built. Per-platform install trees:"
ls -d "$INSTALL_DIR"/* 2>/dev/null || true
echo
echo "==> Done. Next: scripts/executorch/02-stage-and-verify-libs.sh"
