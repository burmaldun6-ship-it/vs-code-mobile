#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/android-ndk" >&2
  exit 2
fi

NDK_PATH="$(cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/nodejs-mobile"

if [[ ! -x "$NDK_PATH/ndk-build" && ! -d "$NDK_PATH" ]]; then
  echo "NDK path does not exist: $NDK_PATH" >&2
  exit 1
fi

if [[ ! -d "$SRC/tools" ]]; then
  git clone --depth 1 --branch mobile-master https://github.com/nodejs-mobile/nodejs-mobile.git "$SRC"
fi

cd "$SRC"
./tools/android_build.sh "$NDK_PATH" arm64

mkdir -p "$ROOT/out"
cp "$SRC/out_android/arm64-v8a/libnode.so" "$ROOT/out/libnode.so"
echo "Built: $ROOT/out/libnode.so"
