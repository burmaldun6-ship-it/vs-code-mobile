#!/usr/bin/env bash
set -euo pipefail

NODEJS_MOBILE_VERSION="${NODEJS_MOBILE_VERSION:-18.20.4}"
NDK_VERSION="${NDK_VERSION:-24.0.8215888}"
ANDROID_API="${ANDROID_API:-24}"
ARCH="${ARCH:-arm64}"
WORK_DIR="${WORK_DIR:-work}"
LOG_DIR="$WORK_DIR/logs"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"

mkdir -p "$LOG_DIR"
rm -rf "$WORK_DIR/nodejs-mobile" "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

validate_regex() {
  local name="$1"
  local value="$2"
  local regex="$3"
  if [[ ! "$value" =~ $regex ]]; then
    echo "Invalid $name: $value" >&2
    exit 2
  fi
}

validate_regex "NODEJS_MOBILE_VERSION" "$NODEJS_MOBILE_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "NDK_VERSION" "$NDK_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "ANDROID_API" "$ANDROID_API" '^[0-9]+$'
if (( ANDROID_API < 24 )); then
  echo "ANDROID_API must be >= 24" >&2
  exit 2
fi
validate_regex "ARCH" "$ARCH" '^(arm64|arm|x86|x86_64)$'
validate_regex "GITHUB_RUN_ID" "${GITHUB_RUN_ID:-0}" '^[0-9]+$'
validate_regex "GITHUB_SHA" "${GITHUB_SHA:-0000000000000000000000000000000000000000}" '^[0-9a-f]{40}$'

if [[ "$NODEJS_MOBILE_VERSION" != "18.20.4" ]]; then
  echo "This workflow is pinned to nodejs-mobile 18.20.4" >&2
  exit 2
fi
if [[ "$NDK_VERSION" != "24.0.8215888" ]]; then
  echo "This workflow is pinned to Android NDK 24.0.8215888" >&2
  exit 2
fi

install_ndk() {
  local sdk_root cmdline_zip cmdline_url cmdline_sha ndk_home actual_rev
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    validate_regex "ANDROID_NDK_HOME" "$ANDROID_NDK_HOME" '^/[A-Za-z0-9._/@:+-]+$'
    ndk_home="$ANDROID_NDK_HOME"
    if [[ ! -f "$ndk_home/source.properties" ]]; then
      echo "ANDROID_NDK_HOME does not contain source.properties" >&2
      return 1
    fi
  else
    sdk_root="$WORK_DIR/android-sdk"
    cmdline_zip="$WORK_DIR/commandlinetools-linux-11076708_latest.zip"
    cmdline_url='https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip'
    cmdline_sha='2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258'
    validate_regex "cmdline_url" "$cmdline_url" '^https://dl\.google\.com/android/repository/commandlinetools-linux-[0-9]+_latest\.zip$'
    validate_regex "cmdline_sha" "$cmdline_sha" '^[0-9a-f]{64}$'

    {
      echo "Downloading Android command-line tools"
      python3 - "$cmdline_url" "$cmdline_zip" <<'PY'
import pathlib
import re
import sys
import urllib.request

url, destination = sys.argv[1:3]
if not re.fullmatch(r"https://dl\.google\.com/android/repository/commandlinetools-linux-[0-9]+_latest\.zip", url):
    raise SystemExit("invalid command-line tools URL")
urllib.request.urlretrieve(url, destination)
pathlib.Path(destination).stat()
PY
      echo "$cmdline_sha  $cmdline_zip" | sha256sum -c -
      mkdir -p "$sdk_root/cmdline-tools"
      rm -rf "$sdk_root/cmdline-tools/latest"
      unzip -q "$cmdline_zip" -d "$sdk_root/cmdline-tools"
      mv "$sdk_root/cmdline-tools/cmdline-tools" "$sdk_root/cmdline-tools/latest"
      yes | "$sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk_root" "ndk;$NDK_VERSION"
    } 2>&1 | tee "$LOG_DIR/ndk.log"

    ndk_home="$sdk_root/ndk/$NDK_VERSION"
  fi

  if [[ ! -x "$ndk_home/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]]; then
    echo "NDK clang toolchain not found under $ndk_home" >&2
    return 1
  fi
  actual_rev="$(sed -nE 's/^Pkg\.Revision = ([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' "$ndk_home/source.properties")"
  validate_regex "NDK detected revision" "$actual_rev" '^[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ "$actual_rev" != "$NDK_VERSION" ]]; then
    echo "Expected NDK $NDK_VERSION, found $actual_rev" >&2
    return 1
  fi
  export ANDROID_NDK_HOME="$ndk_home"
}

install_ndk

NODE_URL="https://github.com/nodejs-mobile/nodejs-mobile.git"
validate_regex "NODE_URL" "$NODE_URL" '^https://github\.com/nodejs-mobile/nodejs-mobile\.git$'
NODE_DIR="$WORK_DIR/nodejs-mobile"

{
  git clone --branch "v$NODEJS_MOBILE_VERSION" --depth 1 -- "$NODE_URL" "$NODE_DIR"
  git -C "$NODE_DIR" rev-parse --verify HEAD
} 2>&1 | tee "$LOG_DIR/clone.log"

if [[ ! -d "$NODE_DIR" ]]; then
  echo "Clone directory missing: $NODE_DIR" >&2
  exit 1
fi
if [[ ! -x "$NODE_DIR/tools/android_build.sh" ]]; then
  echo "Expected build script missing: $NODE_DIR/tools/android_build.sh" >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential git python3 gcc-multilib g++-multilib file binutils zip unzip

{
  export PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
  "$NODE_DIR/tools/android_build.sh" "$ANDROID_NDK_HOME" "$ANDROID_API" "$ARCH"
} 2>&1 | tee "$LOG_DIR/build.log"

LIBNODE=""
for candidate_root in "$NODE_DIR/out_android/$ARCH" "$NODE_DIR/out/Release"; do
  if [[ -d "$candidate_root" ]]; then
    LIBNODE="$(find "$candidate_root" -type f -name 'libnode.so' -print -quit)"
    if [[ -n "$LIBNODE" ]]; then
      break
    fi
  fi
done

if [[ -z "$LIBNODE" || ! -f "$LIBNODE" ]]; then
  echo "libnode.so not found in expected output directories" >&2
  exit 1
fi

{
  file "$LIBNODE"
} 2>&1 | tee "$LOG_DIR/file.log"

{
  readelf -h "$LIBNODE"
} 2>&1 | tee "$LOG_DIR/readelf.log"

case "$ARCH" in
  arm64) EXPECTED_CLASS='ELF64'; EXPECTED_MACHINE='AArch64'; ABI='arm64-v8a' ;;
  arm) EXPECTED_CLASS='ELF32'; EXPECTED_MACHINE='ARM'; ABI='armeabi-v7a' ;;
  x86) EXPECTED_CLASS='ELF32'; EXPECTED_MACHINE='Intel 80386'; ABI='x86' ;;
  x86_64) EXPECTED_CLASS='ELF64'; EXPECTED_MACHINE='X86-64'; ABI='x86_64' ;;
