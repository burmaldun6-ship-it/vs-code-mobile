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
  local name="$1" value="$2" regex="$3"
  if [[ ! "$value" =~ $regex ]]; then echo "Invalid $name: $value" >&2; exit 2; fi
}
validate_regex "NODE_VERSION" "$NODE_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "NDK_VERSION" "$NDK_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_regex "ANDROID_API" "$ANDROID_API" '^[0-9]+$'
validate_regex "GITHUB_RUN_ID" "${GITHUB_RUN_ID:-0}" '^[0-9]+$'
validate_regex "GITHUB_SHA" "${GITHUB_SHA:-0000000000000000000000000000000000000000}" '^[0-9a-f]{40}$'

[[ "$NODE_VERSION" == "24.19.0" ]] || { echo "This workflow is pinned to Node.js 24.19.0" >&2; exit 2; }
[[ "$NDK_VERSION" == "27.0.12077973" ]] || { echo "This workflow is pinned to NDK 27.0.12077973" >&2; exit 2; }
(( ANDROID_API >= 24 )) || { echo "ANDROID_API must be >= 24" >&2; exit 2; }

install_ndk() {
  local sdk_root="$WORK_DIR/android-sdk"
  local cmdline_zip="$WORK_DIR/commandlinetools-linux-11076708_latest.zip"
  local cmdline_url='https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip'
  local cmdline_sha='2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258'
  local ndk_home

  if [[ -n "${ANDROID_NDK_HOME:-}" && -f "$ANDROID_NDK_HOME/source.properties" ]]; then
    ndk_home="$ANDROID_NDK_HOME"
  else
    mkdir -p "$sdk_root/cmdline-tools"
    python3 - "$cmdline_url" "$cmdline_zip" <<'PY'
import pathlib, sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
pathlib.Path(sys.argv[2]).stat()
PY
    echo "$cmdline_sha  $cmdline_zip" | sha256sum -c -
    rm -rf "$sdk_root/cmdline-tools/latest"
    unzip -q "$cmdline_zip" -d "$sdk_root/cmdline-tools"
    mv "$sdk_root/cmdline-tools/cmdline-tools" "$sdk_root/cmdline-tools/latest"
    yes | "$sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null || true
    "$sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk_root" "platform-tools" "platforms;android-${ANDROID_API}" "ndk;$NDK_VERSION"
    ndk_home="$sdk_root/ndk/$NDK_VERSION"
  fi

  test -f "$ndk_home/source.properties"
  grep -q "Pkg.Revision = $NDK_VERSION" "$ndk_home/source.properties"
  test -x "$ndk_home/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  export ANDROID_NDK_HOME="$ndk_home"
}

install_ndk

sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential git python3 gcc-multilib g++-multilib file binutils zip unzip xz-utils

SOURCE_FILENAME="node-v$NODE_VERSION.tar.xz"
SOURCE_URL="https://nodejs.org/dist/v$NODE_VERSION/$SOURCE_FILENAME"
SUMS_URL="https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
ARCHIVE="$WORK_DIR/$SOURCE_FILENAME"
SUMS="$WORK_DIR/SHASUMS256.txt"

python3 - "$SOURCE_URL" "$ARCHIVE" "$SUMS_URL" "$SUMS" <<'PY'
import pathlib, sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
urllib.request.urlretrieve(sys.argv[3], sys.argv[4])
pathlib.Path(sys.argv[2]).stat(); pathlib.Path(sys.argv[4]).stat()
PY
source_sha256="$(python3 - "$SUMS" "$SOURCE_FILENAME" <<'PY'
import pathlib, re, sys
text=pathlib.Path(sys.argv[1]).read_text()
m=re.search(r'^([0-9a-f]{64})\s+\S*'+re.escape(sys.argv[2])+r'$',text,re.M)
if not m: raise SystemExit('checksum not found')
print(m.group(1))
PY
)"
echo "$source_sha256  $ARCHIVE" | sha256sum -c -
rm -rf "$WORK_DIR/node-v$NODE_VERSION"
tar -xJf "$ARCHIVE" -C "$WORK_DIR"

NODE_DIR="$WORK_DIR/node-v$NODE_VERSION"
TOOLCHAIN_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$TOOLCHAIN_BIN:$PATH"

# Target toolchain: Android arm64-v8a.
export CC="aarch64-linux-android${ANDROID_API}-clang"
export CXX="aarch64-linux-android${ANDROID_API}-clang++"
export AR="llvm-ar"
export STRIP="llvm-strip"

