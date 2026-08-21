#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/make_dependencies/work"
SOURCE_DIR="$WORK_DIR/node"
PACKAGE_DIR="$ROOT_DIR/make_dependencies/package"
LOG_DIR="$ROOT_DIR/make_dependencies/logs"

ANDROID_API="${ANDROID_API:-24}"
NDK_VERSION="${NDK_VERSION:-27.3.13750724}"
NODE_VERSION_REQUEST="${NODE_VERSION_REQUEST:-lts}"

fail() {
  printf '\nBUILD FAILED: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '\n===== %s =====\n' "$1"
}

trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$WORK_DIR/source" "$LOG_DIR"
rm -rf "$SOURCE_DIR" "$PACKAGE_DIR"

log "Validate inputs"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || fail "ANDROID_API must be an integer"
(( ANDROID_API >= 24 )) || fail "ANDROID_API must be at least 24"
[[ "$NDK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "NDK_VERSION must look like 27.3.13750724"
if [[ "$NODE_VERSION_REQUEST" != "lts" && ! "$NODE_VERSION_REQUEST" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "NODE_VERSION_REQUEST must be lts or a full semver such as 24.19.0"
fi

log "Resolve Node.js version"
if [[ "$NODE_VERSION_REQUEST" == "lts" ]]; then
  NODE_VERSION="$(curl --proto '=https' --tlsv1.2 -fsSL https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(next(x["version"] for x in json.load(sys.stdin) if x.get("lts")))')"
else
  NODE_VERSION="$NODE_VERSION_REQUEST"
  [[ "$NODE_VERSION" == v* ]] || NODE_VERSION="v$NODE_VERSION"
fi
[[ "$NODE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Resolved Node version is invalid: $NODE_VERSION"
NODE_MAJOR="${NODE_VERSION#v}"
NODE_MAJOR="${NODE_MAJOR%%.*}"
printf 'Node.js: %s\nAndroid API: %s\nNDK: %s\n' "$NODE_VERSION" "$ANDROID_API" "$NDK_VERSION"

log "Download and verify Node.js source"
NODE_TARBALL="node-${NODE_VERSION}.tar.xz"
NODE_TARBALL_PATH="$WORK_DIR/source/$NODE_TARBALL"
SHASUMS_PATH="$WORK_DIR/source/SHASUMS256.txt"
curl --proto '=https' --tlsv1.2 -fsSL -o "$NODE_TARBALL_PATH" "https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"
curl --proto '=https' --tlsv1.2 -fsSL -o "$SHASUMS_PATH" "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
EXPECTED_SHA256="$(awk -v f="$NODE_TARBALL" '$2 == f {print $1; exit}' "$SHASUMS_PATH")"
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "No valid SHA-256 entry for $NODE_TARBALL"
printf '%s  %s\n' "$EXPECTED_SHA256" "$NODE_TARBALL_PATH" | sha256sum -c -
NODE_SOURCE_SHA256="$(sha256sum "$NODE_TARBALL_PATH" | awk '{print $1}')"

TAR_LIST="$WORK_DIR/source/tar.list"
tar -tf "$NODE_TARBALL_PATH" > "$TAR_LIST"
TOP_LEVEL="$(awk -F/ 'NF {print $1; exit}' "$TAR_LIST")"
[[ "$TOP_LEVEL" =~ ^node-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Unexpected Node source archive root: $TOP_LEVEL"
tar -xJf "$NODE_TARBALL_PATH" -C "$WORK_DIR"
mv "$WORK_DIR/$TOP_LEVEL" "$SOURCE_DIR"
test -x "$SOURCE_DIR/configure"
test -s "$SOURCE_DIR/android_configure.py"
test -x "$SOURCE_DIR/android-configure"

log "Apply Android compatibility patches"
PATCH_DIR="$ROOT_DIR/make_dependencies/patches/node-${NODE_MAJOR}"
PATCH_FILE="$PATCH_DIR/android-stack-trace.patch"
[[ -f "$PATCH_FILE" ]] || fail "No Android compatibility patch set for Node ${NODE_MAJOR}"
git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
git -C "$SOURCE_DIR" apply --verbose "$PATCH_FILE" | tee "$LOG_DIR/patch.log"

grep -q '!V8_OS_ANDROID' "$SOURCE_DIR/deps/v8/src/base/debug/stack_trace_posix.cc" || fail "Android stack-trace compatibility patch was not applied"

log "Validate Android toolchain"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/ndk/$NDK_VERSION}}"
[[ -n "$ANDROID_NDK_HOME" ]] || fail "ANDROID_NDK_HOME/ANDROID_SDK_ROOT is not set"
export ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"
CC="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"
test -x "$CC"
test -x "$CXX"
"$CC" --version
"$CXX" --version
"$ANDROID_NDK_HOME/ndk-build" --version

log "Configure Node.js ${NODE_VERSION} for Android ARM64"
cd "$SOURCE_DIR"
export CC CXX
export GYP_DEFINES="target_arch=arm64 v8_target_arch=arm64 android_target_arch=arm64 host_os=linux OS=android android_ndk_path=$ANDROID_NDK_HOME"
export LDFLAGS="${LDFLAGS:--Wl,-z,max-page-size=16384 -llog}"

./android-configure "$ANDROID_NDK_HOME" "$ANDROID_API" arm64 2>&1 | tee "$LOG_DIR/configure.log"
./configure --dest-cpu=arm64 --dest-os=android --openssl-no-asm --cross-compiling --shared 2>&1 | tee "$LOG_DIR/reconfigure.log"

test -s Makefile
test -s config.gypi
printf 'GYP_DEFINES=%s\nCC=%s\nCXX=%s\n' "$GYP_DEFINES" "$CC" "$CXX" | tee "$LOG_DIR/config-summary.log"

log "Build libnode.so"
make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/build.log"

log "Locate and verify libnode.so"
LIBNODE=""
for candidate in \
  "$SOURCE_DIR/out/Release/lib.target/libnode.so" \
  "$SOURCE_DIR/out/Release/obj.target/libnode.so" \
  "$SOURCE_DIR/out/Release/libnode.so"; do
  if [[ -s "$candidate" ]]; then
    LIBNODE="$candidate"
    break
  fi
done
[[ -n "$LIBNODE" ]] || fail "libnode.so was not produced"
file "$LIBNODE" | tee "$LOG_DIR/file.log"
readelf -h "$LIBNODE" | tee "$LOG_DIR/readelf.log"
readelf -h "$LIBNODE" | grep -q 'Class:.*ELF64' || fail "output is not ELF64"
readelf -h "$LIBNODE" | grep -q 'Machine:.*AArch64' || fail "output is not AArch64"
readelf -h "$LIBNODE" | grep -q 'Type:.*DYN' || fail "output is not a shared ELF object"

log "Create package and metadata"
mkdir -p "$PACKAGE_DIR/arm64-v8a"
cp "$LIBNODE" "$PACKAGE_DIR/arm64-v8a/libnode.so"
cp "$LOG_DIR"/*.log "$PACKAGE_DIR/"
LIBNODE_SHA256="$(sha256sum "$PACKAGE_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
LIBNODE_SIZE="$(stat -c '%s' "$PACKAGE_DIR/arm64-v8a/libnode.so")"
GIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - "$PACKAGE_DIR/metadata.json" "$NODE_VERSION" "$NODE_SOURCE_SHA256" "$ANDROID_API" "$NDK_VERSION" "$LIBNODE_SHA256" "$LIBNODE_SIZE" "$GIT_SHA" "$BUILD_TIME_UTC" <<'PY'
import json
import os
import sys

out, node, source_sha, api, ndk, lib_sha, size, git_sha, build_time = sys.argv[1:]
data = {
    "node_version": node,
    "node_source_sha256": source_sha,
    "android_api": int(api),
    "ndk_version": ndk,
    "abi": "arm64-v8a",
    "library": "libnode.so",
    "library_sha256": lib_sha,
    "library_size_bytes": int(size),
    "github_repository": os.environ.get("GITHUB_REPOSITORY", "unknown"),
    "github_sha": git_sha,
    "github_run_id": os.environ.get("GITHUB_RUN_ID", "unknown"),
    "runner_os": os.environ.get("RUNNER_OS", "unknown"),
    "build_time_utc": build_time,
    "ldflags": os.environ.get("LDFLAGS", ""),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cat > "$PACKAGE_DIR/BUILD_INFO.md" <<EOF
# libnode Android ARM64 build

- Node.js: ${NODE_VERSION}
- Android API: ${ANDROID_API}
- Android NDK: ${NDK_VERSION}
- ABI: arm64-v8a
- Node source SHA-256: ${NODE_SOURCE_SHA256}
- GitHub commit: ${GIT_SHA}
- GitHub run: ${GITHUB_RUN_ID:-unknown}
- libnode.so SHA-256: ${LIBNODE_SHA256}
- libnode.so size: ${LIBNODE_SIZE} bytes
- Build time (UTC): ${BUILD_TIME_UTC}
- LDFLAGS: ${LDFLAGS}
EOF

ZIP_NAME="libnode-android-arm64-${NODE_VERSION}.zip"
rm -f "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
(
  cd "$PACKAGE_DIR"
  zip -qr "$ROOT_DIR/$ZIP_NAME" .
)
sha256sum "$ROOT_DIR/$ZIP_NAME" > "$ROOT_DIR/$ZIP_NAME.sha256"

log "Build complete"
ls -lh "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
printf 'libnode: %s\narchive: %s\n' "$PACKAGE_DIR/arm64-v8a/libnode.so" "$ROOT_DIR/$ZIP_NAME"
