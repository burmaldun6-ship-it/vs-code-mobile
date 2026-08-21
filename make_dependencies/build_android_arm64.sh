#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/make_dependencies/work"
SOURCE_DIR="$WORK_DIR/node"
PACKAGE_DIR="$ROOT_DIR/make_dependencies/package"
LOG_DIR="$ROOT_DIR/make_dependencies/logs"

ANDROID_API="${ANDROID_API:-24}"
NDK_VERSION="${NDK_VERSION:-26.3.11579264}"
MOBILE_VERSION="18.20.4"
MOBILE_COMMIT="959b6e8"

fail() { printf '\nBUILD FAILED: %s\n' "$1" >&2; exit 1; }
log() { printf '\n===== %s =====\n' "$1"; }
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$WORK_DIR" "$LOG_DIR"
rm -rf "$SOURCE_DIR" "$PACKAGE_DIR"

log "Validate pinned mobile runtime"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || fail "ANDROID_API must be an integer"
(( ANDROID_API >= 24 )) || fail "ANDROID_API must be at least 24"
[[ "$NDK_VERSION" == "26.3.11579264" ]] || fail "This reproducible mobile build requires NDK 26.3.11579264"

log "Fetch Node.js for Mobile ${MOBILE_VERSION}"
git clone --depth 1 --branch "v${MOBILE_VERSION}" https://github.com/nodejs-mobile/nodejs-mobile.git "$SOURCE_DIR" 2>&1 | tee "$LOG_DIR/clone.log"
ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == 959b6e8* ]] || fail "Unexpected nodejs-mobile v${MOBILE_VERSION} commit: $ACTUAL_COMMIT"

log "Validate Android build sources"
test -x "$SOURCE_DIR/configure"
test -x "$SOURCE_DIR/android-configure"
test -s "$SOURCE_DIR/android_configure.py"
test -s "$SOURCE_DIR/android-patches/trap-handler.h.patch"

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
"$CC" --version | head -n 1
"$CXX" --version | head -n 1

log "Apply upstream Android compatibility patch"
cd "$SOURCE_DIR"
./android-configure patch 2>&1 | tee "$LOG_DIR/patch.log"

log "Configure Node.js Mobile for Android ARM64"
export LDFLAGS="${LDFLAGS:--Wl,-z,max-page-size=16384 -llog}"
./android-configure "$ANDROID_NDK_HOME" "$ANDROID_API" arm64 2>&1 | tee "$LOG_DIR/configure.log"

test -s Makefile
test -s config.gypi
printf 'Node mobile version=%s\nNode mobile commit=%s\nAndroid API=%s\nNDK=%s\n' "$MOBILE_VERSION" "$ACTUAL_COMMIT" "$ANDROID_API" "$NDK_VERSION" | tee "$LOG_DIR/config-summary.log"

grep -q 'target_arch=arm64' "$SOURCE_DIR/config.gypi" || fail "configure did not select ARM64"
grep -q 'android' "$SOURCE_DIR/config.gypi" || fail "configure did not select Android"

log "Build libnode.so"
make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/build.log"

log "Locate and verify libnode.so"
LIBNODE=""
for candidate in \
  "$SOURCE_DIR/out/Release/lib.target/libnode.so" \
  "$SOURCE_DIR/out/Release/obj.target/libnode.so" \
  "$SOURCE_DIR/out/Release/libnode.so"; do
  if [[ -s "$candidate" ]]; then LIBNODE="$candidate"; break; fi
done
[[ -n "$LIBNODE" ]] || fail "libnode.so was not produced"
file "$LIBNODE" | tee "$LOG_DIR/file.log"
readelf -h "$LIBNODE" | tee "$LOG_DIR/readelf.log"
readelf -h "$LIBNODE" | grep -q 'Class:.*ELF64' || fail "output is not ELF64"
readelf -h "$LIBNODE" | grep -q 'Machine:.*AArch64' || fail "output is not AArch64"
readelf -h "$LIBNODE" | grep -q 'Type:.*DYN' || fail "output is not a shared ELF object"

log "Create package"
mkdir -p "$PACKAGE_DIR/arm64-v8a"
cp "$LIBNODE" "$PACKAGE_DIR/arm64-v8a/libnode.so"
cp "$LOG_DIR"/*.log "$PACKAGE_DIR/"
LIBNODE_SHA256="$(sha256sum "$PACKAGE_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
LIBNODE_SIZE="$(stat -c '%s' "$PACKAGE_DIR/arm64-v8a/libnode.so")"
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"

python3 - "$PACKAGE_DIR/metadata.json" "$LIBNODE_SHA256" "$LIBNODE_SIZE" "$BUILD_TIME_UTC" "$GIT_SHA" "$ACTUAL_COMMIT" <<'PY'
import json, os, sys
out, lib_sha, size, build_time, repo_sha, mobile_sha = sys.argv[1:]
data = {
  "runtime": "nodejs-mobile",
  "node_version": "18.20.4",
  "nodejs_mobile_commit": mobile_sha,
  "android_api": 24,
  "ndk_version": "26.3.11579264",
  "abi": "arm64-v8a",
  "library": "libnode.so",
  "library_sha256": lib_sha,
  "library_size_bytes": int(size),
  "github_repository": os.environ.get("GITHUB_REPOSITORY", "unknown"),
  "github_sha": repo_sha,
  "github_run_id": os.environ.get("GITHUB_RUN_ID", "unknown"),
  "build_time_utc": build_time,
  "ldflags": os.environ.get("LDFLAGS", ""),
}
with open(out, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, sort_keys=True)
  f.write("\n")
PY

cat > "$PACKAGE_DIR/BUILD_INFO.md" <<EOF
# libnode Android ARM64

- Runtime: nodejs-mobile
- Node.js: ${MOBILE_VERSION}
- nodejs-mobile commit: ${ACTUAL_COMMIT}
- Android API: ${ANDROID_API}
- NDK: ${NDK_VERSION}
- ABI: arm64-v8a
- libnode.so SHA-256: ${LIBNODE_SHA256}
- libnode.so size: ${LIBNODE_SIZE} bytes
- GitHub commit: ${GIT_SHA}
- GitHub run: ${GITHUB_RUN_ID:-unknown}
- Build time UTC: ${BUILD_TIME_UTC}
EOF

ZIP_NAME="libnode-android-arm64-node-${MOBILE_VERSION}.zip"
rm -f "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
(cd "$PACKAGE_DIR" && zip -qr "$ROOT_DIR/$ZIP_NAME" .)
sha256sum "$ROOT_DIR/$ZIP_NAME" > "$ROOT_DIR/$ZIP_NAME.sha256"

log "Build complete"
ls -lh "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
