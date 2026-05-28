# ExecuTorch build pipeline

These scripts (re)build the entire native ExecuTorch xcframework that
this repo ships in
`packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework`
— iOS device, iOS Simulator, and Mac Catalyst slices — from a single
upstream ref. The bundled C++ headers under
`packages/react-native-executorch/third-party/include/` are also (re)generated
from the same source tree so headers and `.a` archives can never drift apart
again.

They must run on **macOS with Xcode 15+ installed and selected via
`xcode-select`**. Apple Silicon host strongly recommended (the target arch
is arm64-only by design — matches the iOS device/simulator policy that
already excludes x86_64).

The in-repo edits (pbxproj, podspec, build.sh, Podfile) are already
committed on this branch. These scripts produce the binary artifacts and
run the verification builds.

## Order

Run them in numeric order from the repo root:

```
scripts/executorch/01-build-upstream-libs.sh   # ~90-180 min (3 platforms), network + disk heavy
scripts/executorch/02-stage-and-verify-libs.sh # copies artifacts in, lipo/otool checks
scripts/executorch/03-build-xcframework.sh     # regenerates ExecutorchLib.xcframework
scripts/executorch/04-verify-example-app.sh    # pod install + Catalyst + simulator builds of bare-rn
```

Each script is idempotent and bails on the first failure (`set -euo pipefail`).

## Prerequisites

- Xcode 15+ (`xcode-select -p` should resolve to a real Xcode, not just CLT)
- CMake ≥ 3.24 (`brew install cmake`)
- Ninja (`brew install ninja`) — the ExecuTorch sub-build uses the Ninja
  generator because `ios.toolchain.cmake` only injects the macabi target
  triple + iOSSupport paths under non-Xcode generators
- Python in the range `>=3.10,<3.14` with `pip` (`brew install python@3.12`)
  — required by upstream ExecuTorch's setup. 01 picks the newest installed
  3.10–3.13 automatically; override with `EXECUTORCH_PYTHON=/path/to/python`
  if needed.
- Node + Yarn already configured at repo root (used elsewhere in this repo)
- ~15 GB free disk for the upstream checkout + three CMake build trees

## What each script does

### 01-build-upstream-libs.sh

Clones `pytorch/executorch` and `Maratyszcza/pthreadpool` into
`scripts/executorch/.build/` (gitignored), then runs three full ExecuTorch
builds — one per Apple platform slice — from the same source tree at the
same ref. Default `EXECUTORCH_REF=v1.3.0`; override only if you also
update the bridge consumer code to match the new API.

Each platform gets its own `cmake-out-{name}` build dir, freshly wiped per
configure pass (`ios.toolchain.cmake` prepends to `CMAKE_C_FLAGS … CACHE
INTERNAL` so leftover state poisons subsequent reconfigures). After the
build, `cmake --install` lays down a clean install tree at
`scripts/executorch/.build/install/{name}/` — both headers and merged
archives — which 02 (libs) and Phase 2 of the unification plan (headers)
consume.

Per-platform parameters:

| name        | PLATFORM            | sysroot         | triple                                    |
| ----------- | ------------------- | --------------- | ----------------------------------------- |
| ios         | OS64                | iphoneos        | arm64-apple-ios{TARGET}                   |
| simulator   | SIMULATORARM64      | iphonesimulator | arm64-apple-ios{TARGET}-simulator         |
| maccatalyst | MAC_CATALYST_ARM64  | macosx          | arm64-apple-ios{TARGET}-macabi            |

ExecuTorch is built with the Ninja generator using `ios.toolchain.cmake`.
The Xcode generator path through that toolchain is structurally broken for
Catalyst: line 901 of `ios.toolchain.cmake` documents that under Xcode it
"modifies build-settings directly instead" of injecting `-target …-macabi`,
but the project-level build settings get clobbered by ExecuTorch's
per-target compile options. Ninja triggers the toolchain's compile-flag
injection codepath, which works correctly. Ninja also supports Swift
(required if `extension_apple` is re-enabled in the future).

Override the deployment targets with `IOS_DEPLOYMENT_TARGET=17.0` and
`MACABI_DEPLOYMENT_TARGET=17.0` (defaults).

