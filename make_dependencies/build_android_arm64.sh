#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/make_dependencies/work"
SOURCE_DIR="$WORK_DIR/node"
TOOLS_DIR="$WORK_DIR/nodejs-mobile"
PACKAGE_DIR="$ROOT_DIR/make_dependencies/package"
LOG_DIR="$ROOT_DIR/make_dependencies/logs"

ANDROID_API="${ANDROID_API:-24}"
NDK_VERSION="${NDK_VERSION:-27.3.13750724}"
NODE_VERSION_REQUEST="${NODE_VERSION_REQUEST:-lts}"

mkdir -p "$WORK_DIR" "$LOG_DIR"
rm -rf "$SOURCE_DIR" "$TOOLS_DIR" "$PACKAGE_DIR"

log() {
  printf '\n===== %s =====\n' "$1"
}

fail() {
  printf '\nBUILD FAILED: %s\n' "$1" >&2
  exit 1
}

trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

log "Resolve Node.js version"
if [[ "$NODE_VERSION_REQUEST" == "lts" ]]; then
  NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(next(x["version"] for x in json.load(sys.stdin) if x.get("lts")))')"
else
  NODE_VERSION="$NODE_VERSION_REQUEST"
  [[ "$NODE_VERSION" == v* ]] || NODE_VERSION="v$NODE_VERSION"
fi
printf 'Node.js: %s\nAndroid API: %s\nNDK: %s\n' "$NODE_VERSION" "$ANDROID_API" "$NDK_VERSION"

log "Download Node.js source"
mkdir -p "$WORK_DIR/source"
NODE_TARBALL="node-${NODE_VERSION}.tar.xz"
curl -fsSL -o "$WORK_DIR/source/$NODE_TARBALL" "https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"
curl -fsSL -o "$WORK_DIR/source/SHASUMS256.txt" "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
(
  cd "$WORK_DIR/source"
  grep -F "  $NODE_TARBALL" SHASUMS256.txt
  sha256sum --ignore-missing -c SHASUMS256.txt --strict
)
NODE_SOURCE_SHA256="$(sha256sum "$WORK_DIR/source/$NODE_TARBALL" | awk '{print $1}')"

tar -xJf "$WORK_DIR/source/$NODE_TARBALL" -C "$WORK_DIR"
mv "$WORK_DIR/node-${NODE_VERSION#v}" "$SOURCE_DIR"

test -x "$SOURCE_DIR/configure"
test -f "$SOURCE_DIR/Makefile" || true

log "Fetch nodejs-mobile Android configuration"
git clone --depth 1 https://github.com/nodejs-mobile/nodejs-mobile.git "$TOOLS_DIR"
MOBILE_TOOLS_SHA="$(git -C "$TOOLS_DIR" rev-parse HEAD)"
test -x "$TOOLS_DIR/android-configure"
test -s "$TOOLS_DIR/android_configure.py"

log "Validate Android toolchain"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$NDK_VERSION}"
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
test -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang"
test -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang++"
"$ANDROID_NDK_HOME/ndk-build" --version

log "Configure Node.js for Android ARM64"
cd "$SOURCE_DIR"
cp "$TOOLS_DIR/android_configure.py" ./android_configure.py
cp "$TOOLS_DIR/android-configure" ./android-configure
chmod +x ./android-configure
./android-configure "$ANDROID_NDK_HOME" "$ANDROID_API" arm64 2>&1 | tee "$LOG_DIR/configure.log"
test -f Makefile

grep -E '^node_shared|^target_arch|^v8_target_arch' config.gypi || true

log "Build libnode.so"
make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/build.log"

log "Locate and verify libnode.so"
LIBNODE=""
for candidate in \
  "$SOURCE_DIR/out/Release/lib.target/libnode.so" \
  "$SOURCE_DIR/out/Release/libnode.so" \
  "$SOURCE_DIR/out/Release/lib/libnode.so"; do
  if [[ -s "$candidate" ]]; then
    LIBNODE="$candidate"
    break
  fi
done

if [[ -z "$LIBNODE" ]]; then
  find "$SOURCE_DIR/out" -type f -name 'libnode*.so*' -print || true
  fail "libnode.so was not produced"
fi

file "$LIBNODE"
readelf -h "$LIBNODE" | tee "$LOG_DIR/readelf.log"
readelf -h "$LIBNODE" | grep -q 'Machine:.*AArch64' || fail "output is not AArch64"

log "Create package"
mkdir -p "$PACKAGE_DIR/arm64-v8a"
cp "$LIBNODE" "$PACKAGE_DIR/arm64-v8a/libnode.so"
LIBNODE_SHA256="$(sha256sum "$PACKAGE_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
LIBNODE_SIZE="$(stat -c '%s' "$PACKAGE_DIR/arm64-v8a/libnode.so")"
GIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"

python3 - "$PACKAGE_DIR/metadata.json" "$NODE_VERSION" "$NODE_SOURCE_SHA256" "$MOBILE_TOOLS_SHA" "$ANDROID_API" "$NDK_VERSION" "$LIBNODE_SHA256" "$LIBNODE_SIZE" "$GIT_SHA" <<'PY'
import json
import os
import sys
out, node, source_sha, mobile_sha, api, ndk, lib_sha, size, git_sha = sys.argv[1:]
data = {
    "node_version": node,
    "node_source_sha256": source_sha,
    "nodejs_mobile_tools_commit": mobile_sha,
    "android_api": api,
    "ndk_version": ndk,
    "abi": "arm64-v8a",
    "library": "libnode.so",
    "library_sha256": lib_sha,
    "library_size_bytes": int(size),
    "github_sha": git_sha,
    "runner_os": os.environ.get("RUNNER_OS", "unknown"),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY

python3 - "$PACKAGE_DIR/BUILD_INFO.md" "$NODE_VERSION" "$NODE_SOURCE_SHA256" "$MOBILE_TOOLS_SHA" "$ANDROID_API" "$NDK_VERSION" "$LIBNODE_SHA256" "$LIBNODE_SIZE" "$GIT_SHA" <<'PY'
import sys
out, node, source_sha, mobile_sha, api, ndk, lib_sha, size, git_sha = sys.argv[1:]
text = f'''# libnode Android ARM64 build\n\n- Node.js: {node}\n- Android API: {api}\n- Android NDK: {ndk}\n- ABI: arm64-v8a\n- Node source SHA-256: {source_sha}\n- nodejs-mobile tools commit: {mobile_sha}\n- GitHub commit: {git_sha}\n- libnode.so SHA-256: {lib_sha}\n- libnode.so size: {size} bytes\n'''
open(out, 'w', encoding='utf-8').write(text)
PY

cp "$LOG_DIR/configure.log" "$PACKAGE_DIR/configure.log"
cp "$LOG_DIR/build.log" "$PACKAGE_DIR/build.log"
cp "$LOG_DIR/readelf.log" "$PACKAGE_DIR/readelf.log"

ZIP_NAME="libnode-android-arm64-${NODE_VERSION}.zip"
rm -f "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
(
  cd "$PACKAGE_DIR"
  zip -qr "$ROOT_DIR/$ZIP_NAME" .
)
sha256sum "$ROOT_DIR/$ZIP_NAME" > "$ROOT_DIR/$ZIP_NAME.sha256"

log "Build complete"
ls -lh "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
printf 'libnode: %s\n' "$PACKAGE_DIR/arm64-v8a/libnode.so"
printf 'archive: %s\n' "$ROOT_DIR/$ZIP_NAME"
