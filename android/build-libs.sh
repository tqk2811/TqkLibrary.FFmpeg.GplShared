#!/usr/bin/env bash
###############################################################################
# build-libs.sh
#
# Cross-build FFmpeg external libraries (static .a + headers + pkgconfig) with
# the Android NDK for TWO ABIs (arm64-v8a, x86_64), then rebuild FFmpeg 8.1
# (GPL-v3 shared) linking whichever libs succeeded.
#
# Design goals:
#   * Reusable & resumable  -> re-running skips libs already installed (checks
#     for the target static .a in the per-ABI prefix).
#   * Unattended-safe       -> SKIP-AND-CONTINUE: a failing lib is recorded and
#     the driver moves on; it never aborts the whole run.
#   * RAM-safe              -> caps every build at -j4 and waits (ram_guard)
#     whenever `free -g` available RAM drops below 4 GiB, so it coexists with
#     the desktop build running in tmux `ffbuild`.
#
# Per-ABI install prefix: ~/android-ffbuild/deps/<ABI>/
# FFmpeg install:         ~/android-ffbuild/out/<ABI>-gpl-8.1-full/
# Artifacts:              ~/android-ffbuild/artifacts/ffmpeg-8.1-android-<ABI>-gpl-shared-full.tar.xz
#
# Usage:
#   ./build-libs.sh            # build all libs (both ABIs) then FFmpeg
#   ./build-libs.sh libs       # build only the external libs
#   ./build-libs.sh ffmpeg     # build only FFmpeg (assumes libs present)
###############################################################################
set -u
umask 022

# ---------------------------------------------------------------------------
# Global paths / toolchain
# ---------------------------------------------------------------------------
ROOT="$HOME/android-ffbuild"
NDK="$HOME/android/ndk/android-ndk-r26d"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API=21
LOCALBIN="$HOME/.local/bin"

