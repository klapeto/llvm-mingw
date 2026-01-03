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

: ${DEB_DISTRIBUTION:=noble}
: ${DEB_SOURCES:="https://archive.ubuntu.com/ubuntu/|main,universe https://ports.ubuntu.com/ubuntu-ports/|main,universe"}
: ${CACHE_PATH:="$PWD/cache"}

if [ $# -ne 1 ]; then
    echo "$0 dest"
    exit 1
fi

PREFIX="$1"

case $TARGET_TRIPLES in
*-linux-gnu)
    ;;
*)
    echo "Nothing to build for gnu sysroots"
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

if [ ! -f SysrootGenerator ]; then
    wget -O SysrootGenerator https://github.com/klapeto/SysrootGenerator/releases/download/v1.0.2/SysrootGenerator-linux-x86-64
    echo "d6d961cd59c01bf52d48176231641d9e4d3c55f95f0d2163cdbd646c7e0d526e ./SysrootGenerator" | sha256sum -c
    chmod +x ./SysrootGenerator
fi

[ -z "$CHECKOUT_ONLY" ] || exit 0

export PATH="$PREFIX/bin:$PATH"

packages="build-essential"
default_args="--cache-path=$CACHE_PATH --no-bins"

if [ -n "$CLEAN" ]; then
    default_args="$default_args --purge"
fi
for target_triple in $TARGET_TRIPLES; do
    sysroot=$PREFIX/$target_triple

    case $target_triple in
    aarch64-linux-gnu)
        deb_arch=arm64;
        ;;
    arm-linux-gnu)
        deb_arch=armhf;
        ;;
    riscv64-linux-gnu)
        deb_arch=riscv64;
        ;;
    i686-linux-gnu)
        deb_arch=i368
        ;;
    x86_64-linux-gnu)
        deb_arch=amd64
        ;;
    *)
        deb_arch=""
        continue
        ;;
    esac

    ./SysrootGenerator "$default_args" \
        --path="$sysroot" \
        --arch="$deb_arch" \
        --distribution="$DEB_DISTRIBUTION" \
        --sources="$DEB_SOURCES" \
        --packages="$packages" \
        --purge
done
