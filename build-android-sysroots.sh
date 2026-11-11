#!/bin/sh
#
# Creates the sysroots for the Android targets in TARGET_TRIPLES (<arch>-linux-android[eabi]<API>, e.g.
# aarch64-linux-android29 or armv7a-linux-androideabi21), so Android targets use the same clang, compiler-rt
# and libc++ as the other targets of this toolchain.
#
# Only bionic (headers, crt objects, libc/libm/libdl/liblog/... stubs) is taken from the NDK. The NDK's libc++,
# libc++abi, libunwind and compiler-rt are NOT used; build-compiler-rt.sh and build-libcxx.sh build them from
# ./llvm-project, and install-wrappers.sh installs the <triple>-clang etc. tools.
#
# The sysroot is <dest>/<triple>, so including the API level in the triple lets several API levels coexist.
# Note that below API 29 clang uses emulated TLS (__emutls_get_address) instead of ELF TLS.
#
# The NDK release ANDROID_NDK_VERSION (default r29) is downloaded from Google into CACHE_PATH, and only its sysroot
# is extracted. The sysroot is the same in every host package, so the Linux one is used on every host. To use a local
# NDK instead, set ANDROID_NDK to its directory.
#
# Usage: TARGET_TRIPLES="..." [ANDROID_NDK=/path/to/ndk] ./build-android-sysroots.sh dest

set -e

: ${ANDROID_NDK_VERSION:=r29}
: ${CACHE_PATH:="$PWD/cache"}

if [ $# -ne 1 ]; then
    echo "$0 dest"
    exit 1
fi

case $TARGET_TRIPLES in
*-linux-android*)
    ;;
*)
    echo "Nothing to build for android sysroots"
    exit 0
    ;;
esac

mkdir -p "$1"
PREFIX="$(cd "$1" && pwd)"

if [ -n "$ANDROID_NDK" ]; then
    # A local NDK: its sysroot is under the host's prebuilt directory
    NDK_SYSROOT=
    for dir in "$ANDROID_NDK"/toolchains/llvm/prebuilt/*/sysroot; do
        if [ -d "$dir" ]; then
            NDK_SYSROOT="$dir"
            break
        fi
    done
    if [ -z "$NDK_SYSROOT" ]; then
        echo "No NDK sysroot in $ANDROID_NDK/toolchains/llvm/prebuilt"
        exit 1
    fi
else
    ndk_name=android-ndk-$ANDROID_NDK_VERSION
    ndk_dir="$CACHE_PATH/$ndk_name"
    NDK_SYSROOT="$ndk_dir/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    if [ ! -d "$NDK_SYSROOT" ]; then
        mkdir -p "$CACHE_PATH"
        ndk_zip="$CACHE_PATH/$ndk_name-linux.zip"
        ndk_url="https://dl.google.com/android/repository/$ndk_name-linux.zip"
        # Downloaded to .part first, so that an interrupted download is not taken for a complete one
        if [ ! -f "$ndk_zip" ]; then
            echo "Downloading $ndk_url"
            wget -q -O "$ndk_zip.part" "$ndk_url"
            mv "$ndk_zip.part" "$ndk_zip"
        fi
        # Only the sysroot (about 300 MB of the NDK); extracted next to it, then moved, so that an interrupted
        # extraction is not taken for a complete one
        rm -rf "$ndk_dir.part"
        mkdir -p "$ndk_dir.part"
        unzip -q "$ndk_zip" "$ndk_name/source.properties" \
            "$ndk_name/toolchains/llvm/prebuilt/linux-x86_64/sysroot/*" -d "$ndk_dir.part"
        rm -rf "$ndk_dir"
        mv "$ndk_dir.part/$ndk_name" "$ndk_dir"
        rm -rf "$ndk_dir.part" "$ndk_zip"
    fi
fi
echo "Using the NDK sysroot $NDK_SYSROOT"

for target_triple in $TARGET_TRIPLES; do
    case $target_triple in
    *-linux-android*)
        ;;
    *)
        continue
        ;;
    esac

    # The NDK only has the libc.so/libm.so/... stubs per API level, so without one the targets cannot link
    android_api=${target_triple##*-android}
    android_api=${android_api#eabi}
    case $android_api in
    ''|*[!0-9]*)
        echo "$target_triple: Android triples need an API level, e.g. aarch64-linux-android29"
        exit 1
        ;;
    esac

    arch=$(expr match "$target_triple" '\([^-]*\)-.*')
    case $arch in
    arm|armv7|armv7a)
        ndk_triple=arm-linux-androideabi
        ;;
    *)
        ndk_triple=$arch-linux-android
        ;;
    esac

    sysroot="$PREFIX/$target_triple"
    echo "== $target_triple -> $sysroot"

    # Bionic only, without the NDK's C++ runtime. An existing sysroot is kept (it also holds the runtimes and
    # libraries installed later, e.g. LLVM and hwloc); CLEAN=1 recreates it.
    [ -z "$CLEAN" ] || rm -rf "$sysroot"
    if [ ! -d "$sysroot/usr/lib/$ndk_triple" ]; then
        mkdir -p "$sysroot/usr/lib"
        cp -a "$NDK_SYSROOT/usr/include" "$sysroot/usr/"
        rm -rf "$sysroot/usr/include/c++"
        # Relative, so the toolchain can be moved/packaged. The runtimes install to <sysroot>/include.
        [ -e "$sysroot/include" ] || ln -s usr/include "$sysroot/include"
        cp -a "$NDK_SYSROOT/usr/lib/$ndk_triple" "$sysroot/usr/lib/"
        find "$sysroot/usr/lib/$ndk_triple" \( -name 'libc++*' -o -name 'libstdc++*' -o -name 'libunwind*' \) -delete
        cp "$NDK_SYSROOT/NOTICE" "$sysroot/NOTICE.bionic"
    fi
done