SRCROOT="$ROOT/src-libs"          # external-lib source checkouts
DEPSROOT="$ROOT/deps"             # per-ABI install prefixes live under here
LOGDIR="$ROOT/logs"               # one log per lib per ABI
STATEDIR="$ROOT/state"            # (reserved) build markers
STATUS="$ROOT/deps/BUILD_STATUS.txt"
FF_SRC_BASE="$ROOT/src/ffmpeg-8.1-x86_64"   # pristine FFmpeg 8.1 git checkout
JOBS=4
# ABIS overridable via env ANDROID_ABIS (space-separated) for targeted test runs.
IFS=' ' read -r -a ABIS <<< "${ANDROID_ABIS:-arm64-v8a x86_64}"
# DEADLINE_EPOCH (epoch secs): stop starting NEW combos once past it (0=off).
DEADLINE_EPOCH="${DEADLINE_EPOCH:-0}"
past_deadline(){ [ "$DEADLINE_EPOCH" = "0" ] && return 1; [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; }

# Fresh, up-to-date config.sub / config.guess for old autotools tarballs
SYS_CONFIG_SUB="/usr/share/automake-1.16/config.sub"
SYS_CONFIG_GUESS="/usr/share/automake-1.16/config.guess"

# Release tarballs (stable, long-lived versions) for the easy autotools libs
OGG_VER=1.3.5;   OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.xz"
VORBIS_VER=1.3.7; VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.xz"
OPUS_VER=1.5.2;  OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz"
LAME_VER=3.100;  LAME_URL="https://downloads.sourceforge.net/project/lame/lame/3.100/lame-${LAME_VER}.tar.gz"
# --- Batch 2 tarballs ---
THEORA_VER=1.1.1;  THEORA_URL="https://downloads.xiph.org/releases/theora/libtheora-${THEORA_VER}.tar.gz"
TWOLAME_VER=0.4.0; TWOLAME_URL="https://github.com/njh/twolame/releases/download/${TWOLAME_VER}/twolame-${TWOLAME_VER}.tar.gz"
XML2_VER=2.13.5;   XML2_URL="https://download.gnome.org/sources/libxml2/2.13/libxml2-${XML2_VER}.tar.xz"
FREETYPE_VER=2.13.3; FREETYPE_URL="https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VER}/freetype-${FREETYPE_VER}.tar.xz"
LIBASS_VER=0.17.3; LIBASS_URL="https://github.com/libass/libass/releases/download/${LIBASS_VER}/libass-${LIBASS_VER}.tar.gz"

export PATH="$LOCALBIN:$TC/bin:$PATH"

mkdir -p "$SRCROOT" "$DEPSROOT" "$LOGDIR" "$STATEDIR" "$ROOT/artifacts" "$ROOT/out"

# lib -> installed static archive (used for skip / "have" checks)
declare -A LIBFILE=(
  [ogg]=libogg.a [vorbis]=libvorbis.a [opus]=libopus.a [lame]=libmp3lame.a
  [x264]=libx264.a [x265]=libx265.a [aom]=libaom.a [dav1d]=libdav1d.a [vpx]=libvpx.a
  # --- Batch 2 easy tier ---
  [webp]=libwebp.a [theora]=libtheoraenc.a [soxr]=libsoxr.a [zimg]=libzimg.a
  [twolame]=libtwolame.a [openjpeg]=libopenjp2.a [openh264]=libopenh264.a
  [xml2]=libxml2.a [svtav1]=libSvtAv1Enc.a
  # --- Batch 2 libass font chain ---
  [fribidi]=libfribidi.a [freetype]=libfreetype.a [harfbuzz]=libharfbuzz.a [ass]=libass.a )
# lib -> FFmpeg --enable flag (ogg is implicit, no flag)
declare -A FFFLAG=(
  [vorbis]=--enable-libvorbis [opus]=--enable-libopus [lame]=--enable-libmp3lame
  [x264]=--enable-libx264 [x265]=--enable-libx265 [aom]=--enable-libaom
  [dav1d]=--enable-libdav1d [vpx]=--enable-libvpx
  [webp]=--enable-libwebp [theora]=--enable-libtheora [soxr]=--enable-libsoxr
  [zimg]=--enable-libzimg [twolame]=--enable-libtwolame [openjpeg]=--enable-libopenjpeg
  [openh264]=--enable-libopenh264 [xml2]=--enable-libxml2 [svtav1]=--enable-libsvtav1
  [fribidi]=--enable-libfribidi [freetype]=--enable-libfreetype
  [harfbuzz]=--enable-libharfbuzz [ass]=--enable-libass )

# Generic (skip-friendly) order: Batch 1 + Batch 2 easy tier.
LIBS_ORDER=(ogg vorbis opus lame x264 x265 aom dav1d vpx \
            webp theora soxr zimg twolame openjpeg openh264 xml2 svtav1)
# libass font chain is dependency-ordered (2-pass freetype) -> handled separately.
FONT_LIBS=(fribidi freetype harfbuzz ass)
# Everything, for assembling FFmpeg --enable flags.
ALL_LIBS=("${LIBS_ORDER[@]}" "${FONT_LIBS[@]}")

# Reverse map: --enable-libX flag -> our lib key (built from FFFLAG).
declare -A FLAG2LIB
for _k in "${!FFFLAG[@]}"; do FLAG2LIB[${FFFLAG[$_k]}]="$_k"; done; unset _k

# lib key -> substrings that may appear in an FFmpeg "ERROR:" line naming it
# (pkg-config module name and/or the flag). Used to degrade gracefully when an
# older FFmpeg rejects one of our newer libs.
declare -A LIBTOKENS=(
  [x264]="x264 libx264" [x265]="x265 libx265"
  [aom]="libaom aom" [dav1d]="dav1d libdav1d" [vpx]="libvpx vpx"
  [opus]="libopus opus" [vorbis]="libvorbis vorbis" [lame]="mp3lame libmp3lame"
  [webp]="libwebp webp" [theora]="theora libtheora"
  [soxr]="soxr libsoxr" [zimg]="zimg libzimg" [twolame]="twolame libtwolame"
  [openjpeg]="libopenjp2 openjpeg libopenjpeg" [openh264]="openh264 libopenh264"
  [xml2]="libxml-2.0 libxml2 xml2" [svtav1]="SvtAv1Enc svtav1 libsvtav1"
  [fribidi]="fribidi libfribidi" [freetype]="freetype2 freetype libfreetype"
  [harfbuzz]="harfbuzz libharfbuzz" [ass]="libass ass" )

# FFmpeg wrapper source-file stem -> lib key. Used to degrade when configure
# passes but `make` fails compiling a lib wrapper (newer lib API vs old FFmpeg).
declare -A SRCFILE2LIB=(
  [libsvtav1]=svtav1 [libaomenc]=aom [libaomdec]=aom [libdav1d]=dav1d
  [libx264]=x264 [libx265]=x265 [libvpxenc]=vpx [libvpxdec]=vpx
  [libopenh264enc]=openh264 [libopenh264dec]=openh264
  [libtheoraenc]=theora [libwebpenc]=webp [libtwolame]=twolame
  [libopenjpegenc]=openjpeg [libopenjpegdec]=openjpeg
  [libvorbisenc]=vorbis [libvorbisdec]=vorbis [libopusenc]=opus [libopusdec]=opus
  [libmp3lame]=lame [vf_zscale]=zimg [af_aresample]=soxr [vf_subtitles]=ass
  [vf_drawtext]=freetype )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log(){ echo "[$(date +%H:%M:%S)] $*"; }

record(){ # lib abi status note
  printf '%-8s | %-10s | %-4s | %s\n' "$1" "$2" "$3" "$4" >> "$STATUS"
}

# Wait until >=4 GiB RAM is available so we don't starve the desktop build.
ram_guard(){
  local need=4 waited=0 avail
  while :; do
    avail=$(free -g | awk '/^Mem:/{print $7}')
    [ "${avail:-0}" -ge "$need" ] && break
    if [ "$waited" -ge 1800 ]; then
      log "ram_guard: waited 30m, proceeding anyway (avail=${avail}Gi)"; break
    fi
    log "ram_guard: avail=${avail}Gi < ${need}Gi -> sleep 30s"; sleep 30; waited=$((waited+30))
  done
}

# Establish all per-ABI toolchain variables + install prefix.
setup_abi(){
  ABI="$1"
  case "$ABI" in
    arm64-v8a)
      TRIPLE=aarch64-linux-android; CPU_FAMILY=aarch64; MESON_CPU=aarch64
      FF_ARCH=aarch64; FF_CPU=armv8-a; VPXTGT=arm64-android-gcc ;;
    x86_64)
      TRIPLE=x86_64-linux-android;  CPU_FAMILY=x86_64;  MESON_CPU=x86_64
      FF_ARCH=x86_64;  FF_CPU="";    VPXTGT=x86_64-android-gcc ;;
    *) echo "unknown ABI $ABI" >&2; return 1 ;;
  esac
  export CC="$TC/bin/${TRIPLE}${API}-clang"
  export CXX="$TC/bin/${TRIPLE}${API}-clang++"
  export AR="$TC/bin/llvm-ar"
  export RANLIB="$TC/bin/llvm-ranlib"
  export STRIP="$TC/bin/llvm-strip"
  export NM="$TC/bin/llvm-nm"
  export LD="$TC/bin/ld"
  # NOTE: do NOT export AS globally. x264 auto-selects nasm on x86_64 and clang
  # on arm64; a global AS=clang breaks x264's x86 nasm-version check. ffmpeg,
  # libvpx and dav1d each set their assembler explicitly where needed.
  unset AS
  export SYSROOT="$TC/sysroot"
  export PREFIX="$DEPSROOT/$ABI"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
}

# Already installed for the current ABI?
skip_if_built(){ # lib
  local f="$PREFIX/lib/${LIBFILE[$1]}"
  if [ -f "$f" ]; then log "$1/$ABI already built ($f) -> skip"; return 0; fi
  return 1
}
have(){ [ -f "$PREFIX/lib/${LIBFILE[$1]}" ]; }  # for FFmpeg enable-flag decisions

