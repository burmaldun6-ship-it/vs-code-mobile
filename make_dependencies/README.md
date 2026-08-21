# Build `libnode.so` for Android ARM64

This directory contains a reproducible GitHub Actions build for an Android ARM64 (`arm64-v8a`) **shared Node.js library** (`libnode.so`).

The pipeline deliberately does **not** build the old `nodejs-mobile/mobile-master` source tree. Instead it combines:

- the current Node.js LTS source from the official Node.js distribution;
- the Android cross-compilation logic from `nodejs-mobile` (`android-configure` and `android_configure.py`);
- a pinned Android NDK known to work with Node.js 24.x;
- explicit checks, logs and reproducibility metadata.

Node.js 24.x is currently an LTS line; the workflow resolves the newest LTS automatically when `node_version` is left as `lts`. citeturn289789search2turn289789search10

## GitHub Actions

Workflow: **Build libnode Android ARM64 (current LTS)**

Default behavior:

```text
Node.js: newest LTS
Android API: 24
ABI: arm64-v8a
NDK: 27.3.13750724
```

The workflow is triggered by changes under `make_dependencies/**` or by the workflow file itself. It can also be started manually from **Actions → Run workflow**, where `node_version` can be set to `lts` or an exact version such as `24.19.0`.

## Build flow

1. Resolve the current Node.js LTS version from `nodejs.org`.
2. Download the official Node.js source tarball and verify its SHA-256 against `SHASUMS256.txt`.
3. Clone `nodejs-mobile` only to reuse its Android configuration scripts.
4. Install Android SDK command-line tools and NDK automatically.
5. Configure the official Node.js source for Android ARM64 with `--shared`.
6. Build `libnode.so` with GNU Make.
7. Verify the output is a non-empty ELF AArch64 shared library.
8. Create an explicit ZIP archive containing the library, metadata and build logs.
9. Upload that ZIP and its SHA-256 checksum as the Actions artifact.

The Node.js build documentation lists Android ARM64 as a possible target through an Android cross-configuration flow, but also notes that Android is not a supported CI platform upstream; that is why the workflow performs extensive local verification instead of assuming upstream CI coverage. citeturn981608search1

## Artifact contents

The main artifact is an explicit ZIP file:

```text
libnode-android-arm64-v24.19.0.zip
└── package/
    ├── arm64-v8a/
    │   └── libnode.so
    ├── metadata.json
    ├── BUILD_INFO.md
    ├── build.log
    └── configure.log
```

`metadata.json` records the exact Node.js version, source checksum, nodejs-mobile script commit, Android API, NDK version, configure flags, library SHA-256, library size, build timestamp, repository, workflow run and commit.

## Why the old Python 2.7 approach was removed

The old `mobile-master` build flow is from an older Node.js generation and currently fails before producing a modern build. The new pipeline keeps Python 3 only and uses the current Node.js build system together with the mobile project's Android cross-compilation scripts.

## Source references

- Node.js: https://nodejs.org/
- Node.js releases: https://nodejs.org/en/blog/release
- Node.js Android build notes: https://github.com/nodejs/node/blob/main/BUILDING.md
- Node.js Mobile: https://github.com/nodejs-mobile/nodejs-mobile
