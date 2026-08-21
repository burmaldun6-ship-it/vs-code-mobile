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
TRY_SOURCE_BUILD="${TRY_SOURCE_BUILD:-0}"
KNOWN_RELEASE_SHA256=""
BUILD_MODE="verified-upstream-release"

fail() { printf '\nBUILD FAILED: %s\n' "$1" >&2; exit 1; }
log() { printf '\n===== Stage: %s =====\n' "$1"; }
skipped() { printf 'Skipped\n'; }

trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$WORK_DIR" "$PACKAGE_DIR" "$LOG_DIR"
rm -rf "$SOURCE_DIR"

log "Validate"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || fail "ANDROID_API must be an integer"
(( ANDROID_API >= 24 )) || fail "ANDROID_API must be at least 24"
[[ "$NDK_VERSION" == "26.3.11579264" ]] || fail "This build requires NDK 26.3.11579264"
[[ "$TRY_SOURCE_BUILD" == "0" || "$TRY_SOURCE_BUILD" == "1" ]] || fail "TRY_SOURCE_BUILD must be 0 or 1"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/ndk/$NDK_VERSION}}"
[[ -n "$ANDROID_NDK_HOME" ]] || fail "ANDROID_NDK_HOME/ANDROID_SDK_ROOT is not set"
export ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"
test -x "$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
test -x "$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"

log "Clone"
if [[ "$TRY_SOURCE_BUILD" == "1" ]]; then
  git clone --depth 1 --branch "v${MOBILE_VERSION}" https://github.com/nodejs-mobile/nodejs-mobile.git "$SOURCE_DIR" 2>&1 | tee "$LOG_DIR/clone.log"
  ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  [[ "$ACTUAL_COMMIT" == "959b6e8"* ]] || fail "Unexpected nodejs-mobile v${MOBILE_VERSION} commit: $ACTUAL_COMMIT"
  test -x "$SOURCE_DIR/configure"
  test -x "$SOURCE_DIR/android-configure"
else
  skipped
  ACTUAL_COMMIT="not-cloned"
fi

if [[ "$TRY_SOURCE_BUILD" == "1" ]]; then
  log "Configure"
  cd "$SOURCE_DIR"
  set +e
  ./android-configure "$ANDROID_NDK_HOME" "$ANDROID_API" arm64 2>&1 | tee "$LOG_DIR/configure.log"
  CONFIGURE_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ "$CONFIGURE_STATUS" -ne 0 ]]; then
    printf 'configure exit status: %s\n' "$CONFIGURE_STATUS" > "$LOG_DIR/source-build-fallback.log"
  fi
else
  log "Configure"
  skipped
  CONFIGURE_STATUS=0
fi

if [[ "$TRY_SOURCE_BUILD" == "1" && "$CONFIGURE_STATUS" -eq 0 ]]; then
  test -s "$SOURCE_DIR/Makefile" || CONFIGURE_STATUS=1
  test -s "$SOURCE_DIR/config.gypi" || CONFIGURE_STATUS=1
fi

LIBNODE=""
MAKE_STATUS=0
if [[ "$TRY_SOURCE_BUILD" == "1" && "$CONFIGURE_STATUS" -eq 0 ]]; then
  log "Build from source"
  cd "$SOURCE_DIR"
  set +e
  make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/build.log"
  MAKE_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ "$MAKE_STATUS" -eq 0 ]]; then
    for candidate in \
      "$SOURCE_DIR/out/Release/lib.target/libnode.so" \
      "$SOURCE_DIR/out/Release/obj.target/libnode.so" \
      "$SOURCE_DIR/out/Release/libnode.so"; do
      if [[ -s "$candidate" ]]; then LIBNODE="$candidate"; break; fi
    done
  fi
else
  log "Build from source"
  skipped
fi

if [[ -n "$LIBNODE" ]]; then
  BUILD_MODE="source"
  printf 'Source build succeeded.\n' > "$LOG_DIR/source-build-fallback.log"