fetch_git(){ # url dir  (shallow default branch)
  local url="$1" dir="$2"
  [ -d "$SRCROOT/$dir/.git" ] && return 0
  log "clone $url"
  git clone --depth 1 "$url" "$SRCROOT/$dir"
}
fetch_tar(){ # url topdir  -> extracts into $SRCROOT/<topdir>
  local url="$1" top="$2" f
  [ -d "$SRCROOT/$top" ] && return 0
  f="$SRCROOT/$(basename "$url")"
  log "download $url"
  curl -fSL --retry 3 --max-time 300 -o "$f" "$url"
  ( cd "$SRCROOT" && tar xf "$f" )
}
refresh_config_scripts(){ # dir
  [ -f "$SYS_CONFIG_SUB" ]   && cp -f "$SYS_CONFIG_SUB"   "$1/config.sub"   2>/dev/null || true
  [ -f "$SYS_CONFIG_GUESS" ] && cp -f "$SYS_CONFIG_GUESS" "$1/config.guess" 2>/dev/null || true
}

# Run a linear list of commands under `set -e` in a subshell so any failure is
# reported without aborting the driver.
steps(){ ( set -e; eval "$1" ); }

fetch_git_recursive(){ # url dir   (shallow + shallow submodules, e.g. zimg/graphengine)
  local url="$1" dir="$2"
  [ -d "$SRCROOT/$dir/.git" ] && return 0
  log "clone (recursive) $url"
  git clone --depth 1 --recurse-submodules --shallow-submodules "$url" "$SRCROOT/$dir"
}

# Write a Meson cross file for the current ABI and echo its path.
gen_cross(){
  local cross="$SRCROOT/cross-$ABI.txt"
  cat > "$cross" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
nasm = '$LOCALBIN/nasm'
[host_machine]
system = 'android'
cpu_family = '$CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
EOF
  echo "$cross"
}

# Generic build back-ends (return non-zero on any failure via `steps`).
cmake_build(){ # srcdir builddir [extra -D args...]
  local s="$1" b="$2"; shift 2; local extra="$*"; rm -rf "$b"
  steps "cmake -S '$s' -B '$b' \
      -DCMAKE_TOOLCHAIN_FILE='$NDK/build/cmake/android.toolchain.cmake' \
      -DANDROID_ABI='$ABI' -DANDROID_PLATFORM=android-$API \
      -DCMAKE_INSTALL_PREFIX='$PREFIX' -DBUILD_SHARED_LIBS=OFF $extra \
   && cmake --build '$b' -j$JOBS && cmake --install '$b'"
}
meson_build(){ # srcdir builddir [extra meson args...]
  local s="$1" b="$2"; shift 2; local extra="$*"; local cross; cross=$(gen_cross); rm -rf "$b"
  steps "meson setup '$b' '$s' --cross-file '$cross' --default-library=static \
      --prefix='$PREFIX' --buildtype release $extra \
   && ninja -C '$b' install"
}
autotools_build(){ # srcdir [extra ./configure args...]   (VPATH build)
  local s="$1"; shift; local extra="$*"; refresh_config_scripts "$s"
  local b="$s/build-$ABI"; rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' CXX='$CXX' AR='$AR' RANLIB='$RANLIB' STRIP='$STRIP' '$s/configure' \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --disable-shared --enable-static --with-pic --disable-dependency-tracking $extra \
   && make -j$JOBS && make install"
}

# Build one lib for the CURRENT ABI (setup_abi already called), record + log.
stage(){ # lib
  local lib="$1"
  ram_guard
  log ">>> build $lib / $ABI"
  if build_"$lib" >"$LOGDIR/$lib-$ABI.log" 2>&1; then
    record "$lib" "$ABI" OK "${VPX_FELLBACK:+generic-gnu(no-simd)}"; log "OK  $lib / $ABI"
  else
    record "$lib" "$ABI" FAIL "$(tail -n 4 "$LOGDIR/$lib-$ABI.log" | tr '\n' ' ' | tail -c 160)"
    log "FAIL $lib / $ABI (see $LOGDIR/$lib-$ABI.log)"
  fi
  unset VPX_FELLBACK
}

# ---------------------------------------------------------------------------
# Autotools libs (VPATH build so one source tree serves both ABIs)
# ---------------------------------------------------------------------------
build_ogg(){
  skip_if_built ogg && return 0
  fetch_tar "$OGG_URL" "libogg-$OGG_VER" || return 1
  local s="$SRCROOT/libogg-$OGG_VER"; refresh_config_scripts "$s"
  local b="$s/build-$ABI"; rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' AR='$AR' RANLIB='$RANLIB' '$s/configure' \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --disable-shared --enable-static --with-pic --disable-dependency-tracking \
   && make -j$JOBS && make install"
}
build_vorbis(){
  skip_if_built vorbis && return 0
  fetch_tar "$VORBIS_URL" "libvorbis-$VORBIS_VER" || return 1
  local s="$SRCROOT/libvorbis-$VORBIS_VER"; refresh_config_scripts "$s"
  local b="$s/build-$ABI"; rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' AR='$AR' RANLIB='$RANLIB' '$s/configure' \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --with-ogg='$PREFIX' --with-ogg-includes='$PREFIX/include' --with-ogg-libraries='$PREFIX/lib' \
      --disable-shared --enable-static --with-pic --disable-dependency-tracking \
   && make -j$JOBS && make install"
}
build_opus(){
  skip_if_built opus && return 0
  fetch_tar "$OPUS_URL" "opus-$OPUS_VER" || return 1
  local s="$SRCROOT/opus-$OPUS_VER"; refresh_config_scripts "$s"
  local b="$s/build-$ABI"; rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' AR='$AR' RANLIB='$RANLIB' '$s/configure' \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --disable-shared --enable-static --with-pic --disable-dependency-tracking \
      --disable-doc --disable-extra-programs \
   && make -j$JOBS && make install"
}
build_lame(){
  skip_if_built lame && return 0
  fetch_tar "$LAME_URL" "lame-$LAME_VER" || return 1
  local s="$SRCROOT/lame-$LAME_VER"; refresh_config_scripts "$s"
  local b="$s/build-$ABI"; rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' AR='$AR' RANLIB='$RANLIB' '$s/configure' \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --disable-shared --enable-static --with-pic --disable-dependency-tracking \
      --disable-frontend \
   && make -j$JOBS && make install"
}

