#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.19.0}"
NDK_VERSION="${NDK_VERSION:-27.0.12077973}"
ANDROID_API="${ANDROID_API:-24}"
WORK_DIR="${WORK_DIR:-work}"
LOG_DIR="$WORK_DIR/logs"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"

mkdir -p "$LOG_DIR"
rm -rf "$WORK_DIR/node-v$NODE_VERSION" "$ARTIFACTS_DIR"
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

validate_regex "NODE_VERSION" "$NODE_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "NDK_VERSION" "$NDK_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "ANDROID_API" "$ANDROID_API" '^[0-9]+$'
if (( ANDROID_API < 24 )); then
  echo "ANDROID_API must be >= 24" >&2
  exit 2
fi
validate_regex "GITHUB_RUN_ID" "${GITHUB_RUN_ID:-0}" '^[0-9]+$'
validate_regex "GITHUB_SHA" "${GITHUB_SHA:-0000000000000000000000000000000000000000}" '^[0-9a-f]{40}$'

if [[ "$NODE_VERSION" != "24.19.0" ]]; then
  echo "This workflow is pinned to upstream Node.js 24.19.0" >&2
  exit 2
fi
if [[ "$NDK_VERSION" != "27.0.12077973" ]]; then
  echo "This workflow is pinned to Android NDK 27.0.12077973" >&2
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

sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential git python3 gcc-multilib g++-multilib file binutils zip unzip xz-utils

ARCH='arm64'
validate_regex "ARCH" "$ARCH" '^arm64$'

SOURCE_FILENAME="node-v$NODE_VERSION.tar.xz"
SOURCE_URL="https://nodejs.org/dist/v$NODE_VERSION/$SOURCE_FILENAME"
SUMS_URL="https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
validate_regex "SOURCE_FILENAME" "$SOURCE_FILENAME" '^node-v[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz$'
validate_regex "SOURCE_URL" "$SOURCE_URL" '^https://nodejs\.org/dist/v[0-9]+\.[0-9]+\.[0-9]+/node-v[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz$'
validate_regex "SUMS_URL" "$SUMS_URL" '^https://nodejs\.org/dist/v[0-9]+\.[0-9]+\.[0-9]+/SHASUMS256\.txt$'
ARCHIVE="$WORK_DIR/$SOURCE_FILENAME"
SUMS="$WORK_DIR/SHASUMS256.txt"

{
  python3 - "$SOURCE_URL" "$ARCHIVE" "$SUMS_URL" "$SUMS" <<'PY'
import pathlib
import re
import sys
import urllib.request

source_url, source_path, sums_url, sums_path = sys.argv[1:5]
patterns = [
    (source_url, r"https://nodejs\.org/dist/v[0-9]+\.[0-9]+\.[0-9]+/node-v[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz"),
    (sums_url, r"https://nodejs\.org/dist/v[0-9]+\.[0-9]+\.[0-9]+/SHASUMS256\.txt"),
]
for value, pattern in patterns:
    if not re.fullmatch(pattern, value):
        raise SystemExit(f"invalid URL: {value}")
urllib.request.urlretrieve(source_url, source_path)
urllib.request.urlretrieve(sums_url, sums_path)
pathlib.Path(source_path).stat()
pathlib.Path(sums_path).stat()
PY
  source_sha256="$(python3 - "$SUMS" "$SOURCE_FILENAME" <<'PY'
import pathlib
import re
import sys

path, filename = sys.argv[1:3]
text = pathlib.Path(path).read_text(encoding="utf-8")
match = re.search(r"^([0-9a-f]{64})\s+\S*" + re.escape(filename) + r"$", text, re.MULTILINE)
if not match:
    raise SystemExit(f"checksum not found for {filename}")
print(match.group(1))
PY
)"
  validate_regex "source_sha256" "$source_sha256" '^[0-9a-f]{64}$'
  echo "$source_sha256  $ARCHIVE" | sha256sum -c -
  rm -rf "$WORK_DIR/node-v$NODE_VERSION"
  tar -xJf "$ARCHIVE" -C "$WORK_DIR"
  test -d "$WORK_DIR/node-v$NODE_VERSION"
} 2>&1 | tee "$LOG_DIR/download.log"

NODE_DIR="$WORK_DIR/node-v$NODE_VERSION"
TOOLCHAIN_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$TOOLCHAIN_BIN:$PATH"
export CC="aarch64-linux-android${ANDROID_API}-clang"
export CXX="aarch64-linux-android${ANDROID_API}-clang++"
export AR="llvm-ar"
export LINK="$CXX"
export STRIP="llvm-strip"
for tool in "$CC" "$CXX" "$AR" "$STRIP"; do
  if [[ "$tool" == */* ]]; then
    test -x "$tool"
  else
    command -v "$tool" >/dev/null
  fi
done

{
  echo "CC=$CC"
  echo "CXX=$CXX"
  echo "AR=$AR"
  echo "LINK=$LINK"
  echo "STRIP=$STRIP"
  cd "$NODE_DIR"
  ./configure \
    --dest-cpu=arm64 \
    --dest-os=android \
    --shared \
    --without-snapshot \
    --cross-compiling-only \
    --with-intl=small-icu \
    --openssl-no-asm
} 2>&1 | tee "$LOG_DIR/configure.log"

{
  cd "$NODE_DIR"
  make -j"$(nproc)"
} 2>&1 | tee "$LOG_DIR/build.log"

LIBNODE=""
for candidate in "$NODE_DIR/out/Release/libnode.so" "$NODE_DIR/out/Release/lib.target/libnode.so"; do
  if [[ -f "$candidate" ]]; then
    LIBNODE="$candidate"
    break
  fi
done
if [[ -z "$LIBNODE" ]]; then
  echo "libnode.so not found in expected output paths" >&2
  exit 1
fi

{
  file "$LIBNODE"
} 2>&1 | tee "$LOG_DIR/file.log"

{
  readelf -h "$LIBNODE"
} 2>&1 | tee "$LOG_DIR/readelf.log"

{
  readelf -h "$LIBNODE" | grep -Eq 'Class:[[:space:]]+ELF64'
  readelf -h "$LIBNODE" | grep -Eq 'Machine:[[:space:]]+.*AArch64'
  readelf -h "$LIBNODE" | grep -Eq 'Type:[[:space:]]+DYN'
  echo "ELF verification passed for arm64-v8a"
} 2>&1 | tee "$LOG_DIR/verify.log"

mkdir -p "$ARTIFACTS_DIR/arm64-v8a"
{
  cp "$LIBNODE" "$ARTIFACTS_DIR/arm64-v8a/libnode.so"
  library_sha256="$(sha256sum "$ARTIFACTS_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
  library_size_bytes="$(stat -c '%s' "$ARTIFACTS_DIR/arm64-v8a/libnode.so")"
  build_time_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  export library_sha256 library_size_bytes build_time_utc
  python3 - "$ARTIFACTS_DIR/metadata.json" <<'PY'
import json
import os
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
data = {
    "source": "https://nodejs.org/dist/v24.19.0/node-v24.19.0.tar.xz",
    "version": os.environ["NODE_VERSION"],
    "android_api": int(os.environ["ANDROID_API"]),
    "ndk_version": os.environ["NDK_VERSION"],
    "abi": "arm64-v8a",
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
  zip_name="libnode-upstream-24-arm64-api${ANDROID_API}.zip"
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
