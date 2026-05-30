# ExecuTorch build pipeline

These scripts (re)build the entire native ExecuTorch xcframework that
this repo ships in
`packages/react-native-executorch/third-party/ios/ExecutorchLib.xcframework`
— iOS device, iOS Simulator, and Mac Catalyst slices — from a single
upstream ref. The bundled C++ headers under
`packages/react-native-executorch/third-party/include/` are also (re)generated
from the same source tree so headers and `.a` archives can never drift apart.

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
scripts/executorch/01-build.sh                            # ~90-180 min — clones, overlays, builds three slices, stages, repackages xcframework
scripts/executorch/02-reinstall-pods-for-example-apps.sh  # pod install across every apps/* and prints `open …xcworkspace` lines
scripts/executorch/03-test-bare-rn-build.sh               # xcodebuild apps/bare-rn for Mac Catalyst + iOS Simulator
```

Each script is idempotent and bails on the first failure (`set -euo pipefail`).

## `01-build.sh` — the unified build driver

Runs **21 numbered steps**; each step is announced before it runs, a green
check is printed when it finishes, and the active step is the one reported
in the failure banner if anything goes wrong.

```bash
$ scripts/executorch/01-build.sh --list
Step table
   1. prereqs                Verify host toolchain (xcode-select, ninja, python)
   2. sync-executorch        Clone or sync ExecuTorch to v1.3.0
   3. patch-flatc            Pin flatc host deployment target to macOS 12.0
   4. sync-tokenizers        Bump tokenizers submodule to origin/main
   5. overlay-tokenizers     Overlay local tokenizer ops (Bert/Metaspace/WordPiece/…)
   6. python-venv            Bootstrap ExecuTorch Python venv + install_requirements.sh
   7. sync-pthreadpool       Clone or sync pthreadpool
   8. build-et-ios           Build ExecuTorch for iOS device
   9. build-et-sim           Build ExecuTorch for iOS Simulator
  10. build-et-cat           Build ExecuTorch for Mac Catalyst
  11. build-ptp-ios          Build pthreadpool for iOS device
  12. build-ptp-sim          Build pthreadpool for iOS Simulator
  13. build-ptp-cat          Build pthreadpool for Mac Catalyst
  14. stage-ios              Stage iOS slice (libtool-merge + verify Mach-O platform)
  15. stage-sim              Stage iOS Simulator slice
  16. stage-cat              Stage Mac Catalyst slice
  17. verify-cpuinfo         Verify cpuinfo lib carries arm64
  18. vendor-headers         Re-vendor overlaid tokenizers headers into the bundled include tree
  19. xcf-build              Run ExecutorchLib/build.sh to (re)build the xcframework
  20. xcf-install            Replace third-party/ios/ExecutorchLib.xcframework
  21. xcf-verify             Verify Info.plist lists all three slices
