#!/bin/sh
#
# Copyright (c) 2020 Martin Storsjo
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

CFGUARD_CFLAGS="-mguard=cf"
DEBUG_SYMBOLS=0
BUILD_TYPE=Release
ADDITIONAL_CFLAGS=""
ADDITIONAL_CFLAGS_SCRIPT=""

while [ $# -gt 0 ]; do
    case "$1" in
    --enable-cfguard)
        CFGUARD_CFLAGS="-mguard=cf"
        ;;
    --disable-cfguard)
        CFGUARD_CFLAGS=
        ;;
    --debug-symbols)
        DEBUG_SYMBOLS=1
        BUILD_TYPE=RelWithDebInfo
        ;;
    --additional-cflags=*)
        ADDITIONAL_CFLAGS="${1#*=}"
        ;;
    --additional-cflags-script=*)
        ADDITIONAL_CFLAGS_SCRIPT="${1#*=}"
        ;;
    *)
        PREFIX="$1"
        ;;
    esac
    shift
done

if [ -n "$ADDITIONAL_CFLAGS_SCRIPT" ]; then
    if [ ! -x "$ADDITIONAL_CFLAGS_SCRIPT" ]; then
        echo "$ADDITIONAL_CFLAGS_SCRIPT is not executable"
        exit 1
    fi
    # The builds below change directory
    ADDITIONAL_CFLAGS_SCRIPT="$(cd "$(dirname "$ADDITIONAL_CFLAGS_SCRIPT")" && pwd)/$(basename "$ADDITIONAL_CFLAGS_SCRIPT")"
fi

if [ -z "$PREFIX" ]; then
    echo "$0 [--enable-cfguard|--disable-cfguard] [--additional-cflags=flags] [--additional-cflags-script=script] dest"
    exit 1
fi

mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

export PATH="$PREFIX/bin:$PATH"

: ${ARCHS:=${TOOLCHAIN_ARCHS-i686 x86_64 armv7 aarch64 arm64ec}}

if [ -n "$TARGET_TRIPLES" ]; then
    # using Triples, bypasses normal defaults
    ARCHS=""
fi

# append ARCHS if not reset
for arch in $ARCHS; do
    case $TARGET_TRIPLES in
        *$arch-w64-mingw32*) ;;
        *) TARGET_TRIPLES="$TARGET_TRIPLES $arch-w64-mingw32" ;;
    esac
done

if [ ! -d llvm-project/openmp ] || [ -n "$SYNC" ]; then
    CHECKOUT_ONLY=1 ./build-llvm.sh
fi

cd llvm-project/openmp

if command -v ninja >/dev/null; then
    CMAKE_GENERATOR="Ninja"
else
    : ${CORES:=$(nproc 2>/dev/null)}
    : ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
    : ${CORES:=4}

    case $(uname) in
    MINGW*)
        CMAKE_GENERATOR="MSYS Makefiles"
        ;;
    esac
fi

for target_triple in $TARGET_TRIPLES; do
      target_arch=$(expr match "$target_triple" '\(.*\)-.*-.*')
      case $target_triple in
      *-linux-*)
          target_system=Linux
          if [ "$DEBUG_SYMBOLS" = "0" ]; then
            init_flags="$ADDITIONAL_CFLAGS"
          else
            init_flags="-g3 $ADDITIONAL_CFLAGS"
          fi
          sysroot="$PREFIX/$target_triple"
          ;;
      *-w64-mingw32*)
          target_system=Windows
          if [ "$DEBUG_SYMBOLS" = "0" ]; then
            init_flags="$CFGUARD_CFLAGS $ADDITIONAL_CFLAGS"
          else
            init_flags="$CFGUARD_CFLAGS -g3 -gcodeview $ADDITIONAL_CFLAGS"
          fi
          sysroot=""
          ;;
      esac

    CMAKEFLAGS=""
    case $target_arch in
    x86_64)
        CMAKEFLAGS="$CMAKEFLAGS -DLIBOMP_ASMFLAGS=-m64"
        ;;
    arm64ec)
        # Not yet supported
        continue
        ;;
    esac

    [ -z "$CLEAN" ] || rm -rf build-$target_triple
    mkdir -p build-$target_triple
    cd build-$target_triple
    [ -n "$NO_RECONF" ] || rm -rf CMake*

    if [ -n "$ADDITIONAL_CFLAGS_SCRIPT" ]; then
        init_flags="$init_flags $("$ADDITIONAL_CFLAGS_SCRIPT" "$target_triple")"
    fi

    additional_cmake_flags=""
    case $target_triple in
    *-android*)
        # LLVM's CMake checks ANDROID_NATIVE_API_LEVEL, e.g. for _FILE_OFFSET_BITS=64 on 32-bit before API 24
        android_api=${target_triple##*-android}
        android_api=${android_api#eabi}
        additional_cmake_flags="-DANDROID=ON${android_api:+ -DANDROID_NATIVE_API_LEVEL=$android_api}"
        ;;
    esac

    cmake \
        ${CMAKE_GENERATOR+-G} "$CMAKE_GENERATOR" \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_INSTALL_PREFIX="$PREFIX/$target_triple" \
        -DCMAKE_C_COMPILER=$target_triple-clang \
        -DCMAKE_CXX_COMPILER=$target_triple-clang++ \
        -DCMAKE_RC_COMPILER=$target_triple-windres \
        -DCMAKE_ASM_MASM_COMPILER=llvm-ml \
        -DCMAKE_SYSTEM_NAME=$target_system \
        -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
        -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
        -DCMAKE_SYSROOT=$sysroot \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DLIBOMP_ENABLE_SHARED=TRUE \
        -DCMAKE_C_FLAGS_INIT="$init_flags" \
        -DCMAKE_CXX_FLAGS_INIT="$init_flags" \
        $additional_cmake_flags \
        $CMAKEFLAGS \
        ..
    cmake --build . ${CORES:+-j${CORES}}
    cmake --install .
    rm -f $PREFIX/$target_triple/bin/*iomp5md*
    rm -f $PREFIX/$target_triple/lib/*iomp5md*
    cd ..
done