# ---------------------------------------------------------------------------
# x264 (in-tree; distclean between ABIs)
# ---------------------------------------------------------------------------
build_x264(){
  skip_if_built x264 && return 0
  fetch_git "https://code.videolan.org/videolan/x264.git" x264 || return 1
  local s="$SRCROOT/x264"
  ( cd "$s" && make distclean >/dev/null 2>&1 || true )
  steps "cd '$s' && CC='$CC' ./configure --host=$TRIPLE \
      --cross-prefix='$TC/bin/llvm-' --sysroot='$SYSROOT' --prefix='$PREFIX' \
      --enable-static --enable-pic --disable-cli --disable-opencl \
   && make -j$JOBS && make install"
}

# ---------------------------------------------------------------------------
# x265 (cmake; retry with assembly disabled on failure)
#
# NOTE: x265's CMake only generates/installs x265.pc when it can derive a
# version tag (X265_LATEST_TAG). A shallow `git clone --depth 1` has no tags,
# so x265.pc is NOT produced -> FFmpeg's --enable-libx265 (which requires
# pkg-config) fails. We therefore always write a correct x265.pc ourselves,
# with Android/NDK link flags: libx265 is C++ so it needs the NDK C++ runtime
# (-lc++_shared, shipped in the sysroot). FFmpeg's own x265 gate is the header
# macro X265_BUILD (>=89), independent of this .pc's Version field.
# ---------------------------------------------------------------------------
write_x265_pc(){
  local pc="$PREFIX/lib/pkgconfig/x265.pc"
  [ -f "$PREFIX/lib/libx265.a" ] || return 0
  cat > "$pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: 4.1
Libs: -L\${libdir} -lx265
Libs.private: -lc++_shared -lm -ldl
Cflags: -I\${includedir}
EOF
}
_x265_try(){ # extra-cmake-args...
  local s="$SRCROOT/x265" b="$SRCROOT/x265/build-$ABI"
  rm -rf "$b"
  steps "cmake -S '$s/source' -B '$b' \
      -DCMAKE_TOOLCHAIN_FILE='$NDK/build/cmake/android.toolchain.cmake' \
      -DANDROID_ABI='$ABI' -DANDROID_PLATFORM=android-$API \
      -DCMAKE_INSTALL_PREFIX='$PREFIX' -DENABLE_SHARED=OFF -DENABLE_CLI=OFF $* \
   && cmake --build '$b' -j$JOBS && cmake --install '$b'"
}
build_x265(){
  if skip_if_built x265; then write_x265_pc; return 0; fi
  fetch_git "https://bitbucket.org/multicoreware/x265_git.git" x265 || return 1
  if _x265_try ""; then write_x265_pc; return 0; fi
  log "x265/$ABI: retrying with -DENABLE_ASSEMBLY=OFF"
  _x265_try "-DENABLE_ASSEMBLY=OFF" && { write_x265_pc; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# libaom (cmake)
# ---------------------------------------------------------------------------
build_aom(){
  skip_if_built aom && return 0
  fetch_git "https://aomedia.googlesource.com/aom" aom || return 1
  local s="$SRCROOT/aom" b="$SRCROOT/aom/build-$ABI"; rm -rf "$b"
  steps "cmake -S '$s' -B '$b' \
      -DCMAKE_TOOLCHAIN_FILE='$NDK/build/cmake/android.toolchain.cmake' \
      -DANDROID_ABI='$ABI' -DANDROID_PLATFORM=android-$API \
      -DCMAKE_INSTALL_PREFIX='$PREFIX' \
      -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 -DENABLE_DOCS=0 \
      -DBUILD_SHARED_LIBS=0 -DCONFIG_PIC=1 \
   && cmake --build '$b' -j$JOBS && cmake --install '$b'"
}

# ---------------------------------------------------------------------------
# dav1d (meson + ninja, cross file)
# ---------------------------------------------------------------------------
build_dav1d(){
  skip_if_built dav1d && return 0
  fetch_git "https://code.videolan.org/videolan/dav1d.git" dav1d || return 1
  local s="$SRCROOT/dav1d" cross="$SRCROOT/dav1d/cross-$ABI.txt" b="$SRCROOT/dav1d/build-$ABI"
  cat > "$cross" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
nasm = '$LOCALBIN/nasm'
[host_machine]
system = 'android'
cpu_family = '$CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
EOF
  rm -rf "$b"
  steps "meson setup '$b' '$s' --cross-file '$cross' --default-library=static \
      --prefix='$PREFIX' -Denable_tools=false -Denable_tests=false --buildtype release \
   && ninja -C '$b' install"
}

# ---------------------------------------------------------------------------
# libvpx (out-of-tree; fall back to generic-gnu if the android target is rejected)
# ---------------------------------------------------------------------------
_vpx_try(){ # target [extra]
  local s="$SRCROOT/vpx" b="$SRCROOT/vpx-build-$ABI"
  rm -rf "$b"; mkdir -p "$b"
  steps "cd '$b' && CC='$CC' CXX='$CXX' '$s/configure' --target=$1 --prefix='$PREFIX' \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --enable-pic --enable-static --disable-shared ${2:-} \
   && make -j$JOBS && make install"
}
build_vpx(){
  skip_if_built vpx && return 0
  fetch_git "https://chromium.googlesource.com/webm/libvpx" vpx || return 1
  local asflag=""; [ "$ABI" = "x86_64" ] && asflag="--as=nasm"
  if _vpx_try "$VPXTGT" "$asflag"; then return 0; fi
  log "libvpx/$ABI: target $VPXTGT rejected -> fallback generic-gnu (NO SIMD)"
  VPX_FELLBACK=1
  _vpx_try "generic-gnu" ""
}

###############################################################################
# BATCH 2 — easy tier (independent libs)
###############################################################################
build_webp(){
  skip_if_built webp && return 0
  fetch_git "https://github.com/webmproject/libwebp.git" webp || return 1
  cmake_build "$SRCROOT/webp" "$SRCROOT/webp/build-$ABI" \
      -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
      -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
      -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_EXTRAS=OFF
}
build_theora(){          # autotools, needs libogg from this same prefix
  skip_if_built theora && return 0
  fetch_tar "$THEORA_URL" "libtheora-$THEORA_VER" || return 1
  autotools_build "$SRCROOT/libtheora-$THEORA_VER" \
      --with-ogg="$PREFIX" --disable-asm --disable-examples \
      --disable-oggtest --disable-vorbistest --disable-sdltest --disable-spec
}
build_soxr(){
  skip_if_built soxr && return 0
  fetch_git "https://github.com/chirlu/soxr.git" soxr || return 1
  cmake_build "$SRCROOT/soxr" "$SRCROOT/soxr/build-$ABI" \
      -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF
}
build_zimg(){            # autotools (autogen); graphengine is a git submodule
  skip_if_built zimg && return 0
  fetch_git_recursive "https://github.com/sekrit-twc/zimg.git" zimg || return 1
  local s="$SRCROOT/zimg"
  [ -x "$s/configure" ] || steps "cd '$s' && ./autogen.sh" || return 1
  autotools_build "$s"
}
build_twolame(){
  skip_if_built twolame && return 0
  fetch_tar "$TWOLAME_URL" "twolame-$TWOLAME_VER" || return 1
  autotools_build "$SRCROOT/twolame-$TWOLAME_VER"
}
build_openjpeg(){
  skip_if_built openjpeg && return 0
  fetch_git "https://github.com/uclouvain/openjpeg.git" openjpeg || return 1
  cmake_build "$SRCROOT/openjpeg" "$SRCROOT/openjpeg/build-$ABI" \
      -DBUILD_CODEC=OFF -DBUILD_DOC=OFF -DBUILD_TESTING=OFF
}
build_openh264(){        # meson
  skip_if_built openh264 && return 0
  fetch_git "https://github.com/cisco/openh264.git" openh264 || return 1
  meson_build "$SRCROOT/openh264" "$SRCROOT/openh264/build-$ABI" -Dtests=disabled
}
build_xml2(){
  skip_if_built xml2 && return 0
  fetch_tar "$XML2_URL" "libxml2-$XML2_VER" || return 1
  autotools_build "$SRCROOT/libxml2-$XML2_VER" \
      --without-python --without-lzma --without-zlib --without-iconv --without-http
}
build_svtav1(){          # cmake; arm64 supported on recent SVT-AV1 (skip ABI on fail)
  skip_if_built svtav1 && return 0
  fetch_git "https://gitlab.com/AOMediaCodec/SVT-AV1.git" svtav1 || return 1
  cmake_build "$SRCROOT/svtav1" "$SRCROOT/svtav1/build-$ABI" \
      -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
}

###############################################################################
# BATCH 2 — libass font chain (dependency-ordered, 2-pass freetype/harfbuzz)
###############################################################################
build_fribidi(){         # meson
  skip_if_built fribidi && return 0
  fetch_git "https://github.com/fribidi/fribidi.git" fribidi || return 1
  meson_build "$SRCROOT/fribidi" "$SRCROOT/fribidi/build-$ABI" \
      -Dtests=false -Dbin=false -Ddocs=false
}
# freetype (autotools, in-tree so the two passes reuse one tree; distclean each pass)
_freetype_build(){       # $1 = on|off (harfbuzz)
  fetch_tar "$FREETYPE_URL" "freetype-$FREETYPE_VER" || return 1
  local s="$SRCROOT/freetype-$FREETYPE_VER" hb
  [ "$1" = on ] && hb="--with-harfbuzz=yes" || hb="--with-harfbuzz=no"
  refresh_config_scripts "$s"
  steps "cd '$s' && ( make distclean >/dev/null 2>&1 || true ) \
      && CC='$CC' CXX='$CXX' AR='$AR' RANLIB='$RANLIB' ./configure \
      --host=$TRIPLE --build=x86_64-linux-gnu --prefix='$PREFIX' \
      --disable-shared --enable-static --with-pic \
      --without-zlib --without-bzip2 --without-png --without-brotli $hb \
   && make -j$JOBS && make install"
}
build_freetype(){        # standalone/reuse: harfbuzz on iff already installed
  local hb=off; [ -f "$PREFIX/lib/libharfbuzz.a" ] && hb=on
  _freetype_build "$hb"
}
build_harfbuzz(){        # meson, needs freetype (pass 1) via pkg-config
  skip_if_built harfbuzz && return 0
  fetch_git "https://github.com/harfbuzz/harfbuzz.git" harfbuzz || return 1
  meson_build "$SRCROOT/harfbuzz" "$SRCROOT/harfbuzz/build-$ABI" \
      -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
      -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
}
build_ass(){             # autotools, needs freetype2 + fribidi + harfbuzz
  skip_if_built ass && return 0
  fetch_tar "$LIBASS_URL" "libass-$LIBASS_VER" || return 1
  autotools_build "$SRCROOT/libass-$LIBASS_VER" \
      --disable-fontconfig --disable-require-system-font-provider
}

# Dependency-ordered font chain per ABI:
#   fribidi -> freetype(no hb) -> harfbuzz(with freetype) -> freetype(with hb) -> libass
run_fontchain(){
  local abi hb
  for abi in "${ABIS[@]}"; do
    setup_abi "$abi"
    stage fribidi
    # freetype pass 1 (without harfbuzz) so harfbuzz can link against it
    if ! have freetype; then
      ram_guard; log ">>> freetype pass1 (harfbuzz=off) / $abi"
      _freetype_build off >"$LOGDIR/freetype-$abi.log" 2>&1 || log "freetype pass1 FAILED / $abi"
    fi
    stage harfbuzz
    # freetype pass 2 (with harfbuzz if it built) -> this is the recorded result
    ram_guard; hb=off; have harfbuzz && hb=on
    log ">>> freetype pass2 (harfbuzz=$hb) / $abi"
    if _freetype_build "$hb" >>"$LOGDIR/freetype-$abi.log" 2>&1; then
      record freetype "$abi" OK "harfbuzz=$hb"; log "OK  freetype / $abi"
    else
      record freetype "$abi" FAIL "$(tail -n 4 "$LOGDIR/freetype-$abi.log" | tr '\n' ' ' | tail -c 160)"
      log "FAIL freetype / $abi"
    fi
    stage ass
  done
}

# ---------------------------------------------------------------------------
# FFmpeg rebuild (shared) for a given VERSION + LICENSE VARIANT, linking the
# prebuilt libs. Pristine per-(ver,abi,variant) source clone -> in-tree build,
# so no config.h collision between combos.
#
# License variant -> configure license flags + lib exclusions (mirrors BtbN):
#   gpl   (GPLv3)     : --enable-gpl --enable-version3 ; ALL libs
#   lgpl  (LGPLv3)    : --enable-version3 (NO --enable-gpl) ; drop GPL-only libs
#   gpl2  (GPLv2)     : --enable-gpl (NO version3) ; ALL libs
#   lgpl2 (LGPLv2.1)  : neither flag ; drop GPL-only libs
# GPL-only libs in our current set = x264, x265 (both require --enable-gpl).
#
# GRACEFUL DEGRADATION: an older FFmpeg may reject one of our newer libs (an
# unknown --enable-libX option, a "libX not found" / version error at configure,
# or a wrapper compile error at make). We retry, dropping ONE offending
# --enable-libX flag each round, until it builds (or all lib flags exhausted).
# ---------------------------------------------------------------------------
GPL_ONLY_LIBS=(x264 x265)   # libs that force --enable-gpl -> excluded from lgpl*
is_gpl_only(){ local l; for l in "${GPL_ONLY_LIBS[@]}"; do [ "$1" = "$l" ] && return 0; done; return 1; }

# variant -> sets globals LIC (license flags) and GPL_OK (1/0).
_variant_flags(){
  case "$1" in
    gpl)   LIC="--enable-gpl --enable-version3"; GPL_OK=1 ;;
    lgpl)  LIC="--enable-version3";              GPL_OK=0 ;;
    gpl2)  LIC="--enable-gpl";                   GPL_OK=1 ;;
    lgpl2) LIC="";                               GPL_OK=0 ;;
    *) return 1 ;;
  esac
}

