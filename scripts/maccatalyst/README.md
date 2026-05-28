# Mac Catalyst build pipeline

These scripts add an `ios-arm64-maccatalyst` slice to
`packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework`
and verify it end-to-end against `apps/bare-rn`.

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
scripts/maccatalyst/01-build-upstream-libs.sh   # ~30–60 min, network + disk heavy
scripts/maccatalyst/02-stage-and-verify-libs.sh # copies artifacts in, lipo/otool checks
scripts/maccatalyst/03-build-xcframework.sh     # regenerates ExecutorchLib.xcframework
scripts/maccatalyst/04-verify-example-app.sh    # pod install + Catalyst build of bare-rn
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
  3.10–3.13 automatically; override with `MACCATALYST_PYTHON=/path/to/python`
  if needed.
- Node + Yarn already configured at repo root (used elsewhere in this repo)
- ~10 GB free disk for the upstream checkout + CMake build trees

## What each script does

### 01-build-upstream-libs.sh

Clones `pytorch/executorch` and `Maratyszcza/pthreadpool` into
`scripts/maccatalyst/.build/` (gitignored), then builds them for the Mac
Catalyst SDK (arm64 only).

ExecuTorch is built with the Ninja generator using `ios.toolchain.cmake` +
`PLATFORM=MAC_CATALYST_ARM64`. The Xcode generator path through that
toolchain is structurally broken for Catalyst: line 901 of
`ios.toolchain.cmake` documents that under Xcode it "modifies build-settings
directly instead" of injecting `-target …-macabi`, but the project-level
build settings get clobbered by ExecuTorch's per-target compile options.
Result: half the targets came out as platform 1 (MACOS), not 6 (MACCATALYST).
Ninja triggers the toolchain's compile-flag-injection codepath, which works
correctly. Ninja also supports Swift (required by `extension_apple`).

Override the deployment target with `MACABI_DEPLOYMENT_TARGET=17.0`
(default).

**Known scope limitation.** The maccatalyst slice intentionally omits
`EXTENSION_APPLE` and `EXTENSION_LLM_APPLE` (the `ExecuTorch` and
`ExecuTorchLLM` Swift wrapper modules). CMake's Ninja generator doesn't
cleanly split flags by language for mixed Swift+C++ targets, so project-
wide C-only flags (`-Wno-deprecated-declarations`, `-ffile-prefix-map=…`)
leak into swiftc and fail with "unknown argument". The Xcode generator
would side-step this but is structurally broken for Catalyst via this
toolchain (see preceding paragraph). The React Native bridge in this
repo uses the C++ API directly, so the wrappers aren't required. If a
future consumer needs `import ExecuTorch` on Catalyst, build
`extension_apple` separately under the Xcode generator and libtool-merge
the resulting `.a` into `libexecutorch_maccatalyst.a` from 02.

Sourcing upstream's preset matters: it enables `EXTENSION_APPLE`,
`EXTENSION_LLM_APPLE`, `EXTENSION_LLM_RUNNER`, `EXTENSION_FLAT_TENSOR`,
and the XNNPACK weight-cache / shared-workspace flags that the iOS and
macOS xcframeworks rely on. Without them the merged
`libexecutorch_llm_maccatalyst.a` artifact is missing required objects.

pthreadpool is built as a separate cmake project (with a manual
`-target arm64-apple-ios…-macabi` triple) because the podspec links
`libpthreadpool.a` directly for the maccatalyst slice rather than going
through the merged archives.

**Pin the ExecuTorch ref.** Defaults to `EXECUTORCH_REF=v0.5.0`. Verify it
matches the version of the existing `_ios.a` files before running — if
upstream has moved, override with `EXECUTORCH_REF=<sha-or-tag>` in the
environment.

### 02-stage-and-verify-libs.sh

Uses `libtool -static` to merge the per-target archives from `.build/` into
the consolidated `lib*_maccatalyst.a` files the ExecutorchLib xcodeproj
links against. The composition (which raw archives feed each consolidated
output) mirrors upstream's
`executorch/scripts/build_apple_frameworks.sh` `FRAMEWORK_*` definitions —
that's how iOS / macOS xcframeworks are built, so the maccatalyst slice
matches exactly.

Outputs:

```
packages/react-native-executorch/third-party/ios/libs/executorch/lib*_maccatalyst.a
packages/react-native-executorch/third-party/ios/libs/pthreadpool/maccatalyst-arm64-release/libpthreadpool.a
```

Then runs `lipo -archs` and `otool -l ... | grep platform` on each artifact
to confirm:
- single arm64 slice
- `LC_BUILD_VERSION` platform == `MACCATALYST` (Mach-O platform 6)

Source archives are resolved by basename within the build tree, so the
script tolerates upstream layout shifts but fails fast on a true rename or
missing target.

Also verifies that `packages/react-native-executorch/third-party/ios/libs/cpuinfo/libcpuinfo.a`
contains an arm64 slice usable for Mac Catalyst — if not, the script halts
and points at the rebuild instructions.

### 03-build-xcframework.sh

Runs `packages/react-native-executorch/third-party/ios/ExecutorchLib/build.sh`
(which now includes the maccatalyst archive step) and verifies the
regenerated xcframework's `Info.plist` lists three `AvailableLibraries`
entries, one with `LibraryIdentifier = ios-arm64-maccatalyst`.

The freshly built xcframework lands at:
`packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework/`

Commit it after this step (the repo tracks the xcframework as binary).

### 04-verify-example-app.sh

From `apps/bare-rn/ios/`:

1. Runs `pod install`.
2. Runs `xcodebuild ... -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64'`
   in Debug. Success means the catalyst slice links cleanly into a real
   consumer.
3. Runs the same build for `iphonesimulator,arch=arm64` as a regression
   check — must still succeed.

Both builds use `CODE_SIGNING_ALLOWED=NO` so no signing identity is needed.
Actually launching the Catalyst app on the host Mac (for runtime
verification of model inference) is a manual step described at the bottom
of the script.

## Cleaning up

`scripts/maccatalyst/.build/` is large; remove it once the staged `.a`
files have been committed:

```
rm -rf scripts/maccatalyst/.build
```
