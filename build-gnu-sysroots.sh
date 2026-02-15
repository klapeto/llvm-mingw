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
: ${SYSROOTGEN_VERSION:="v1.0.5"}
: ${SYSROOTGEN_CHECKSUM:="5061221e2a3e5d591b005743bad8f8fa2bafbc4712922aee65d6c53160595fe8"}

if [ -n "$NO_SYSROOT_GEN" ]; then
    echo "Bypassing generating sysroot"
    exit 0
fi

if [ $# -ne 1 ]; then
    echo "$0 dest"
    exit 1
fi

PREFIX="$1"

case $TARGET_TRIPLES in
*-linux-gnu*)
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

if [ ! -f SysrootGenerator ] || [ ! -x SysrootGenerator ]; then
    wget -O SysrootGenerator "https://github.com/klapeto/SysrootGenerator/releases/download/${SYSROOTGEN_VERSION}/SysrootGenerator-linux-x86-64"
    echo "${SYSROOTGEN_CHECKSUM} ./SysrootGenerator" | sha256sum -c
    chmod +x ./SysrootGenerator
fi

[ -z "$CHECKOUT_ONLY" ] || exit 0

export PATH="$PREFIX/bin:$PATH"

packages="libc6-dev"
sysroot_args=""

if [ -n "$CLEAN" ]; then
    sysroot_args="$sysroot_args --purge"
else
    sysroot_args="$sysroot_args --store-install-state"
fi
for target_triple in $TARGET_TRIPLES; do
    sysroot=$PREFIX/$target_triple

    case $target_triple in
    aarch64-linux-gnu)
        deb_arch=arm64;
        ;;
    arm-linux-gnueabihf)
        deb_arch=armhf;
        ;;
    riscv64-linux-gnu)
        deb_arch=riscv64;
        ;;
    i[63]86-linux-gnu)
        deb_arch=i386
        ;;
    x86_64-linux-gnu)
        deb_arch=amd64
        ;;
    *)
        deb_arch=""
        continue
        ;;
    esac

    ./SysrootGenerator $sysroot_args \
        --path "$sysroot" \
        --arch "$deb_arch" \
        --distribution "$DEB_DISTRIBUTION" \
        --sources "$DEB_SOURCES" \
        --cache-path "$CACHE_PATH" \
        --packages="$packages"
done