# Ensure a (possibly shallow) FFmpeg checkout has release tags so `git describe`
# and FFmpeg's own version.sh produce the full version (n<ver>-<commits>-g<hash>)
# instead of just a short commit hash. Best-effort (network); silent on failure.
ensure_tags(){ # dir
  local d="$1"
  git -C "$d" describe --tags --match 'n*' >/dev/null 2>&1 && return 0
  log "fetch tags into $(basename "$d") for full version" >&2
  git -C "$d" fetch --tags --depth 200 >/dev/null 2>&1 \
    || git -C "$d" fetch --tags --unshallow >/dev/null 2>&1 || true
}

# Full FFmpeg version label for artifact naming, desktop-style: prefer
# `git describe` (n8.1.2-21-gce3c09c101); fall back to the RELEASE file
# (n8.1.2); last resort the 2-part branch version (n8.1).
ff_full_version(){ # srcdir ver
  local d="$1" ver="$2" v
  v=$(git -C "$d" describe --tags --match 'n*' 2>/dev/null)
  if [ -n "$v" ]; then echo "$v"; return; fi
  if [ -s "$d/RELEASE" ]; then echo "n$(tr -d '[:space:]' < "$d/RELEASE")"; return; fi
  echo "n$ver"
}

# License variant -> the FFmpeg COPYING.* file shipped in the source tree.
_variant_copying(){ # variant
  case "$1" in
    gpl)   echo COPYING.GPLv3 ;;
    lgpl)  echo COPYING.LGPLv3 ;;
    gpl2)  echo COPYING.GPLv2 ;;
    lgpl2) echo COPYING.LGPLv2.1 ;;
    *) return 1 ;;
  esac
}

