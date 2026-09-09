#!/bin/sh

# 03-lambda-requisites.sh
#
# Install all packages required by lambda

. ./vind-config.sh
. ./vind-utils.sh

# env

unset CC CXX PREFIX DESTDIR HOST TOOLS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

export MARKERS="/building/markers"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/usr/lib/llvm/22/bin"
export CC=gcc
export CXX=g++
export CFLAGS="-I/usr/include"
export CPPFLAGS="-I/usr/include"
export LDFLAGS="-L/usr/lib"

# zlib

if [ ! -f "$MARKERS/.zlib_done" ]; then
    info "Building zlib"


    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf zlib-1.3.1.tar.gz || {
        error "Failed to extract zlib"
        exit 1
    }

    cd zlib-1.3.1 || {
        error "Failed to enter zlib source directory"
        exit 1
    }

    export CC=gcc || {
        error "Failed to export CC as gcc"
        exit 1
    }

    ./configure --prefix=/usr || {
        error "Failed to configure zlib"
        exit 1
    }

    make || {
        error "Failed to build zlib"
        exit 1
    }

    make install || {
        error "Failed to install zlib"
        exit 1
    }

    touch "$MARKERS/.zlib_done"
fi

# perl

if [ ! -f "$MARKERS/.perl_done" ]; then
    info "Building perl"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf perl-5.40.0.tar.gz || {
        error "Failed to extract perl"
        exit 1
    }

    cd perl-5.40.0 || {
        error "Failed to enter perl source directory"
        exit 1
    }

    ./Configure -des -Dprefix=/usr || {
        error "Failed to configure perl"
        exit 1
    }

    make || {
        error "Failed to build perl"
        exit 1
    }

    make install || {
        error "Failed to install perl"
        exit 1
    }

    touch "$MARKERS/.perl_done"
fi

# openssl

if [ ! -f "$MARKERS/.openssl_done" ]; then
    info "Building openssl"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf openssl-3.5.7.tar.gz || {
        error "Failed to extract openssl"
        exit 1
    }

    cd openssl-3.5.7 || {
        error "Failed to enter openssl source directory"
        exit 1
    }

    ./Configure linux-x86_64 \
        --prefix=/usr \
        --openssldir=/etc/ssl \
        --libdir=lib \
        shared || {
        error "Failed to configure openssl"
        exit 1
    }

    make || {
        error "Failed to build openssl"
        exit 1
    }

    make install || {
        error "Failed to install openssl"
        exit 1
    }

    mkdir -p /etc/ssl || {
        error "Failed to create SSL directory"
        exit 1
    }

    cp /usr/src/cacert.pem /etc/ssl/cert.pem || {
        error "Failed to install CA bundle"
        exit 1
    }

    touch "$MARKERS/.openssl_done"
fi

# curl

if [ ! -f "$MARKERS/.curl_done" ]; then
    info "Building curl"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf curl-8.11.0.tar.gz || {
        error "Failed to extract curl"
        exit 1
    }

    cd curl-8.11.0 || {
        error "Failed to enter curl source directory"
        exit 1
    }

    ./configure \
        --prefix=/usr \
        --with-openssl \
        --with-ca-bundle=/etc/ssl/cert.pem \
        --without-libpsl \
        --disable-docs \
        --without-ca-embed || {
        error "Failed to configure curl"
        exit 1
    }

    make || {
        error "Failed to build curl"
        exit 1
    }

    make install || {
        error "Failed to install curl"
        exit 1
    }

    touch "$MARKERS/.curl_done"
fi

# pkg-config

if [ ! -f "$MARKERS/.pkg-config_done" ]; then
    info "Building pkg-config"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf pkg-config-0.29.2.tar.gz || {
        error "Failed to extract pkg-config"
        exit 1
    }

    cd pkg-config-0.29.2 || {
        error "Failed to enter pkg-config source directory"
        exit 1
    }

    ./configure --prefix=/usr --with-internal-glib || {
        error "Failed to configure pkg-config"
        exit 1
    }

    make || {
        error "Failed to build pkg-config"
        exit 1
    }

    make install || {
        error "Failed to install pkg-config"
        exit 1
    }

    touch "$MARKERS/.pkg-config_done"
fi

# wget

if [ ! -f "$MARKERS/.wget_done" ]; then
    info "Building wget"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf wget-1.24.5.tar.gz || {
        error "Failed to extract wget"
        exit 1
    }

    cd wget-1.24.5 || {
        error "Failed to enter wget source directory"
        exit 1
    }

    ./configure --prefix=/usr --with-ssl=openssl || {
        error "Failed to configure wget"
        exit 1
    }

    make || {
        error "Failed to build wget"
        exit 1
    }

    make install || {
        error "Failed to install wget"
        exit 1
    }

    touch "$MARKERS/.wget_done"
fi

# jq

if [ ! -f "$MARKERS/.jq_done" ]; then
    info "Building jq"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf jq-1.7.1.tar.gz || {
        error "Failed to extract jq"
        exit 1
    }

    cd jq-1.7.1 || {
        error "Failed to enter jq source directory"
        exit 1
    }

    ./configure \
        --prefix=/usr \
        --with-oniguruma=builtin \
        --disable-maintainer-mode || {
        error "Failed to configure jq"
        exit 1
    }

    make || {
        error "Failed to build jq"
        exit 1
    }

    make install || {
        error "Failed to install jq"
        exit 1
    }

    touch "$MARKERS/.jq_done"
fi

# m4

if [ ! -f "$MARKERS/.m4_done" ]; then
    info "Building m4"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf m4-1.4.19.tar.xz || {
        error "Failed to extract m4"
        exit 1
    }

    cd m4-1.4.19 || {
        error "Failed to enter m4 source directory"
        exit 1
    }

    ./configure --prefix=/usr || {
        error "Failed to configure m4"
        exit 1
    }

    make || {
        error "Failed to build m4"
        exit 1
    }

    make install || {
        error "Failed to install m4"
        exit 1
    }

    touch "$MARKERS/.m4_done"
fi

# autoconf

if [ ! -f "$MARKERS/.autoconf_done" ]; then
    info "Building autoconf"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf autoconf-2.71.tar.xz || {
        error "Failed to extract autoconf"
        exit 1
    }

    cd autoconf-2.71 || {
        error "Failed to enter autoconf source directory"
        exit 1
    }

    ./configure --prefix=/usr || {
        error "Failed to configure autoconf"
        exit 1
    }

    make || {
        error "Failed to build autoconf"
        exit 1
    }

    make install || {
        error "Failed to install autoconf"
        exit 1
    }

    touch "$MARKERS/.autoconf_done"
fi

# git

if [ ! -f "$MARKERS/.git_done" ]; then
    info "Building git"

    cd "/usr/src" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf git-2.47.0.tar.xz || {
        error "Failed to extract git"
        exit 1
    }

    cd git-2.47.0 || {
        error "Failed to enter git source directory"
        exit 1
    }

    make configure || {
        error "Failed to generate git configure script"
        exit 1
    }

    ./configure --prefix=/usr --without-tcltk --disable-nls || {
        error "Failed to configure git"
        exit 1
    }

    make NO_GETTEXT=1 NO_TCLTK=1 || {
        error "Failed to build git"
        exit 1
    }

    make NO_GETTEXT=1 NO_TCLTK=1 install || {
        error "Failed to install git"
        exit 1
    }

    touch "$MARKERS/.git_done"
fi

info "lambda requisites finished."
