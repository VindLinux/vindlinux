#!/bin/sh

# 01-fetch-sources.sh
#
# Download ALL necessary packages.
# Existing packages are skipped.
# Interrupted downloads are resumed.

set -u

. ./vind-config.sh
. ./vind-utils.sh

# musl cross make

mkdir -p sources/musl-cross-make-sources || {
    error "Failed to create sources/musl-cross-make-sources"
    exit 1
}
cd sources/musl-cross-make-sources || {
    error "Failed to enter sources/musl-cross-make-sources"
    exit 1
}

wget -c \
    https://mirrors.edge.kernel.org/gnu/gcc/gcc-13.3.0/gcc-13.3.0.tar.xz \
    https://mirrors.edge.kernel.org/gnu/binutils/binutils-2.44.tar.gz \
    https://mirrors.edge.kernel.org/gnu/mpfr/mpfr-4.2.2.tar.xz \
    https://mirrors.edge.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz \
    https://mirrors.edge.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz \
    https://sources.voidlinux.org/musl-1.2.5/musl-1.2.5.tar.gz \
    https://ftp.barfooze.de/pub/sabotage/tarballs/linux-headers-4.19.88-2.tar.xz

git clone https://github.com/richfelker/musl-cross-make || {
    error "Failed to clone musl-cross-make"
    exit 1
}

cd ../.. || {
    error "Failed to return to sources directory"
    exit 1
}

mkdir -p sources/minimal-system || {
    error "Failed to create sources/minimal-system"
    exit 1
}

cd sources/minimal-system || {
    error "Failed to enter sources/minimal-system"
    exit 1
}

wget -c \
    https://sources.voidlinux.org/musl-1.2.5/musl-1.2.5.tar.gz \
    https://mirror.slackbuilds.org/slackware/slackware64-current/source/a/mkinitrd/busybox-1.37.0.tar.bz2 \
    http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.12.tar.gz \
    https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz \
    https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz \
    https://ftp.gnu.org/gnu/binutils/binutils-2.42.tar.xz \
    https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.79.tar.xz \
    https://ftp.gnu.org/gnu/gcc/gcc-13.3.0/gcc-13.3.0.tar.xz

# lambda prerequisites

mkdir -p "$VIND/usr/src" || {
    error "Failed to create $VIND/usr/src"
    exit 1
}
cd "$VIND/usr/src" || {
    error "Failed to enter $VIND/usr/src"
    exit 1
}

wget -c \
    https://zlib.net/fossils/zlib-1.3.1.tar.gz \
    https://www.cpan.org/src/5.0/perl-5.40.0.tar.gz \
    https://www.openssl.org/source/openssl-3.5.7.tar.gz \
    https://curl.se/ca/cacert.pem \
    https://curl.se/download/curl-8.11.0.tar.gz \
    https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz \
    https://ftp.gnu.org/gnu/wget/wget-1.24.5.tar.gz \
    https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz \
    https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.47.0.tar.xz \
    https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz \
    https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz
