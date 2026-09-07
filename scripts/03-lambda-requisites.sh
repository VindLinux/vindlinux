#!/bin/sh

# 03-lambda-requisites.sh
#
# Install all packages required by lambda


# env

unset CC CXX PREFIX DESTDIR HOST TOOLS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

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