# Host toolchain: native runner x86_64 Linux. Never use the Android linker for host tools.
export CC_host="/usr/bin/gcc"
export CXX_host="/usr/bin/g++"
export AR_host="/usr/bin/ar"
export AS_host="/usr/bin/as"
export LD_host="/usr/bin/ld"
export NM_host="/usr/bin/nm"
export RANLIB_host="/usr/bin/ranlib"
export STRIP_host="/usr/bin/strip"
export LINK_host="/usr/bin/g++"

# Keep target and host architectures separate. Node's configure uses the host toolset
# when cross-compiling; snapshots must remain enabled so GYP creates obj.host targets.
export GYP_DEFINES="target_arch=arm64 v8_target_arch=arm64 android_target_arch=arm64 host_os=linux OS=android android_ndk_path=$ANDROID_NDK_HOME"
export npm_config_arch=arm64
export npm_config_platform=android

for tool in "$CC" "$CXX" "$AR" "$STRIP" "$CC_host" "$CXX_host" "$AR_host" "$AS_host" "$LD_host" "$NM_host" "$RANLIB_host" "$STRIP_host" "$LINK_host"; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
echo "GYP_DEFINES=$GYP_DEFINES"
echo "CC=$CC"
echo "CXX=$CXX"
echo "CC_host=$CC_host"
echo "CXX_host=$CXX_host"
echo "AR_host=$AR_host"
echo "LD_host=$LD_host"

{
  cd "$NODE_DIR"
  ./configure \
    --dest-cpu=arm64 \
    --dest-os=android \
    --shared \
    --cross-compiling \
    --with-intl=small-icu \
    --openssl-no-asm
} 2>&1 | tee "$LOG_DIR/configure.log"

{
  cd "$NODE_DIR"
  make -j"$(nproc)"
} 2>&1 | tee "$LOG_DIR/build.log"

LIBNODE=""
for candidate in "$NODE_DIR/out/Release/libnode.so" "$NODE_DIR/out/Release/lib.target/libnode.so"; do
  if [[ -f "$candidate" ]]; then LIBNODE="$candidate"; break; fi
done
[[ -n "$LIBNODE" ]] || { echo "libnode.so not found" >&2; exit 1; }

file "$LIBNODE" | tee "$LOG_DIR/file.log"
readelf -h "$LIBNODE" | tee "$LOG_DIR/readelf.log"
readelf -h "$LIBNODE" | grep -Eq 'Class:[[:space:]]+ELF64'
readelf -h "$LIBNODE" | grep -Eq 'Machine:[[:space:]]+.*AArch64'
readelf -h "$LIBNODE" | grep -Eq 'Type:[[:space:]]+DYN'
echo "ELF verification passed for arm64-v8a" | tee "$LOG_DIR/verify.log"

mkdir -p "$ARTIFACTS_DIR/arm64-v8a"
cp "$LIBNODE" "$ARTIFACTS_DIR/arm64-v8a/libnode.so"
library_sha256="$(sha256sum "$ARTIFACTS_DIR/arm64-v8a/libnode.so" | awk '{print $1}')"
library_size_bytes="$(stat -c '%s' "$ARTIFACTS_DIR/arm64-v8a/libnode.so")"
build_time_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export library_sha256 library_size_bytes build_time_utc
python3 - "$ARTIFACTS_DIR/metadata.json" <<'PY'
import json, os, pathlib, sys
p=pathlib.Path(sys.argv[1])
p.write_text(json.dumps({
 "source":"https://nodejs.org/dist/v24.19.0/node-v24.19.0.tar.xz",
 "version":os.environ["NODE_VERSION"],"android_api":int(os.environ["ANDROID_API"]),
 "ndk_version":os.environ["NDK_VERSION"],"abi":"arm64-v8a",
 "library_sha256":os.environ["library_sha256"],"library_size_bytes":int(os.environ["library_size_bytes"]),
 "build_time_utc":os.environ["build_time_utc"],"github_run_id":os.environ["GITHUB_RUN_ID"],"github_sha":os.environ["GITHUB_SHA"]
},indent=2)+"\n")
PY
zip_name="libnode-upstream-24-arm64-api${ANDROID_API}.zip"
(cd "$ARTIFACTS_DIR" && zip -qr "../$zip_name" .)
sha256sum "$zip_name" > "$zip_name.sha256"
test -s "$zip_name" && test -s "$zip_name.sha256"
echo "Created $zip_name"
cat "$zip_name.sha256"