**Known scope limitation.** All three slices intentionally omit
`EXTENSION_APPLE` and `EXTENSION_LLM_APPLE` (the `ExecuTorch` and
`ExecuTorchLLM` Swift wrapper modules). CMake's Ninja generator doesn't
cleanly split flags by language for mixed Swift+C++ targets, so project-
wide C-only flags (`-Wno-deprecated-declarations`, `-ffile-prefix-map=…`)
leak into swiftc and fail with "unknown argument". The bridge in this repo
uses the C++ API directly, so the wrappers aren't required.

pthreadpool is built as a separate cmake project (with a manual
`-target …` triple per platform) because the podspec links
`libpthreadpool.a` directly for each slice rather than going through the
merged archives.

### 02-stage-and-verify-libs.sh

For each of `ios`, `simulator`, and `maccatalyst`, uses `libtool -static`
to merge the per-target archives from `.build/executorch/cmake-out-{name}/`
into the consolidated `lib*_{name}.a` files the ExecutorchLib xcodeproj
links against. Then runs `lipo -archs` and `otool -l ... | grep platform`
on each to confirm:
- single arm64 slice
- correct `LC_BUILD_VERSION` platform (2=IOS, 6=MACCATALYST, 7=IOS_SIMULATOR)

Outputs:

```
packages/react-native-executorch/third-party/ios/libs/executorch/lib*_ios.a
packages/react-native-executorch/third-party/ios/libs/executorch/lib*_simulator.a
packages/react-native-executorch/third-party/ios/libs/executorch/lib*_maccatalyst.a
packages/react-native-executorch/third-party/ios/libs/pthreadpool/physical-arm64-release/libpthreadpool.a
packages/react-native-executorch/third-party/ios/libs/pthreadpool/simulator-arm64-debug/libpthreadpool.a
packages/react-native-executorch/third-party/ios/libs/pthreadpool/maccatalyst-arm64-release/libpthreadpool.a
```

The composition (which raw archives feed each consolidated output) mirrors
upstream's `executorch/scripts/build_apple_frameworks.sh` `FRAMEWORK_*`
definitions. Source archives are resolved by basename within the build
tree, so the script tolerates upstream layout shifts but fails fast on a
true rename or missing target.

Also verifies that
`packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a`
contains an arm64 slice usable for all three platforms.

### 03-build-xcframework.sh

Runs `packages/react-native-executorch/third-party/ios/ExecutorchLib/build.sh`
(which builds all three xcarchive slices via `xcodebuild`) and verifies the
regenerated xcframework's `Info.plist` lists three `AvailableLibraries`
entries with `LibraryIdentifier` values `ios-arm64`, `ios-arm64-simulator`,
and `ios-arm64-maccatalyst`.

The freshly built xcframework lands at:
`packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework/`

Commit it after this step (the repo tracks the xcframework as binary via
Git LFS).

### 04-verify-example-app.sh

From `apps/bare-rn/ios/`:

1. Runs `pod install`.
2. Runs `xcodebuild ... -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64'`
   in Debug. Success means the catalyst slice links cleanly into a real
   consumer.
3. Runs the same build for `iphonesimulator,arch=arm64` as a regression
   check.

Both builds use `CODE_SIGNING_ALLOWED=NO` so no signing identity is needed.
Actually launching the app on the host Mac / simulator (for runtime
verification of model inference) is a manual step described at the bottom
of the script.

## Replacing the bundled C++ headers

After 01 finishes, refresh the bundled C++ include tree from the install
output (headers are platform-independent; any of the three installs works,
we use simulator by convention):

```
rm -rf packages/react-native-executorch/third-party/include/executorch
rm -rf packages/react-native-executorch/third-party/include/pytorch
rm -rf packages/react-native-executorch/third-party/include/nlohmann
cp -R scripts/executorch/.build/install/simulator/include/executorch  packages/react-native-executorch/third-party/include/
cp -R scripts/executorch/.build/install/simulator/include/pytorch     packages/react-native-executorch/third-party/include/
cp -R scripts/executorch/.build/install/simulator/include/nlohmann    packages/react-native-executorch/third-party/include/ 2>/dev/null || true
```

Keep the `cpuinfo/`, `pthreadpool/`, and any other non-executorch headers
already in `third-party/include/` unless the install populated them.

## Cleaning up

`scripts/executorch/.build/` is large (~15 GB); remove it once the staged
`.a` files have been committed:

```
rm -rf scripts/executorch/.build
```
