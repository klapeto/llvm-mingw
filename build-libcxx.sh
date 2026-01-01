#!/bin/sh
#
# Copyright (c) 2018 Martin Storsjo
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

BUILD_STATIC=ON
BUILD_SHARED=ON
CFGUARD_CFLAGS="-mguard=cf"

while [ $# -gt 0 ]; do
    if [ "$1" = "--disable-shared" ]; then
        BUILD_SHARED=OFF
    elif [ "$1" = "--enable-shared" ]; then
        BUILD_SHARED=ON
    elif [ "$1" = "--disable-static" ]; then
        BUILD_STATIC=OFF
    elif [ "$1" = "--enable-static" ]; then
        BUILD_STATIC=ON
    elif [ "$1" = "--enable-cfguard" ]; then
        CFGUARD_CFLAGS="-mguard=cf"
    elif [ "$1" = "--disable-cfguard" ]; then
        CFGUARD_CFLAGS=
    else
        PREFIX="$1"
    fi
    shift
done
if [ -z "$PREFIX" ]; then
    echo "$0 [--disable-shared] [--disable-static] [--enable-cfguard|--disable-cfguard] dest"
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

if [ ! -d llvm-project/libunwind ] || [ -n "$SYNC" ]; then
    CHECKOUT_ONLY=1 ./build-llvm.sh
fi

cd llvm-project

cd runtimes

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
    [ -z "$CLEAN" ] || rm -rf build-$target_triple
    mkdir -p build-$target_triple
    cd build-$target_triple
    [ -n "$NO_RECONF" ] || rm -rf CMake*

    target_arch=$(expr match "$target_triple" '\(.*\)-.*-.*')
    target_env=$(expr match "$target_triple" '.*-.*-\(.*\)')
    case $target_triple in
    *-linux-gnu*)
        target_system=Linux
        init_flags=""
        compiler_target=$target_arch-linux-$target_env
        sysroot="$PREFIX/$target_triple"
        ;;
    *-w64-mingw32*)
        target_system=Windows
        init_flags="$CFGUARD_CFLAGS"
        compiler_target=$target_arch-w64-windows-gnu
        sysroot=""
        ;;
    esac

    cmake \
        ${CMAKE_GENERATOR+-G} "$CMAKE_GENERATOR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX/$target_triple" \
        -DCMAKE_C_COMPILER=$target_triple-clang \
        -DCMAKE_CXX_COMPILER=$target_triple-clang++ \
        -DCMAKE_CXX_COMPILER_TARGET=$compiler_target \
        -DCMAKE_SYSTEM_NAME=$target_system \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
        -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
        -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
        -DLIBUNWIND_USE_COMPILER_RT=TRUE \
        -DLIBUNWIND_ENABLE_SHARED=$BUILD_SHARED \
        -DLIBUNWIND_ENABLE_STATIC=$BUILD_STATIC \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_ENABLE_SHARED=$BUILD_SHARED \
        -DLIBCXX_ENABLE_STATIC=$BUILD_STATIC \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_LIBDIR_SUFFIX="" \
        -DLIBCXX_INCLUDE_TESTS=FALSE \
        -DLIBCXX_INSTALL_MODULES=ON \
        -DLIBCXX_INSTALL_MODULES_DIR="$PREFIX/share/libc++/v1" \
        -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE \
        -DCMAKE_SYSROOT=$sysroot \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_LIBDIR_SUFFIX="" \
        -DCMAKE_C_FLAGS_INIT="$init_flags" \
        -DCMAKE_CXX_FLAGS_INIT="$init_flags" \
        ..

    cmake --build . ${CORES:+-j${CORES}}
    cmake --install .
    cd ..
done