# Ensure the FFmpeg source for a version exists; echo its path. 8.1 reuses the
# existing pristine checkout; others are cloned from release/<ver>.
ff_src_dir(){ # ver
  local ver="$1" d
  if [ "$ver" = 8.1 ]; then ensure_tags "$FF_SRC_BASE"; echo "$FF_SRC_BASE"; return 0; fi
  d="$ROOT/src/ffmpeg-$ver"
  if [ ! -d "$d/.git" ]; then
    log "clone FFmpeg release/$ver" >&2
    git clone --depth 1 --branch "release/$ver" \
        https://github.com/FFmpeg/FFmpeg.git "$d" >&2 || return 1
  fi
  ensure_tags "$d"
  echo "$d"
}

# One configure invocation. Uses globals: PREFIX, FF_ARCH, FF_CPU, CC..., EN, LIC.
_ff_configure(){ # ffdir ffprefix
  local ffdir="$1" ffprefix="$2" cpuflag=""
  [ -n "$FF_CPU" ] && cpuflag="--cpu=$FF_CPU"
  steps "cd '$ffdir' && PKG_CONFIG_LIBDIR='$PREFIX/lib/pkgconfig' ./configure \
      --prefix='$ffprefix' --target-os=android --arch=$FF_ARCH $cpuflag \
      --enable-cross-compile --cross-prefix='$TC/bin/llvm-' --pkg-config=pkg-config \
      --cc='$CC' --cxx='$CXX' --ar='$AR' --nm='$NM' --ranlib='$RANLIB' --strip='$STRIP' \
      --sysroot='$SYSROOT' \
      --enable-shared --disable-static --disable-doc --disable-ffplay --disable-vulkan \
      $LIC --pkg-config-flags=--static \
      --extra-cflags='-I$PREFIX/include' --extra-ldflags='-L$PREFIX/lib' \
      --extra-libs='-lc++_shared -lm' \
      $EN"
}

