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

: ${LINUX_VERSION_TAG:=latest}
: ${MUSL_VERSION_TAG:=latest}

if [ $# -ne 1 ]; then
    echo "$0 dest"
    exit 1
fi

PREFIX="$1"

case $TARGET_TRIPLES in
*-linux-musl)
    ;;
*)
    echo "Nothing to build for musl sysroots"
    exit 0
    ;;
esac

if [ -z "$CHECKOUT_ONLY" ]; then
    if [ -z "$PREFIX" ]; then
        echo "$0 dest"
        exit 1
    fi

    mkdir -p "$PREFIX"
    PREFIX="$(cd "$PREFIX" && pwd)"
fi

if [ ! -d linux ]; then
    git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
    CHECKOUT=1
fi

if [ ! -d musl ]; then
    git clone https://git.musl-libc.org/git/musl
    CHECKOUT=1
fi

cd linux

if [ -n "$SYNC" ] || [ -n "$CHECKOUT" ]; then
    [ -z "$SYNC" ] || git fetch
    if [ $LINUX_VERSION_TAG != "latest" ]; then
        git checkout $LINUX_VERSION_TAG
    fi
fi

cd ../musl

if [ -n "$SYNC" ] || [ -n "$CHECKOUT" ]; then
    [ -z "$SYNC" ] || git fetch
    if [ $MUSL_VERSION_TAG != "latest" ]; then
        git checkout $MUSL_VERSION_TAG
    fi
fi

cd ..

[ -z "$CHECKOUT_ONLY" ] || exit 0

MAKE=make
if command -v gmake >/dev/null; then
    MAKE=gmake
fi

export PATH="$PREFIX/bin:$PATH"

unset CC

for target_triple in $TARGET_TRIPLES; do
    cd linux
    [ -z "$CLEAN" ] || $MAKE clean

    sysroot=$PREFIX/$target_triple
    mkdir -p "$sysroot/usr/lib" "$sysroot/usr/include"
    ln -sfn "usr/lib" "$sysroot/lib"
    ln -sfn "usr/include" "$sysroot/include"

    case $target_triple in
    aarch64-linux-*)
        linux_arch=arm64;
        ;;
    arm-linux-*)
        linux_arch=arm;
        ;;
    riscv64-linux-*)
        linux_arch=riscv;
        ;;
    i686-linux-*)
        linux_arch=x86
        ;;
    x86_64-linux-*)
        linux_arch=x86
        ;;
    *)
        linux_arch=""
        continue
        ;;
    esac
    $MAKE headers_install ARCH=$linux_arch INSTALL_HDR_PATH="$sysroot/usr"

    case $target_triple in
    *-linux-musl)
        cd ../musl
        [ -z "$CLEAN" ] || rm -rf build-$target_triple
        mkdir -p build-$target_triple
        cd build-$target_triple
        CC=${target_triple}-clang CROSS_COMPILE=${target_triple}- ../configure --host=${target_triple} --prefix="$sysroot/usr"
        $MAKE
        $MAKE install
        ;;
    *-linux-gnu)
        echo "We cannot build glibc to generate a sysroot. Please use alternative methods"
        ;;
    esac

    cd ..
done
