#!/bin/bash
#
# Build ExecuTorch + pthreadpool static libraries for the Mac Catalyst SDK
# (arm64 only). Output lands in scripts/maccatalyst/.build/, ready for
# 02-stage-and-verify-libs.sh to libtool-merge into the repo.
#
# Run from anywhere; paths resolve relative to this script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
mkdir -p "$BUILD_DIR"

# --- Configuration ---------------------------------------------------------
EXECUTORCH_REPO="https://github.com/pytorch/executorch.git"
# v1.2.0 is the ref the bundled iOS / iOS-simulator .a slices were built
# from (see this repo's commit "build: bump executorch to v1.2.0" #1076).
# Newer refs (e.g. main) add a `kernel_registry` param to
# Module::load_method that breaks ABI against the bundled headers; older
# refs (v0.5.0) predate `LoadBackendOptionsMap`. Override only if you've
# also rebuilt the iOS / simulator slices from the same ref.
EXECUTORCH_REF="${EXECUTORCH_REF:-v1.2.0}"

PTHREADPOOL_REPO="https://github.com/Maratyszcza/pthreadpool.git"
PTHREADPOOL_REF="${PTHREADPOOL_REF:-master}"

# iOS deployment target the rest of this project uses. The toolchain emits
# arm64-apple-ios${DEPLOYMENT_TARGET}-macabi from this.
MACABI_DEPLOYMENT_TARGET="${MACABI_DEPLOYMENT_TARGET:-17.0}"

# Manual triple for the pthreadpool subbuild (it doesn't use ExecuTorch's
# toolchain). ExecuTorch's own build derives its triple from PLATFORM via
# ios.toolchain.cmake instead.
MACABI_TRIPLE="arm64-apple-ios${MACABI_DEPLOYMENT_TARGET}-macabi"
MACOSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"

CC="$(xcrun --sdk macosx --find clang)"
CXX="$(xcrun --sdk macosx --find clang++)"

PTP_C_FLAGS="-target $MACABI_TRIPLE -isysroot $MACOSX_SYSROOT -fembed-bitcode-marker"

if ! command -v ninja >/dev/null 2>&1; then
  echo "ERROR: ninja not found on PATH." >&2
  echo "       The ExecuTorch sub-build uses the Ninja generator because" >&2
  echo "       Xcode + ios.toolchain.cmake + MAC_CATALYST_ARM64 has structural" >&2
  echo "       gaps (see comment in this script near 'cmake -S ... -G Ninja')." >&2
  echo "       Install with: brew install ninja" >&2
  exit 1
fi

echo "==> Mac Catalyst toolchain"
echo "    clang     : $CC"
echo "    clang++   : $CXX"
echo "    sysroot   : $MACOSX_SYSROOT"
echo "    target    : $MACABI_TRIPLE (pthreadpool only)"
echo "    executorch: PLATFORM=MAC_CATALYST_ARM64, DEPLOYMENT_TARGET=$MACABI_DEPLOYMENT_TARGET"
echo

# --- pthreadpool -----------------------------------------------------------
# Built standalone because the podspec links libpthreadpool.a directly for
# the maccatalyst slice (see react-native-executorch.podspec).
PTP_SRC="$BUILD_DIR/pthreadpool"
PTP_BUILD="$PTP_SRC/cmake-out-maccatalyst"

if [ ! -d "$PTP_SRC/.git" ]; then
  echo "==> Cloning pthreadpool ($PTHREADPOOL_REF)"
  git clone --depth 1 --branch "$PTHREADPOOL_REF" "$PTHREADPOOL_REPO" "$PTP_SRC"
fi

echo "==> Building pthreadpool for Mac Catalyst (arm64)"
rm -rf "$PTP_BUILD"
cmake -S "$PTP_SRC" -B "$PTP_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$MACOSX_SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$PTP_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$PTP_C_FLAGS" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DPTHREADPOOL_BUILD_TESTS=OFF \
  -DPTHREADPOOL_BUILD_BENCHMARKS=OFF
cmake --build "$PTP_BUILD" --config Release -j

if [ ! -f "$PTP_BUILD/libpthreadpool.a" ]; then
  echo "ERROR: libpthreadpool.a was not produced at $PTP_BUILD" >&2
  exit 1
fi
echo "    -> $PTP_BUILD/libpthreadpool.a"
echo

# --- ExecuTorch ------------------------------------------------------------
ET_SRC="$BUILD_DIR/executorch"
ET_BUILD="$ET_SRC/cmake-out-maccatalyst"

if [ ! -d "$ET_SRC/.git" ]; then
  echo "==> Cloning ExecuTorch"
  # Important: do NOT use --recursive here. Some refs (e.g. v0.5.0) have
  # `shim/` as a regular tracked directory while HEAD has it as a submodule,
  # so submodule-at-HEAD files conflict with the ref's tracked content during
  # `git checkout`. Init submodules AFTER the ref is checked out.
  git clone --no-recurse-submodules "$EXECUTORCH_REPO" "$ET_SRC"
