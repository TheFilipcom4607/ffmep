#!/usr/bin/env bash
# Builds a static arm64 ffmpeg + ffprobe (macOS 14+) into vendor/.
# Only links system libraries at runtime. Resumable: finished steps are skipped on re-run.
#
# Requires: Xcode command line tools, cmake, and `brew install meson ninja pkgconf`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/src"     # downloaded tarballs (checksummed)
WORK="$BUILD/work"   # extracted sources, recreated per step
DEPS="$BUILD/deps"   # static install prefix
LOGS="$BUILD/logs"
VENDOR="$ROOT/vendor"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$SRC" "$WORK" "$DEPS" "$LOGS" "$VENDOR"

# Keep Homebrew/devkitPro libraries and pkg-config files out of the build.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG=/opt/homebrew/bin/pkgconf
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET=14.0
ARCH_FLAGS="-arch arm64 -mmacosx-version-min=14.0"
export CFLAGS="$ARCH_FLAGS" CXXFLAGS="$ARCH_FLAGS" LDFLAGS="$ARCH_FLAGS"
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

for tool in cmake meson ninja pkgconf clang; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Run: brew install cmake meson ninja pkgconf"; exit 1; }
done

CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$DEPS"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DBUILD_SHARED_LIBS=OFF
)

# name | file | url | sha256
FFMPEG_VER=9.0.1
X264_REV=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
X265_VER=4.3
SVTAV1_VER=4.2.0
VPX_VER=1.17.0
OPUS_VER=1.6.1
LAME_VER=4.0
WEBP_VER=1.6.0
DAV1D_VER=1.5.4

SOURCES=(
  "ffmpeg|ffmpeg-$FFMPEG_VER.tar.xz|https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz|cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
  "x264|x264-$X264_REV.tar.bz2|https://code.videolan.org/videolan/x264/-/archive/$X264_REV/x264-$X264_REV.tar.bz2|6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"
  "x265|x265_$X265_VER.tar.gz|https://github.com/Multicorewareinc/x265/releases/download/$X265_VER/x265_$X265_VER.tar.gz|83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121"
  "svtav1|SVT-AV1-v$SVTAV1_VER.tar.gz|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v$SVTAV1_VER/SVT-AV1-v$SVTAV1_VER.tar.gz|c7b13c4a84bd3751aa35fcc72be13e6875467e7c2216879251a486e5b1e4e740"
  "libvpx|libvpx-$VPX_VER.tar.gz|https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VER.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"
  "opus|opus-$OPUS_VER.tar.gz|https://downloads.xiph.org/releases/opus/opus-$OPUS_VER.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
  "lame|lame-$LAME_VER.tar.gz|https://downloads.sourceforge.net/project/lame/lame/$LAME_VER/lame-$LAME_VER.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
  "libwebp|libwebp-$WEBP_VER.tar.gz|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_VER.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
  "dav1d|dav1d-$DAV1D_VER.tar.xz|https://download.videolan.org/pub/videolan/dav1d/$DAV1D_VER/dav1d-$DAV1D_VER.tar.xz|686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
)

# Downloads (if needed), verifies and extracts a source into $WORK/<name>, then cds into it.
unpack() {
  local want=$1 entry name file url sha
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name file url sha <<<"$entry"
    [[ "$name" == "$want" ]] || continue
    if ! echo "$sha  $SRC/$file" | shasum -a 256 -c - >/dev/null 2>&1; then
      echo "Downloading $url"
      curl -fL --retry 3 -o "$SRC/$file.part" "$url"
      mv "$SRC/$file.part" "$SRC/$file"
      echo "$sha  $SRC/$file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $file"; rm -f "$SRC/$file"; return 1; }
    fi
    rm -rf "${WORK:?}/$name"
    mkdir -p "$WORK/$name"
    tar -xf "$SRC/$file" -C "$WORK/$name" --strip-components 1
    cd "$WORK/$name"
    return 0
  done
  echo "Unknown source $want"; return 1
}

# run_step <marker> <function>: runs the function with output in build/logs, skipping finished steps.
run_step() {
  local marker=$1 fn=$2 start=$SECONDS status
  if [[ -f "$DEPS/.done-$marker" ]]; then
    echo "✓ $marker (already built)"
    return
  fi
  echo "→ $marker  (log: build/logs/$marker.log)"
  set +e
  ( set -euo pipefail; "$fn" ) >"$LOGS/$marker.log" 2>&1
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "✗ $marker failed. Last lines of build/logs/$marker.log:"
    tail -n 40 "$LOGS/$marker.log"
    exit 1
  fi
  touch "$DEPS/.done-$marker"
  echo "✓ $marker ($((SECONDS - start))s)"
}

build_x264() {
  unpack x264
  ./configure --prefix="$DEPS" --enable-static --enable-pic --disable-cli \
    --extra-cflags="$ARCH_FLAGS" --extra-ldflags="$ARCH_FLAGS"
  make -j"$JOBS"
  make install
}

build_x265() {
  unpack x265
  cmake -S source -B build-8bit "${CMAKE_COMMON[@]}" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DHIGH_BIT_DEPTH=OFF
  cmake --build build-8bit -j"$JOBS"
  cmake --install build-8bit
}

build_svtav1() {
  unpack svtav1
  cmake -S . -B build "${CMAKE_COMMON[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
  cmake --build build -j"$JOBS"
  cmake --install build
}