# Identify one --enable-libX flag to drop from a failed CONFIGURE log.
_find_drop_configure(){ # log enflags...
  local log="$1"; shift; local en=("$@") f lib tok uo errline
  uo=$(grep -oE 'Unknown option "--enable-lib[a-z0-9]+"' "$log" | head -1 | grep -oE '\-\-enable-lib[a-z0-9]+')
  if [ -n "$uo" ]; then echo "$uo"; return; fi
  errline=$(grep -iE 'ERROR:' "$log" | grep -viE 'you think configure|report the problem|mailing list|Include the log' | tail -1)
  [ -z "$errline" ] && return
  for f in "${en[@]}"; do
    lib="${FLAG2LIB[$f]:-}"; [ -z "$lib" ] && continue
    for tok in ${LIBTOKENS[$lib]:-}; do
      if printf '%s' "$errline" | grep -qiF "$tok"; then echo "$f"; return; fi
    done
  done
}

# Identify one --enable-libX flag to drop from a failed MAKE log.
_find_drop_make(){ # log enflags...
  local log="$1"; shift; local en=("$@") errctx stems s lib f e
  errctx=$(grep -iE 'error:|\*\*\* \[' "$log")
  stems=$(printf '%s\n' "$errctx" | grep -oE '(lib[a-z0-9_]+|vf_[a-z0-9_]+|af_[a-z0-9_]+)' | sort -u)
  for s in $stems; do
    lib="${SRCFILE2LIB[$s]:-}"; [ -z "$lib" ] && continue
    f="${FFFLAG[$lib]:-}"; [ -z "$f" ] && continue
    for e in "${en[@]}"; do [ "$e" = "$f" ] && { echo "$f"; return; }; done
  done
}

