#!/bin/bash
#
# Build ExecuTorch + pthreadpool static libraries for the Mac Catalyst SDK
# (arm64 only). Output lands in scripts/maccatalyst/.build/, ready for
# 02-stage-and-verify-libs.sh to copy into the repo.
#
# Run from anywhere; paths resolve relative to this script's location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
mkdir -p "$BUILD_DIR"

# --- Configuration ---------------------------------------------------------
# Default upstream pin. Override with EXECUTORCH_REF / PTHREADPOOL_REF env
# vars if you need a different version. There is no authoritative pin in
# this repo today; pick a ref whose exported symbols match the existing
# third-party/ios/libs/executorch/lib*_ios.a files.
EXECUTORCH_REPO="https://github.com/pytorch/executorch.git"
EXECUTORCH_REF="${EXECUTORCH_REF:-v0.5.0}"

PTHREADPOOL_REPO="https://github.com/Maratyszcza/pthreadpool.git"
PTHREADPOOL_REF="${PTHREADPOOL_REF:-master}"

# Mac Catalyst arm64 target triple. iOS 17.0 to match the rest of the build.
MACABI_TRIPLE="arm64-apple-ios17.0-macabi"
MACOSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"

CC="$(xcrun --sdk macosx --find clang)"
CXX="$(xcrun --sdk macosx --find clang++)"

COMMON_C_FLAGS="-target $MACABI_TRIPLE -isysroot $MACOSX_SYSROOT -fembed-bitcode-marker"
COMMON_CXX_FLAGS="$COMMON_C_FLAGS"

echo "==> Mac Catalyst toolchain"
echo "    clang     : $CC"
echo "    clang++   : $CXX"
echo "    sysroot   : $MACOSX_SYSROOT"
echo "    target    : $MACABI_TRIPLE"
echo

# --- pthreadpool -----------------------------------------------------------
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
  -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
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
  echo "==> Cloning ExecuTorch ($EXECUTORCH_REF)"
  git clone --recursive "$EXECUTORCH_REPO" "$ET_SRC"
  git -C "$ET_SRC" checkout "$EXECUTORCH_REF"
  git -C "$ET_SRC" submodule update --init --recursive
fi

# Upstream's install_requirements.sh expects a Python venv; users typically
# set this up once. If it's already done, this is a no-op.
if [ ! -d "$ET_SRC/.venv" ]; then
  echo "==> Bootstrapping ExecuTorch Python deps (one-time)"
  python3 -m venv "$ET_SRC/.venv"
  # shellcheck disable=SC1091
  source "$ET_SRC/.venv/bin/activate"
  pip install --upgrade pip
  (cd "$ET_SRC" && ./install_requirements.sh)
  deactivate
fi

echo "==> Building ExecuTorch for Mac Catalyst (arm64)"
rm -rf "$ET_BUILD"
cmake -S "$ET_SRC" -B "$ET_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$MACOSX_SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
  -DCMAKE_OBJC_FLAGS="$COMMON_C_FLAGS" \
  -DCMAKE_OBJCXX_FLAGS="$COMMON_CXX_FLAGS" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON \
  -DEXECUTORCH_BUILD_EXTENSION_LLM=ON \
  -DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON \
  -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON \
  -DEXECUTORCH_BUILD_KERNELS_LLM=ON \
  -DEXECUTORCH_BUILD_KERNELS_TORCHAO=ON \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_BUILD_COREML=ON \
  -DEXECUTORCH_BUILD_MPS=ON \
  -DEXECUTORCH_BUILD_PTHREADPOOL=ON \
  -DEXECUTORCH_BUILD_CPUINFO=ON
cmake --build "$ET_BUILD" --config Release -j

# Sanity: list what we just produced so 02 can stage it.
echo
echo "==> Produced libraries:"
find "$ET_BUILD" -name "*.a" -type f | sort
echo
echo "==> Done. Next: scripts/maccatalyst/02-stage-and-verify-libs.sh"