```

**Resume after a failure.** The ERR trap prints
`✗ FAILED at step N/M: <id>` with the exit code and an exact
`--from N` command to resume after fixing the root cause. So if the
30-minute Mac Catalyst ExecuTorch build (step 10) crashes you don't need
to rerun the seven cheap setup steps:

```bash
scripts/executorch/01-build.sh --from 10
```

Other flags:
- `--to N` — stop after step N (e.g. `--to 13` to just build the binaries, not stage them)
- `--only N[,M,…]` — run only the listed steps (e.g. `--only 18,19,20,21` to
  re-vendor headers + repackage the xcframework without rebuilding anything)
- `--list` — print the step table without running anything
- `--help` — full usage

### What the steps actually do

**Steps 1-7 (setup).** `prereqs` resolves all the SDK sysroots, clangs, and
libtool from `xcrun` and confirms ninja + a 3.10-3.13 Python are on PATH.
`sync-executorch` clones `pytorch/executorch.git` into
`scripts/executorch/.build/executorch/` and checks out `EXECUTORCH_REF`
(default `v1.3.0`). `patch-flatc` flips `third-party/CMakeLists.txt` so
flatc/flatcc target macOS 12.0 instead of inheriting the project's iOS 17.0
deployment target (Xcode 26 / SDK 26 host clang rejects
`-mmacosx-version-min=17.0` because macOS 17 doesn't exist).

`sync-tokenizers` + `overlay-tokenizers` bump
`extension/llm/tokenizers` to `TOKENIZERS_REF` (default `origin/main`) —
ExecuTorch v1.3.0 pins meta-pytorch/tokenizers at `b642403`, which lacks
most of the HuggingFace tokenizer ops real models ship — then overlay our
own `.h`/`.cpp` files from `patches/tokenizers/` on top:

- **Normalizers**: `BertNormalizer`, `LowercaseNormalizer`, `NFDNormalizer`,
  `NFKC`/`NFKDNormalizer`, `StripNormalizer`, `StripAccentsNormalizer`,
  `NmtNormalizer`, `ByteLevelNormalizer`, passthrough `PrecompiledNormalizer`.
- **Pre-tokenizers**: `BertPreTokenizer` (whitespace split → punctuation
  isolation, per `pre_tokenizers/bert.rs`) and `MetaspacePreTokenizer`
  (`space → ▁` with optional prepend/split, per `metaspace.rs`).
- **Decoders**: `WordPiece` (strip `##` continuation prefix, optional
  cleanup of contraction/punctuation spacing, per `decoders/wordpiece.rs`).
