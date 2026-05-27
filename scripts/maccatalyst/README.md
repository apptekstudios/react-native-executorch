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
- Python 3.10+ with `pip` (`brew install python@3.11`) — required by
  upstream ExecuTorch's setup
- Node + Yarn already configured at repo root (used elsewhere in this repo)
- ~10 GB free disk for the upstream checkout + CMake build trees

## What each script does

### 01-build-upstream-libs.sh

Clones `pytorch/executorch` and `Maratyszcza/pthreadpool` into
`scripts/maccatalyst/.build/` (gitignored), then builds them for the Mac
Catalyst SDK (arm64 only, target triple `arm64-apple-ios17.0-macabi`).

Produces:
- `scripts/maccatalyst/.build/executorch/cmake-out-maccatalyst/lib*.a`
  (one per ExecuTorch backend / kernel module)
- `scripts/maccatalyst/.build/pthreadpool/cmake-out-maccatalyst/libpthreadpool.a`

**Pin the ExecuTorch ref.** The script defaults to the upstream tag listed in
`UPSTREAM_REF` at the top of the script. Verify it matches the version of
the existing `_ios.a` files before running — if upstream has moved, override
with `EXECUTORCH_REF=<sha-or-tag>` in the environment. There's currently no
authoritative pin in this repo, so the chosen ref needs human verification.

### 02-stage-and-verify-libs.sh

Copies the built `.a` files from `.build/` into the in-repo locations the
xcframework build expects:

```
packages/react-native-executorch/third-party/ios/libs/executorch/lib*_maccatalyst.a
packages/react-native-executorch/third-party/ios/libs/pthreadpool/maccatalyst-arm64-release/libpthreadpool.a
```

Then runs `lipo -info` and `otool -l ... | grep platform` on each artifact
to confirm:
- single arm64 slice
- `LC_BUILD_VERSION` platform == `MACCATALYST` (Mach-O platform 6)

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
