# Build `libnode.so` for Android ARM64

This directory contains a self-contained GitHub Actions build for the Android ARM64 (`arm64-v8a`) version of Node.js Mobile.

## What it does

The workflow:

1. Checks out the Node.js Mobile `mobile-master` source tree.
2. Downloads the Android command-line tools.
3. Installs the Android SDK platform-tools and the pinned Android NDK.
4. Builds Node.js Mobile with the upstream `tools/android_build.sh <ndk> arm64` flow.
5. Publishes `out_android/arm64-v8a/libnode.so` as a GitHub Actions artifact.

The upstream build script explicitly maps the `arm64` target to the Android ABI directory `arm64-v8a` and copies `out/Release/lib.target/libnode.so` there.

## Run locally

```bash
./build_arm64.sh /path/to/android-ndk
```

The local helper expects a Linux host with the usual Node.js Mobile build prerequisites available. The GitHub Actions workflow is the recommended reproducible build path because it provisions the Android SDK/NDK automatically.

## Output

The artifact is named `libnode-android-arm64` and contains:

```text
arm64-v8a/libnode.so
```

## Source

- Node.js Mobile: https://github.com/nodejs-mobile/nodejs-mobile
- Upstream Android build script: `tools/android_build.sh`
