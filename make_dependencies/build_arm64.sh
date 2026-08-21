#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${1:-24.19.0}"
ANDROID_API="${ANDROID_API:-24}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"

if [[ -z "$ANDROID_NDK_ROOT" ]]; then
  echo "Set ANDROID_NDK_ROOT (or ANDROID_NDK_HOME) to an installed Android NDK." >&2
  echo "Example: ANDROID_NDK_ROOT=$HOME/android-sdk/ndk/27.3.13750724 $0 24.19.0" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/node-${NODE_VERSION}"

mkdir -p "$ROOT/source" "$ROOT/out"

if [[ ! -d "$SRC" ]]; then
  TARBALL="$ROOT/source/node-v${NODE_VERSION}.tar.xz"
  SUMS="$ROOT/source/SHASUMS256.txt"
  curl -fsSL -o "$TARBALL" "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.xz"
  curl -fsSL -o "$SUMS" "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
  (cd "$ROOT/source" && sha256sum --ignore-missing -c SHASUMS256.txt --strict)
  mkdir -p "$SRC"
  tar -xJf "$TARBALL" --strip-components=1 -C "$SRC"
fi

# Reuse the Android configuration logic from nodejs-mobile.
if [[ ! -s "$ROOT/android-configure" || ! -s "$ROOT/android_configure.py" ]]; then
  rm -rf "$ROOT/nodejs-mobile-tools"
  git clone --depth 1 https://github.com/nodejs-mobile/nodejs-mobile.git "$ROOT/nodejs-mobile-tools"
  cp "$ROOT/nodejs-mobile-tools/android-configure" "$ROOT/android-configure"
  cp "$ROOT/nodejs-mobile-tools/android_configure.py" "$ROOT/android_configure.py"
  chmod +x "$ROOT/android-configure"
fi

cp "$ROOT/android-configure" "$SRC/android-configure"
cp "$ROOT/android_configure.py" "$SRC/android_configure.py"
chmod +x "$SRC/android-configure"
sed -i 's/--with-intl=none/--with-intl=small-icu/' "$SRC/android_configure.py"

cd "$SRC"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT"
./android-configure "$ANDROID_NDK_ROOT" "$ANDROID_API" arm64
make -j"$(nproc)"

test -s out/Release/lib.target/libnode.so
cp out/Release/lib.target/libnode.so "$ROOT/out/libnode.so"
file "$ROOT/out/libnode.so"
readelf -h "$ROOT/out/libnode.so" | grep -E 'Class|Machine|Type'
echo "Built: $ROOT/out/libnode.so"
