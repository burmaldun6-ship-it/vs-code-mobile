# Android ARM64 `libnode.so` build

This directory contains the complete reproducible build script and GitHub Actions workflow for producing an Android ARM64 (`arm64-v8a`) shared Node.js library.

The build uses:

- the newest Node.js LTS source from the official Node.js distribution;
- the current Android configuration scripts from `nodejs-mobile` (`android-configure` and `android_configure.py`);
- Android API 24;
- Android NDK `27.3.13750724`;
- Python 3 only.

The old `mobile-master` build and Python 2.7 are intentionally not used.

## Files

- `build_android_arm64.sh` — the actual build script. The workflow only provisions dependencies and calls this script.
- `README.md` — this documentation.
- `.github/workflows/build-libnode-arm64.yml` — minimal GitHub Actions wrapper around the script.

Keeping the build logic in a normal repository script makes it possible to reproduce the same build locally and avoids putting complicated shell quoting and package-generation logic into YAML.

## Build flow

1. Resolve the newest LTS version from `nodejs.org`, or use `NODE_VERSION_REQUEST` for an exact version.
2. Download the official Node.js source and verify its SHA-256 against `SHASUMS256.txt`.
3. Clone `nodejs-mobile` and record its exact commit.
4. Install Android SDK/NDK in GitHub Actions.
5. Run `nodejs-mobile/android-configure` against the official Node.js source for `arm64`.
6. Build with GNU Make using all available runner CPUs.
7. Locate `libnode.so` and verify that it is a non-empty AArch64 ELF shared library.
8. Generate `metadata.json`, `BUILD_INFO.md`, and build logs.
9. Create an explicit ZIP archive containing the library and metadata.
10. Generate a SHA-256 checksum for the ZIP and upload both as Actions artifacts.

## Artifact

The main artifact is a real ZIP file, for example:

```text
libnode-android-arm64-v24.x.x.zip
├── arm64-v8a/
│   └── libnode.so
├── metadata.json
├── BUILD_INFO.md
├── configure.log
├── build.log
└── readelf.log
```

A separate `.sha256` file contains the checksum of the ZIP archive.

`metadata.json` records the Node.js version, Node.js source checksum, exact `nodejs-mobile` tools commit, Android API, NDK version, ABI, library checksum and size, and the GitHub source commit.

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