- **Post-processors**: `BertProcessing` and `RobertaProcessing` (per
  `processors/{bert,roberta}.rs`). Both wrap a single sequence as
  `[cls, …, sep]`; pair form is `[cls, A, sep, B, sep]` for Bert and
  `[cls, A, sep, sep, B, sep]` for Roberta. `trim_offsets` /
  `add_prefix_space` are accepted but no-op (offsets aren't carried).
- **HFTokenizer**: `parse_merges` short-circuits to `Error::Ok` when the
  model self-identifies as non-BPE or has no `merges` field, so WordPiece /
  Unigram / WordLevel tokenizer.json files load cleanly.

Together these cover every tokenizer.json variant used by the example apps
(BERT-family SentenceTransformer embeddings, Hammer 2.1 SentencePiece LLM,
and the existing ByteLevel-based LLMs).

`python-venv` bootstraps `scripts/executorch/.build/executorch/.venv` and
runs `install_requirements.sh` once (it's a no-op on subsequent runs).
`sync-pthreadpool` shallow-clones `Maratyszcza/pthreadpool`.

**Steps 8-13 (per-platform CMake builds).** Three ExecuTorch builds + three
pthreadpool builds. Each ExecuTorch build is 30-60 minutes wall clock.

| step name      | PLATFORM            | sysroot         | triple                                    |
| -------------- | ------------------- | --------------- | ----------------------------------------- |
| build-et-ios   | OS64                | iphoneos        | arm64-apple-ios{TARGET}                   |
| build-et-sim   | SIMULATORARM64      | iphonesimulator | arm64-apple-ios{TARGET}-simulator         |
| build-et-cat   | MAC_CATALYST_ARM64  | macosx          | arm64-apple-ios{TARGET}-macabi            |

ExecuTorch is built with the Ninja generator using `ios.toolchain.cmake`.
The Xcode generator path through that toolchain is structurally broken for
Catalyst: line 901 of `ios.toolchain.cmake` documents that under Xcode it
"modifies build-settings directly instead" of injecting `-target …-macabi`,
but the project-level settings get clobbered by ExecuTorch's per-target
compile options. Ninja triggers the toolchain's compile-flag injection
codepath, which works correctly.

All three slices intentionally omit `EXTENSION_APPLE` and
`EXTENSION_LLM_APPLE` (the `ExecuTorch` / `ExecuTorchLLM` Swift wrappers).
The bridge uses the C++ API directly, so the wrappers aren't required;
including them tangles the build with project-wide C-only flags leaking
into swiftc.

Override deployment targets with `IOS_DEPLOYMENT_TARGET=17.0` and
`MACABI_DEPLOYMENT_TARGET=17.0` (defaults).

**Steps 14-17 (staging + verify).** For each slice, `libtool -static`
merges the per-target archives from `.build/executorch/cmake-out-{name}/`
into consolidated `lib*_{name}.a` files the ExecutorchLib xcodeproj links
against, then `lipo -archs` + `otool -l | grep platform` confirms each is
single-arch arm64 on the expected `LC_BUILD_VERSION` platform code
(2=IOS, 6=MACCATALYST, 7=IOS_SIMULATOR). The composition mirrors
upstream's `executorch/scripts/build_apple_frameworks.sh` `FRAMEWORK_*`
definitions. Source archives are resolved by basename so the script
tolerates upstream layout shifts but fails fast on a true rename or
missing target. `verify-cpuinfo` confirms the existing shared
`libcpuinfo.a` carries an arm64 slice.

**Step 18 (vendor-headers).** Mirrors the overlaid tokenizer headers from
`.build/install/simulator/include/pytorch/tokenizers/` back into the
bundled
`packages/react-native-executorch/third-party/include/pytorch/tokenizers/`
so consumer code sees the API the libs were compiled against. (Picking
simulator is arbitrary — headers are platform-independent.)

**Steps 19-21 (xcframework).** Runs
`packages/react-native-executorch/third-party/ios/ExecutorchLib/build.sh`
(which builds all three xcarchive slices via `xcodebuild`), replaces the
bundled `ExecutorchLib.xcframework`, and confirms the regenerated
`Info.plist` lists all three `AvailableLibraries` entries
(`ios-arm64`, `ios-arm64-simulator`, `ios-arm64-maccatalyst`).

### Environment overrides

| variable                   | default       | purpose                                            |
| -------------------------- | ------------- | -------------------------------------------------- |
| `EXECUTORCH_REF`           | `v1.3.0`      | upstream ExecuTorch ref to check out               |
| `TOKENIZERS_REF`           | `origin/main` | tokenizers submodule pin (override at your peril)  |
| `PTHREADPOOL_REF`          | `master`      | pthreadpool ref                                    |
| `EXECUTORCH_PYTHON`        | auto          | force a specific python interpreter                |
| `IOS_DEPLOYMENT_TARGET`    | `17.0`        | iOS / simulator deployment target                  |
| `MACABI_DEPLOYMENT_TARGET` | `17.0`        | Mac Catalyst deployment target                     |

## `02-reinstall-pods-for-example-apps.sh`

Runs `pod install` for every `apps/*/ios` that has a `Podfile`
(currently bare-rn, computer-vision, llm, speech, text-embeddings), forcing
each Pods project to re-link against the freshly rebuilt
`ExecutorchLib.xcframework` and `.a` archives. After all installs succeed,
prints one `open <abs-path>.xcworkspace` line per app under an
"Open in Xcode:" header so the workspaces can be opened in a single
copy-paste batch.

## `03-test-bare-rn-build.sh`

From `apps/bare-rn/ios/`:

1. Runs `pod install` (redundant if you just ran `02`, but safe).
2. Runs `xcodebuild … -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64'`
   in Debug. Success means the Catalyst slice links cleanly into a real
   consumer.
3. Runs the same build for `iphonesimulator,arch=arm64` as a regression
   check.

Both builds use `CODE_SIGNING_ALLOWED=NO` so no signing identity is needed.
Launching the app on the host Mac / simulator (for runtime verification of
model inference) is a manual step described at the bottom of the script.

## Prerequisites

- Xcode 15+ (`xcode-select -p` should resolve to a real Xcode, not just CLT)
- CMake ≥ 3.24 (`brew install cmake`)
- Ninja (`brew install ninja`) — `01-build.sh` step 1 verifies this
- Python in the range `>=3.10,<3.14` with `pip` (`brew install python@3.12`).
  Step 1 picks the newest installed 3.10-3.13 automatically; override with
  `EXECUTORCH_PYTHON=/path/to/python`.
- Node + Yarn already configured at repo root (used by `02`/`03`)
- ~15 GB free disk for the upstream checkout + three CMake build trees

## Cleaning up

`scripts/executorch/.build/` is large (~15 GB); remove it once the staged
`.a` files have been committed:

```
rm -rf scripts/executorch/.build
```
