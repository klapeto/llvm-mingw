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

USE_CFLAGS="-g -O2 -mguard=cf"
DEBUG_SYMBOLS=0
ADDITIONAL_CFLAGS=""
ADDITIONAL_CFLAGS_SCRIPT=""

while [ $# -gt 0 ]; do
    case "$1" in
    --enable-cfguard)
        USE_CFLAGS="-g -O2 -mguard=cf"
        ;;
    --disable-cfguard)
        USE_CFLAGS="-g -O2"
        ;;
    --debug-symbols)
        DEBUG_SYMBOLS=1
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
unset CC

: ${CORES:=$(nproc 2>/dev/null)}
: ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
: ${CORES:=4}
: ${ARCHS:=${TOOLCHAIN_ARCHS-i686 x86_64 armv7 aarch64 arm64ec}}

if [ -n "$TARGET_TRIPLES" ]; then
    # using Triples, bypasses normal defaults
    ARCHS=""
    # append to ARCHS
    for target_triple in $TARGET_TRIPLES; do
        case $target_triple in
        *-w64-mingw32*)
            target_arch=$(expr match "$target_triple" '\(.*\)-.*-.*')
            # mingw32 and mingw32uwp triples of one arch share the build
            case " $ARCHS " in
            *" $target_arch "*) ;;
            *) ARCHS="$ARCHS $target_arch" ;;
            esac
        ;;
        *);;
        esac
    done
fi

if [ -z "$ARCHS" ]; then
    echo "No mingw32 libraries will be built"
    exit 0;
fi

if [ ! -d mingw-w64 ] || [ -n "$SYNC" ]; then
    CHECKOUT_ONLY=1 ./build-mingw-w64.sh
fi

MAKE=make
if command -v gmake >/dev/null; then
    MAKE=gmake
fi

if [ "$DEBUG_SYMBOLS" = "1" ]; then
    USE_CFLAGS="$USE_CFLAGS -g3 -gcodeview"
fi

# winstorecompat is only needed by UWP targets
LIBS="winpthreads"
if [ -n "$TARGET_TRIPLES" ]; then
    uwp_targets="$TARGET_TRIPLES"
else
    uwp_targets="${TARGET_OSES-${TOOLCHAIN_TARGET_OSES-mingw32 mingw32uwp}}"
fi
case "$uwp_targets" in
*mingw32uwp*)
    LIBS="$LIBS winstorecompat"
    ;;
esac

cd mingw-w64/mingw-w64-libraries
for lib in $LIBS; do
    cd $lib
    for arch in $ARCHS; do
        [ -z "$CLEAN" ] || rm -rf build-$arch
        mkdir -p build-$arch
        cd build-$arch
        arch_prefix="$PREFIX/$arch-w64-mingw32"

        this_cflags="$USE_CFLAGS $ADDITIONAL_CFLAGS"
        if [ -n "$ADDITIONAL_CFLAGS_SCRIPT" ]; then
            this_cflags="$this_cflags $("$ADDITIONAL_CFLAGS_SCRIPT" "$arch-w64-mingw32")"
        fi

        ../configure --host=$arch-w64-mingw32 --prefix="$arch_prefix" --libdir="$arch_prefix/lib" \
            --enable-silent-rules \
            CFLAGS="$this_cflags" \
            CXXFLAGS="$this_cflags"
        $MAKE -j$CORES
        $MAKE install
        cd ..
        mkdir -p "$arch_prefix/share/mingw32"
        install -m644 COPYING "$arch_prefix/share/mingw32/COPYING.${lib}.txt"
    done
    cd ..
done
