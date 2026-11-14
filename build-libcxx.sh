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
DEBUG_SYMBOLS=0
BUILD_TYPE=Release
ADDITIONAL_CFLAGS=""
ADDITIONAL_CFLAGS_SCRIPT=""

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
    elif [ "$1" = "--debug-symbols" ]; then
        DEBUG_SYMBOLS=1
        BUILD_TYPE=RelWithDebInfo
    elif [ "${1#--additional-cflags=}" != "$1" ]; then
        ADDITIONAL_CFLAGS="${1#*=}"
    elif [ "${1#--additional-cflags-script=}" != "$1" ]; then
        ADDITIONAL_CFLAGS_SCRIPT="${1#*=}"
    else
        PREFIX="$1"
    fi
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
    echo "$0 [--disable-shared] [--disable-static] [--enable-cfguard|--disable-cfguard] [--additional-cflags=flags] [--additional-cflags-script=script] dest"
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
    *-linux-*)
        target_system=Linux
        if [ "$DEBUG_SYMBOLS" = "0" ]; then
            init_flags="$ADDITIONAL_CFLAGS"
        else
            init_flags="-g3 $ADDITIONAL_CFLAGS"
        fi
        compiler_target=$target_arch-linux-$target_env
        sysroot="$PREFIX/$target_triple"
        ;;
    *-w64-mingw32*)
        target_system=Windows
        if [ "$DEBUG_SYMBOLS" = "0" ]; then
            init_flags="$CFGUARD_CFLAGS $ADDITIONAL_CFLAGS"
        else
            init_flags="$CFGUARD_CFLAGS -g3 -gcodeview $ADDITIONAL_CFLAGS"
        fi
        compiler_target=$target_arch-w64-windows-gnu
        sysroot=""
        ;;
    esac

    case $target_triple in
    *-linux-musl*)
        enable_musl=ON
        ;;
    *)
        enable_musl=OFF
        ;;
    esac

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

    # Android devices have no libc++.so/libunwind.so, so a shared build would make every binary linked with the
    # default -stdlib=libc++ depend on a library that has to be packaged with it. Link them statically instead.
    target_shared=$BUILD_SHARED
    target_static=$BUILD_STATIC
    case $target_triple in
    *-android*)
        target_shared=OFF
        target_static=ON
        ;;
    esac

    # Atomic helpers come from the compiler-rt builtins; don't let libc++ link
    # a libatomic that happens to exist in the sysroot.
    cmake \
        ${CMAKE_GENERATOR+-G} "$CMAKE_GENERATOR" \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
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
        -DLLVM_ENABLE_PIC=ON \
        -DLIBUNWIND_USE_COMPILER_RT=TRUE \
        -DLIBUNWIND_ENABLE_SHARED=$target_shared \
        -DLIBUNWIND_ENABLE_STATIC=$target_static \
        -DLIBCXX_HAS_MUSL_LIBC=$enable_musl \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_HAS_ATOMIC_LIB=OFF \
        -DLIBCXX_ENABLE_SHARED=$target_shared \
        -DLIBCXX_ENABLE_STATIC=$target_static \
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
        $additional_cmake_flags \
        ..

    cmake --build . ${CORES:+-j${CORES}}
    cmake --install .
    cd ..
done