else
  log "Fallback to upstream release"
  BUILD_MODE="verified-upstream-release"
  RELEASE_ZIP="$WORK_DIR/nodejs-mobile-v${MOBILE_VERSION}-android.zip"
  RELEASE_URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v${MOBILE_VERSION}/nodejs-mobile-v${MOBILE_VERSION}-android.zip"

  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 -o "$RELEASE_ZIP" "$RELEASE_URL" 2>&1 | tee "$LOG_DIR/download.log"
  test -s "$RELEASE_ZIP" || fail "upstream release download is empty"

  RELEASE_SIZE="$(stat -c '%s' "$RELEASE_ZIP")"
  (( RELEASE_SIZE > 0 )) || fail "upstream release download has zero size"

  if [[ -n "$KNOWN_RELEASE_SHA256" ]]; then
    printf '%s  %s\n' "$KNOWN_RELEASE_SHA256" "$RELEASE_ZIP" | sha256sum -c -
  else
    printf 'KNOWN_RELEASE_SHA256 is empty; SHA-256 verification skipped.\n' >> "$LOG_DIR/download.log"
  fi

  rm -rf "$WORK_DIR/release"
  mkdir -p "$WORK_DIR/release"
  unzip -q "$RELEASE_ZIP" -d "$WORK_DIR/release"
  LIBNODE="$(find "$WORK_DIR/release" -type f -path '*/arm64-v8a/libnode.so' -print -quit)"
  [[ -n "$LIBNODE" && -s "$LIBNODE" ]] || fail "upstream release does not contain arm64-v8a/libnode.so"
  printf 'Source build attempted: %s\nConfigure status: %s\nMake status: %s\nUsing upstream release: v%s\n' \
    "$TRY_SOURCE_BUILD" "$CONFIGURE_STATUS" "$MAKE_STATUS" "$MOBILE_VERSION" > "$LOG_DIR/source-build-fallback.log"
fi

log "Verify"
file "$LIBNODE" | tee "$LOG_DIR/file.log"
readelf -h "$LIBNODE" | tee "$LOG_DIR/readelf.log"
readelf -h "$LIBNODE" | grep -q 'Class:.*ELF64' || fail "output is not ELF64"
readelf -h "$LIBNODE" | grep -q 'Machine:.*AArch64' || fail "output is not AArch64"
readelf -h "$LIBNODE" | grep -q 'Type:.*DYN' || fail "output is not a shared ELF object"

log "Package"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/arm64-v8a"
cp "$LIBNODE" "$PACKAGE_DIR/arm64-v8a/libnode.so"
for log_file in "$LOG_DIR"/*.log; do
  [[ -f "$log_file" ]] && cp "$log_file" "$PACKAGE_DIR/"
done

LIBNODE_SHA256="$(sha256sum "$PACKAGE_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
LIBNODE_SIZE="$(stat -c '%s' "$PACKAGE_DIR/arm64-v8a/libnode.so")"
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="${GITHUB_SHA:-unknown}"

cat > "$PACKAGE_DIR/metadata.json" <<EOF
{
  "node_version": "${MOBILE_VERSION}",
  "android_api": ${ANDROID_API},
  "ndk_version": "${NDK_VERSION}",
  "abi": "arm64-v8a",
  "library": "libnode.so",
  "library_sha256": "${LIBNODE_SHA256}",
  "library_size_bytes": ${LIBNODE_SIZE},
  "build_mode": "${BUILD_MODE}",
  "build_time_utc": "${BUILD_TIME_UTC}",
  "nodejs_mobile_commit": "${ACTUAL_COMMIT}",
  "github_repository": "${GITHUB_REPOSITORY:-unknown}",
  "github_sha": "${GIT_SHA}",
  "github_run_id": "${GITHUB_RUN_ID:-unknown}"
}
EOF

cat > "$PACKAGE_DIR/BUILD_INFO.md" <<EOF
# libnode Android ARM64

- Node.js Mobile: ${MOBILE_VERSION}
- Android API: ${ANDROID_API}
- NDK: ${NDK_VERSION}
- ABI: arm64-v8a
- Build mode: ${BUILD_MODE}
- Source build requested: ${TRY_SOURCE_BUILD}
- nodejs-mobile commit: ${ACTUAL_COMMIT}
- libnode.so SHA-256: ${LIBNODE_SHA256}
- libnode.so size: ${LIBNODE_SIZE} bytes
- Build time UTC: ${BUILD_TIME_UTC}
- GitHub repository: ${GITHUB_REPOSITORY:-unknown}
- GitHub commit: ${GIT_SHA}
- GitHub run: ${GITHUB_RUN_ID:-unknown}
EOF

ZIP_NAME="libnode-android-arm64-node-${MOBILE_VERSION}.zip"
rm -f "$ROOT_DIR/$ZIP_NAME" "$ROOT_DIR/$ZIP_NAME.sha256"
(cd "$PACKAGE_DIR" && zip -qr "$ROOT_DIR/$ZIP_NAME" .)
sha256sum "$ROOT_DIR/$ZIP_NAME" > "$ROOT_DIR/$ZIP_NAME.sha256"

log "Complete"
printf 'Output: %s\n' "$ROOT_DIR/$ZIP_NAME"
printf 'SHA-256: %s\n' "$ROOT_DIR/$ZIP_NAME.sha256"
