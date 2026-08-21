# Android ARM64 `libnode.so` build

This directory contains the complete reproducible build script and GitHub Actions workflow for producing an Android ARM64 (`arm64-v8a`) shared Node.js library.

The build uses:

- the newest Node.js LTS source from the official Node.js distribution;
- a pinned `nodejs-mobile` commit for `android-configure` and `android_configure.py`;
- Android API 24;
- Android NDK `27.3.13750724` (Android NDK r27d LTS);
- Python 3 only.

The old `mobile-master` build and Python 2.7 are intentionally not used.

## Files

- `build_android_arm64.sh` — the actual build script. The workflow only provisions dependencies and calls this script.
- `README.md` — this documentation.
- `.github/workflows/build-libnode-arm64.yml` — minimal GitHub Actions wrapper around the script.

Keeping the build logic in a normal repository script makes it possible to reproduce the same build locally and avoids complicated shell quoting and package-generation logic in YAML.

## Build flow

1. Resolve the newest LTS version from `nodejs.org`, or use a full version such as `24.19.0`.
2. Validate all workflow inputs before they reach shell paths or URLs.
3. Download the official Node.js source and verify its SHA-256 against the release checksum file.
4. Fetch the pinned `nodejs-mobile` commit rather than a moving branch.
5. Install Android SDK/NDK in GitHub Actions and verify the command-line tools archive SHA-256.
6. Run `nodejs-mobile/android-configure` against the official Node.js source for `arm64`.
7. Build with GNU Make using all available runner CPUs and 16 KiB Android page-size linker flags.
8. Locate `libnode.so` and verify that it is a non-empty ELF64 AArch64 shared library.
9. Generate `metadata.json`, `BUILD_INFO.md`, and detailed build logs.
10. Create an explicit ZIP archive containing the library, metadata and logs.
11. Generate a SHA-256 checksum for the ZIP and upload both as Actions artifacts.

## Artifact

The main artifact is a real ZIP file, for example:

```text
libnode-android-arm64-v24.19.0.zip
├── arm64-v8a/
│   └── libnode.so
├── metadata.json
├── BUILD_INFO.md
├── config-summary.log
├── configure.log
├── build.log
├── file.log
└── readelf.log
```

A separate `.sha256` file contains the checksum of the ZIP archive.

`metadata.json` records the Node.js version, Node.js source checksum, exact `nodejs-mobile` tools commit, Android API, NDK version, ABI, linker flags, library checksum and size, and the GitHub source/run identifiers.

## Security and reproducibility

- GitHub Actions has `contents: read` only.
- Checkout does not persist the GitHub token in the repository working tree.
- The Android command-line tools archive is pinned and SHA-256 verified.
- The `nodejs-mobile` source is fetched by an exact 40-character commit SHA.
- Node.js version input is restricted to `lts` or a full semantic version, preventing path/URL injection.
- Android API and NDK version inputs are validated before use.
- The build does not use `eval`, `curl | sh`, Python 2, or generated executable code from workflow inputs.
- The output architecture, ELF class and shared-library type are checked before packaging.

## Manual build

The GitHub runner provisions the Android SDK/NDK automatically. For a local Linux build, install the same prerequisites and export:

```text
ANDROID_SDK_ROOT=/path/to/android-sdk
ANDROID_NDK_HOME=/path/to/android-sdk/ndk/27.3.13750724
ANDROID_NDK_ROOT=/path/to/android-sdk/ndk/27.3.13750724
ANDROID_API=24
NDK_VERSION=27.3.13750724
NODE_VERSION_REQUEST=lts
```

Then run:

```text
./make_dependencies/build_android_arm64.sh
```

## Upstream notes

Node.js documents the Android cross-configuration flow and supports `arm64` as an Android target, while noting that Android is not covered by its normal upstream CI. The build therefore performs explicit toolchain, architecture, file-size and checksum checks rather than treating a successful `make` command as sufficient.