esac

{
  readelf -h "$LIBNODE" | grep -Eq "Class:[[:space:]]+$EXPECTED_CLASS"
  readelf -h "$LIBNODE" | grep -Eq "Machine:[[:space:]]+.*$EXPECTED_MACHINE"
  readelf -h "$LIBNODE" | grep -Eq 'Type:[[:space:]]+DYN'
  echo "ELF verification passed for $ARCH ($ABI)"
} 2>&1 | tee "$LOG_DIR/verify.log"

mkdir -p "$ARTIFACTS_DIR/$ARCH"
{
  cp "$LIBNODE" "$ARTIFACTS_DIR/$ARCH/libnode.so"
  library_sha256="$(sha256sum "$ARTIFACTS_DIR/$ARCH/libnode.so" | awk '{print $1}')"
  library_size_bytes="$(stat -c '%s' "$ARTIFACTS_DIR/$ARCH/libnode.so")"
  build_time_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  export library_sha256 library_size_bytes build_time_utc ABI
  python3 - "$ARTIFACTS_DIR/metadata.json" <<'PY'
import json
import os
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
data = {
    "source": "https://github.com/nodejs-mobile/nodejs-mobile",
    "version": os.environ["NODEJS_MOBILE_VERSION"],
    "android_api": int(os.environ["ANDROID_API"]),
    "ndk_version": os.environ["NDK_VERSION"],
    "abi": os.environ["ABI"],
    "library_sha256": os.environ["library_sha256"],
    "library_size_bytes": int(os.environ["library_size_bytes"]),
    "build_time_utc": os.environ["build_time_utc"],
    "github_run_id": os.environ["GITHUB_RUN_ID"],
    "github_sha": os.environ["GITHUB_SHA"],
}
if not re.fullmatch(r"[0-9a-f]{64}", data["library_sha256"]):
    raise SystemExit("invalid library_sha256")
if not re.fullmatch(r"[0-9a-f]{40}", data["github_sha"]):
    raise SystemExit("invalid github_sha")
out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  zip_name="libnode-mobile-18-${ARCH}-api${ANDROID_API}.zip"
  (
    cd "$ARTIFACTS_DIR"
    zip -qr "../$zip_name" .
  )
  sha256sum "$zip_name" > "$zip_name.sha256"
  test -s "$zip_name"
  test -s "$zip_name.sha256"
  echo "Created $zip_name"
  echo "SHA-256:"
  cat "$zip_name.sha256"
} 2>&1 | tee "$LOG_DIR/package.log"