# build_ffmpeg VER ABI VARIANT  -> installs + packages; sets DROPPED_LIBS.
build_ffmpeg(){
  local ver="$1" abi="$2" variant="${3:-gpl}" ffver="${4:-}"; setup_abi "$abi"
  local FF_SRC; FF_SRC=$(ff_src_dir "$ver") || { log "no source for $ver"; return 1; }
  [ -z "$ffver" ] && ffver=$(ff_full_version "$FF_SRC" "$ver")
  local FF_PREFIX="$ROOT/out/$ver-$abi-$variant-full"
  local FF_DIR="$ROOT/src/ffmpeg-$ver-full-$abi-$variant"
  rm -rf "$FF_DIR" "$FF_PREFIX"
  git clone --local "$FF_SRC" "$FF_DIR" || return 1
  _variant_flags "$variant" || { log "unknown variant $variant"; return 2; }

  # Assemble --enable flags from libs installed for this ABI, honouring license.
  local en=() lib
  for lib in "${ALL_LIBS[@]}"; do
    have "$lib" || continue
    [ -z "${FFFLAG[$lib]:-}" ] && continue
    if [ "$GPL_OK" -eq 0 ] && is_gpl_only "$lib"; then continue; fi
    en+=("${FFFLAG[$lib]}")
  done
  log "ffmpeg $ver/$abi [$variant] license='$LIC' start libs=${#en[@]}"

  local dropped=() attempt=0 max=$(( ${#en[@]} + 4 )) off f nn=()
  local cfg_log="$FF_DIR/_cfg.log" mk_log="$FF_DIR/_make.log"
  DROPPED_LIBS=""
  while :; do
    attempt=$((attempt+1))
    EN="${en[*]}"
    if _ff_configure "$FF_DIR" "$FF_PREFIX" >"$cfg_log" 2>&1; then
      if steps "cd '$FF_DIR' && make -j$JOBS" >"$mk_log" 2>&1; then
        break                                    # configure + make succeeded
      fi
      off=$(_find_drop_make "$mk_log" "${en[@]}")
      if [ -z "$off" ]; then log "make failed, no lib to drop:"; tail -n 6 "$mk_log"; return 1; fi
    else
      off=$(_find_drop_configure "$cfg_log" "${en[@]}")
      if [ -z "$off" ]; then log "configure failed, no lib to drop:"; tail -n 8 "$cfg_log"; return 1; fi
    fi
    if [ "$attempt" -ge "$max" ]; then log "degradation attempts exhausted"; return 1; fi
    log "  drop $off (round $attempt) and retry"
    dropped+=("$off")
    nn=(); for f in "${en[@]}"; do [ "$f" = "$off" ] || nn+=("$f"); done; en=("${nn[@]}")
    steps "cd '$FF_DIR' && make distclean" >/dev/null 2>&1 || true
  done
  DROPPED_LIBS="${dropped[*]}"

  steps "cd '$FF_DIR' && make install" >>"$mk_log" 2>&1 || return 1
  # Bundle the NDK C++ runtime that the shared libs + programs link against
  # (configure passes -lc++_shared); it is not part of FFmpeg's own install.
  local libcxx="$SYSROOT/usr/lib/$TRIPLE/libc++_shared.so"
  if [ -f "$libcxx" ]; then cp -f "$libcxx" "$FF_PREFIX/lib/"; else log "WARN: libc++_shared.so not found at $libcxx"; fi
  # Ship the matching GNU license text as LICENSE.txt (FFmpeg source has COPYING.*).
  local copying; copying=$(_variant_copying "$variant")
  if [ -n "$copying" ] && [ -f "$FF_DIR/$copying" ]; then
    cp -f "$FF_DIR/$copying" "$FF_PREFIX/LICENSE.txt"
  else
    log "WARN: $copying not found in source; archive will lack LICENSE.txt"
  fi
  local extra_files=""; [ -f "$FF_PREFIX/LICENSE.txt" ] && extra_files="LICENSE.txt"
  # Programs (ffmpeg, ffprobe; ffplay disabled) install to bin/ now that
  # --disable-programs was dropped (programs are default-on; only ffplay is
  # explicitly disabled); include the dir in the archive when present.
  local prog_dir=""; [ -d "$FF_PREFIX/bin" ] && prog_dir="bin"
  steps "cd '$FF_PREFIX' && tar -cJf \
      '$ROOT/artifacts/ffmpeg-$ffver-android-$abi-$variant-shared-full.tar.xz' lib include $prog_dir $extra_files" || return 1
  grep -iA30 'External libraries' "$cfg_log" 2>/dev/null | sed -n '1,25p' \
      > "$LOGDIR/ffmpeg-$ver-$variant-$abi.extlibs.txt" || true
  rm -rf "$FF_DIR"                                # reclaim disk; artifact is kept
  return 0
}

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------
run_libs(){
  local lib abi
  for lib in "${LIBS_ORDER[@]}"; do
    for abi in "${ABIS[@]}"; do
      setup_abi "$abi"
      stage "$lib"
    done
  done
}
# run_ffmpeg [variant...]   builds FFmpeg 8.1 for the given variants (default gpl).
run_ffmpeg(){ run_phase2_versions "8.1" "$@"; }

# run_phase2 [version...]   Full Phase 2: each version x 4 variants x 2 ABIs.
# Resumable: skips any combo whose artifact already exists; appends to
# phase2-progress.log. Applies graceful lib-flag degradation per combo.
run_phase2(){
  local versions=("$@")
  [ ${#versions[@]} -eq 0 ] && versions=(8.0 7.1 7.0 6.1 6.0 5.1 5.0 4.4)
  run_phase2_versions "${versions[*]}" gpl lgpl gpl2 lgpl2
}

# internal: run_phase2_versions "<space-sep versions>" [variant...]
run_phase2_versions(){
  local versions=($1); shift
  local variants=("$@"); [ ${#variants[@]} -eq 0 ] && variants=(gpl lgpl gpl2 lgpl2)
  local ver variant abi art sz
  local ffsrc ffver
  for ver in "${versions[@]}"; do
    ffsrc=$(ff_src_dir "$ver" 2>>"$LOGDIR/phase2-clone.log") \
      || { log "SKIP version $ver (clone failed)"; continue; }
    ffver=$(ff_full_version "$ffsrc" "$ver")
    log "version $ver -> $ffver"
    for variant in "${variants[@]}"; do
      for abi in "${ABIS[@]}"; do
        art="$ROOT/artifacts/ffmpeg-$ffver-android-$abi-$variant-shared-full.tar.xz"
        if [ -f "$art" ]; then log "skip existing $ver/$variant/$abi"; continue; fi
        if past_deadline; then log "DEADLINE reached -> stop starting new combos"; return 0; fi
        ram_guard
        log ">>> FFmpeg $ver [$variant] / $abi"
        DROPPED_LIBS=""
        if build_ffmpeg "$ver" "$abi" "$variant" "$ffver" >"$LOGDIR/ffmpeg-$ver-$variant-$abi.log" 2>&1; then
          sz=$(stat -c%s "$art" 2>/dev/null || echo 0)
          record "$ver-$variant" "$abi" OK "drop:[${DROPPED_LIBS:-none}]"
          echo "$(date +%H:%M:%S) | $ver | $abi | $variant | OK | dropped:[${DROPPED_LIBS:-none}] | ${sz}B" >> "$ROOT/phase2-progress.log"
          log "OK  $ver/$variant/$abi dropped:[${DROPPED_LIBS:-none}]"
        else
          record "$ver-$variant" "$abi" FAIL "$(tail -n 3 "$LOGDIR/ffmpeg-$ver-$variant-$abi.log" | tr '\n' ' ' | tail -c 140)"
          echo "$(date +%H:%M:%S) | $ver | $abi | $variant | FAIL | $(tail -n 2 "$LOGDIR/ffmpeg-$ver-$variant-$abi.log" | tr '\n' ' ' | tail -c 120)" >> "$ROOT/phase2-progress.log"
          log "FAIL $ver/$variant/$abi (see $LOGDIR/ffmpeg-$ver-$variant-$abi.log)"
        fi
      done
    done
  done
}
summary(){
  echo; echo "======== BUILD SUMMARY ========"; cat "$STATUS" 2>/dev/null
  echo; echo "-- installed archives --"
  local abi
  for abi in "${ABIS[@]}"; do
    echo "[$abi]"; ls -1 "$DEPSROOT/$abi/lib"/*.a 2>/dev/null | sed 's#.*/#  #'
  done
  echo; echo "-- artifacts --"; ls -la "$ROOT/artifacts"/*full* 2>/dev/null
}

echo "==== build-libs.sh start $(date) ===="
# Usage:
#   ./build-libs.sh                       # libs + fonts + FFmpeg (gpl)
#   ./build-libs.sh all                   # same as above
#   ./build-libs.sh libs                  # external libs only
#   ./build-libs.sh fonts                 # libass font chain only
#   ./build-libs.sh ffmpeg [variant...]   # FFmpeg 8.1 only, given license
#                                         # variants (gpl lgpl gpl2 lgpl2);
#                                         # default gpl. Reuses prebuilt libs.
#   ./build-libs.sh phase2 [version...]   # each version x 4 variants x 2 ABIs,
#                                         # graceful lib-flag degradation,
#                                         # resumable (skips existing artifacts).
#                                         # default versions: 8.0..4.4
# Examples:  ./build-libs.sh ffmpeg lgpl gpl2 lgpl2
#            ./build-libs.sh phase2 8.0 7.1 7.0 6.1 6.0 5.1 5.0 4.4
mode="${1:-all}"; shift 2>/dev/null || true
case "$mode" in
  libs)   : > "$STATUS"; run_libs ;;
  fonts)  run_fontchain ;;
  ffmpeg) run_ffmpeg "$@" ;;                       # do NOT wipe lib status here
  phase2) run_phase2 "$@" ;;                        # do NOT wipe lib status here
  all|*)  : > "$STATUS"; run_libs; run_fontchain; run_ffmpeg gpl ;;
esac
summary
echo "==== build-libs.sh done $(date) ===="