build_libvpx() {
  unpack libvpx
  # Newest arm64 darwin target this libvpx knows; the SDK min version comes from our flags.
  local target
  target="$( (./configure --help || true) | grep -oE 'arm64-darwin[0-9]+-gcc' | sort -V | tail -1)"  # --help exits 1
  mkdir -p macbuild && cd macbuild
  ../configure --prefix="$DEPS" --target="$target" \
    --enable-static --disable-shared --enable-pic --enable-runtime-cpu-detect \
    --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --extra-cflags="$ARCH_FLAGS" --extra-cxxflags="$ARCH_FLAGS"
  make -j"$JOBS"
  make install
}

build_opus() {
  unpack opus
  ./configure --prefix="$DEPS" --enable-static --disable-shared --disable-doc --disable-extra-programs
  make -j"$JOBS"
  make install
}

build_lame() {
  unpack lame
  # LAME still uses undeclared legacy ID3 APIs, which don't compile as C23.
  export ac_cv_prog_cc_c23=no
  export CFLAGS="$CFLAGS -Wno-implicit-function-declaration"
  # ffmpeg only needs the encoder; the mp3 decoder would pull in libmpg123.
  ./configure --prefix="$DEPS" --enable-static --disable-shared --disable-frontend \
    --disable-decoder --disable-analyzer-hooks --disable-gtktest \
    --disable-dependency-tracking --disable-debug \
    --build=aarch64-apple-darwin --host=aarch64-apple-darwin
  make -j"$JOBS"
  make install
}

build_libwebp() {
  unpack libwebp
  cmake -S . -B build "${CMAKE_COMMON[@]}" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON
  cmake --build build -j"$JOBS"
  cmake --install build
}

build_dav1d() {
  unpack dav1d
  meson setup build --prefix="$DEPS" --libdir=lib --buildtype=release --default-library=static \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false
  ninja -C build -j"$JOBS"
  ninja -C build install
}

build_ffmpeg() {
  unpack ffmpeg
  ./configure \
    --prefix="$BUILD/ffmpeg-install" \
    --cc=clang --arch=arm64 \
    --pkg-config="$PKG_CONFIG" --pkg-config-flags=--static \
    --extra-cflags="$ARCH_FLAGS -I$DEPS/include" \
    --extra-ldflags="$ARCH_FLAGS -L$DEPS/lib" \
    --extra-libs="-liconv" \
    --enable-gpl --enable-version3 --enable-static --disable-shared \
    --disable-autodetect --enable-zlib --enable-bzlib --enable-iconv \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-libx264 --enable-libx265 --enable-libsvtav1 --enable-libvpx \
    --enable-libopus --enable-libmp3lame --enable-libwebp --enable-libdav1d \
    --disable-ffplay --disable-doc --disable-debug --disable-network
  make -j"$JOBS"
  install -m 755 ffmpeg ffprobe "$VENDOR/"
  mkdir -p "$VENDOR/licenses"
  cp COPYING.GPLv3 COPYING.GPLv2 LICENSE.md "$VENDOR/licenses/"
}

echo "Building static ffmpeg $FFMPEG_VER for arm64 (macOS 14+) with $JOBS jobs"
run_step "x264-${X264_REV:0:8}" build_x264
run_step "x265-$X265_VER" build_x265
run_step "svtav1-$SVTAV1_VER" build_svtav1
run_step "libvpx-$VPX_VER" build_libvpx
run_step "opus-$OPUS_VER" build_opus
run_step "lame-$LAME_VER" build_lame
run_step "libwebp-$WEBP_VER" build_libwebp
run_step "dav1d-$DAV1D_VER" build_dav1d
if [[ ! -x "$VENDOR/ffmpeg" || ! -x "$VENDOR/ffprobe" ]]; then rm -f "$DEPS/.done-ffmpeg-$FFMPEG_VER"; fi
run_step "ffmpeg-$FFMPEG_VER" build_ffmpeg

echo
echo "Verifying…"
fail=0
for bin in ffmpeg ffprobe; do
  foreign="$(otool -L "$VENDOR/$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' || true)"
  if [[ -n "$foreign" ]]; then echo "✗ $bin links non-system libraries:"; echo "$foreign"; fail=1; fi
done
encoders="$("$VENDOR/ffmpeg" -hide_banner -encoders)"
for enc in libwebp libx264 libx265 libsvtav1 libvpx-vp9 libopus libmp3lame \
           h264_videotoolbox hevc_videotoolbox prores_videotoolbox aac_at; do
  grep -qE "^ [A-Z.]{6} $enc " <<<"$encoders" || { echo "✗ missing encoder $enc"; fail=1; }
done
[[ $fail -eq 0 ]] || exit 1

{
  echo "ffmpeg $FFMPEG_VER (https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz)"
  echo "x264 $X264_REV, x265 $X265_VER, SVT-AV1 $SVTAV1_VER, libvpx $VPX_VER, opus $OPUS_VER,"
  echo "lame $LAME_VER, libwebp $WEBP_VER, dav1d $DAV1D_VER"
  echo "Built $(date -u +%Y-%m-%dT%H:%MZ) by scripts/build-ffmpeg.sh"
} >"$VENDOR/BUILDINFO.txt"

echo "✓ vendor/ffmpeg $("$VENDOR/ffmpeg" -hide_banner -version | head -1 | awk '{print $3}') — only system libraries, all encoders present"
ls -lh "$VENDOR/ffmpeg" "$VENDOR/ffprobe"