fi

# Always re-sync to EXECUTORCH_REF (idempotent). Prior versions of this
# script only checked out the ref inside the clone-if-missing block, so
# HEAD could drift if the user later did anything in the source tree —
# the symptom was an ABI mismatch against the bundled iOS .a (e.g.
# Module::load_method gained a kernel_registry param on main).
CURRENT_REF="$(git -C "$ET_SRC" rev-parse HEAD)"
DESIRED_REF="$(git -C "$ET_SRC" rev-parse "$EXECUTORCH_REF" 2>/dev/null || true)"
if [ -z "$DESIRED_REF" ] || [ "$CURRENT_REF" != "$DESIRED_REF" ]; then
  echo "==> Syncing ExecuTorch to $EXECUTORCH_REF"
  # --force needed because upstream's ciflow/trunk/* CI tags get periodically
  # force-pushed; without it fetch prints scary-looking "would clobber existing
  # tag" warnings for every one. They're benign (exit 0), but noisy.
  git -C "$ET_SRC" fetch --tags --force origin
  git -C "$ET_SRC" checkout "$EXECUTORCH_REF"
  git -C "$ET_SRC" submodule update --init --recursive
fi


# ExecuTorch supports Python >=3.10,<3.14. Override with MACCATALYST_PYTHON.
pick_python() {
  if [ -n "${MACCATALYST_PYTHON:-}" ]; then
    command -v "$MACCATALYST_PYTHON" || return 1
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
  echo "       Install one (e.g. \`brew install python@3.12\`) or set MACCATALYST_PYTHON." >&2
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

echo "==> Building ExecuTorch for Mac Catalyst (arm64)"
rm -rf "$ET_BUILD"
VENV_PYTHON="$ET_SRC/.venv/bin/python"

# Ninja generator (not Xcode) because ios.toolchain.cmake only injects the
# macabi target triple + iOSSupport include/framework paths in its non-Xcode
# branch (see line 901 of ios.toolchain.cmake). With Xcode + this toolchain,
# the build defaults to platform 1 (MACOS) and CMAKE_XCODE_ATTRIBUTE_*
# overrides get clobbered by ExecuTorch's per-target compile options.
#
# Ninja supports Swift (extension_apple) since CMake 3.15+, so the Swift
# module emission that fails under Unix Makefiles works here.
#
# Source the macos preset cmake file for the EXTENSION_APPLE /
# EXTENSION_LLM_APPLE / EXTENSION_LLM_RUNNER / EXTENSION_FLAT_TENSOR /
# XNNPACK weight-cache flags that produce the source archives 02 merges.
# Temporarily Debug to diagnose a runtime crash that doesn't happen on iOS:
# disables -O3 (rules in/out clang miscompile under macabi codegen) and
# enables assert() inside v1.2.0's tokenizers — including
# StringIntegerMap::getElement's `assert(index < size_)` which would catch
# the "size_ > 0 but storage empty" path. Switch back to Release once the
# root cause is found.
cmake -S "$ET_SRC" -B "$ET_BUILD" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$ET_BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$ET_SRC/third-party/ios-cmake/ios.toolchain.cmake" \
  -DEXECUTORCH_BUILD_PRESET_FILE="$ET_SRC/tools/cmake/preset/macos.cmake" \
  -DPLATFORM=MAC_CATALYST_ARM64 \
  -DDEPLOYMENT_TARGET="$MACABI_DEPLOYMENT_TARGET" \
  -DENABLE_VISIBILITY=ON \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DPython3_EXECUTABLE="$VENV_PYTHON" \
  -DPython_EXECUTABLE="$VENV_PYTHON" \
  -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF \
  -DEXECUTORCH_COREML_BUILD_EXECUTOR_RUNNER=OFF \
  -DEXECUTORCH_BUILD_EXTENSION_APPLE=OFF \
  -DEXECUTORCH_BUILD_EXTENSION_LLM_APPLE=OFF
# EXTENSION_APPLE and EXTENSION_LLM_APPLE are the Swift wrapper modules
# (ExecuTorch / ExecuTorchLLM). They're enabled by the macos preset's
# apple_common.cmake by default but are not consumed by this repo's React
# Native bridge — which uses ExecuTorch's C++ API directly. Disabling them
# for Catalyst sidesteps CMake-Ninja's incomplete handling of mixed
# Swift+C++ targets (project-wide C-only flags like -Wno-deprecated-
# declarations get passed to swiftc and fail with "unknown argument").
# Trade-off: the maccatalyst slice lacks the `import ExecuTorch` /
# `import ExecuTorchLLM` Swift wrappers that the iOS slice provides.
cmake --build "$ET_BUILD"

# Sanity: list what we just produced so 02 can stage it.
echo
echo "==> Produced libraries:"
find "$ET_BUILD" -name "*.a" -type f | sort
echo
echo "==> Done. Next: scripts/maccatalyst/02-stage-and-verify-libs.sh"
