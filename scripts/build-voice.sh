#!/bin/bash
set -euo pipefail
VERSION=8.1.3
SHA=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
mkdir -p build/ffmpeg-source Vendor/ffmpeg
ARCHIVE="$PWD/build/ffmpeg-source/ffmpeg-$VERSION.tar.xz"
if [ -f "$PWD/third-party-sources/ffmpeg-$VERSION.tar.xz" ]; then ARCHIVE="$PWD/third-party-sources/ffmpeg-$VERSION.tar.xz"; fi
if [ ! -f "$ARCHIVE" ]; then curl --fail --location --max-time 120 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"; fi
printf '%s  %s\n' "$SHA" "$ARCHIVE" | shasum -a 256 -c -
tar -xf "$ARCHIVE" -C build/ffmpeg-source
SOURCE="$PWD/build/ffmpeg-source/ffmpeg-$VERSION"
for SDK in iphoneos iphonesimulator; do
 PREFIX="$PWD/Vendor/ffmpeg/$SDK"
 if [ -f "$PREFIX/lib/libavformat.a" ]; then continue; fi
 ARCH=arm64
 if [ "$SDK" = iphonesimulator ]; then ARCH=$(uname -m); MIN="-mios-simulator-version-min=16.0"; else MIN="-miphoneos-version-min=16.0"; fi
 SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
 mkdir -p "build/ffmpeg-$SDK"
 (cd "build/ffmpeg-$SDK"
  "$SOURCE/configure" --prefix="$PREFIX" --cc="$(xcrun --sdk "$SDK" -f clang)" --ar="$(xcrun --sdk "$SDK" -f ar)" --ranlib="$(xcrun --sdk "$SDK" -f ranlib)" --target-os=darwin --arch="$ARCH" --enable-cross-compile --sysroot="$SDKROOT" --extra-cflags="-arch $ARCH $MIN -fPIC" --extra-ldflags="-arch $ARCH $MIN" --disable-x86asm --disable-everything --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-network --enable-small --enable-static --disable-shared --enable-avformat --enable-avcodec --enable-avutil --enable-demuxer=mpegts,mov --enable-muxer=mpegts --enable-decoder=aac --enable-encoder=aac --enable-parser=aac,h264,hevc --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
  make -j4
  make install)
done
cp "$SOURCE/COPYING.LGPLv2.1" Vendor/ffmpeg/

