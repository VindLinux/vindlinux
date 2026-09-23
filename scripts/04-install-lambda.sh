#!/bin/sh

# 04-install-lambda.sh
#
# Prepare system and install lambda.

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

mkdir -p "$MARKERS" || {
    error "Failed to create markers directory"
    exit 1
}

# resolv.conf

if [ ! -f "$MARKERS/.chroot_resolv_done" ]; then
    info "Configuring resolv.conf"

    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    if [ $? -ne 0 ]; then
        error "Failed to configure resolv.conf"
        exit 1
    fi

    touch "$MARKERS/.chroot_resolv_done" || {
        error "Failed to create resolv.conf marker"
        exit 1
    }
fi

# lambda install 


if [ ! -f "$MARKERS/.lambda_install_done" ]; then
    info "Installing lambda"

    cd /sources/lambda-manager || {
        error "Failed to enter /sources/lambda-manager"
        exit 1
    }

    ./installer.sh || exit 1 # no message bc lambda already has error messages on installer

    touch "$MARKERS/.lambda_install_done" || {
        error "Failed to create lambda install marker"
        exit 1
    }
fi

# lambda configuration

if [ ! -f "$MARKERS/.lambda_config_done" ]; then
    info "Configuring lambda"

    mkdir -p /etc/lambda || {
        error "Failed to create lambda configuration directory"
        exit 1
    }

    sed -i -e 's/^export CC="clang"$/export CC="gcc"/' -e 's/^export CXX="clang++"$/export CXX="g++"/' /etc/lambda/make.conf || {
        error "Failed to switch compiler to GCC"
        exit 1
    }

    cat > /etc/ld-musl-x86_64.path << 'EOF'
/lib
/usr/local/lib
/usr/lib
/usr/lib64
EOF

    if [ $? -ne 0 ]; then
        error "Failed to create musl library path configuration"
        exit 1
    fi

    lambda mutate append llvm clang-config || {
        error "Failed to append clang-config and llvm to system"
    }

    touch "$MARKERS/.lambda_config_done" || {
        error "Failed to create lambda configuration marker"
        exit 1
    }
fi

info "install lambda finished."
