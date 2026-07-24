#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
NDK="$HOME/android/ndk/android-ndk-r26d"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
PREFIX="$HOME/android-ffbuild/out/arm64-v8a-gpl-8.1"
cd "$HOME/android-ffbuild/src/ffmpeg-8.1"
make distclean >/dev/null 2>&1 || true
./configure \
  --prefix="$PREFIX" \
  --target-os=android --arch=aarch64 --cpu=armv8-a \
  --enable-cross-compile \
  --cross-prefix="$TC/bin/llvm-" \
  --cc="$TC/bin/aarch64-linux-android21-clang" \
  --cxx="$TC/bin/aarch64-linux-android21-clang++" \
  --ar="$TC/bin/llvm-ar" --nm="$TC/bin/llvm-nm" \
  --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" \
  --sysroot="$TC/sysroot" \
  --enable-shared --disable-static \
  --disable-doc --disable-programs \
  --enable-gpl --enable-version3
