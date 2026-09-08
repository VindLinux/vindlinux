#!/bin/sh

# 04-install-lambda.sh
#
# Prepare system and install lambda

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

    touch "$MARKERS/.chroot_resolv_done"
fi

# prepare system

if [ ! -f "$MARKERS/.prepare_system_done" ]; then
    info "Preparing system"

    cd /usr/src || {
        error "Failed to enter sources directory"
        exit 1
    }

    if [ ! -d "lambda-manager" ]; then
        git clone https://github.com/VindLinux/lambda-manager || {
            error "Failed to clone lambda-manager"
            exit 1
        }
    fi

    if [ ! -d "packages" ]; then
        git clone https://github.com/VindLinux/packages || {
            error "Failed to clone packages repository"
            exit 1
        }
    fi

    cp packages/packages/* lambda-manager/packages/ || {
        error "Failed to copy packages to lambda"
        exit 1
    }

    cd lambda-manager || {
        error "Failed to enter lambda directory"
        exit 1
    }

    ./install.sh || {
        error "Failed to install lambda"
        exit 1
    }

    touch "$MARKERS/.prepare_system_done"
fi

# lambda configuration

if [ ! -f "$MARKERS/.lambda_config_done" ]; then
    info "Configuring lambda"

    mkdir -p /etc/lambda || {
        error "Failed to create lambda configuration directory"
        exit 1
    }

    cat > /etc/lambda/make.conf << 'EOF'
# Lambda build environment

export CC="gcc"
export CXX="g++"

export CFLAGS="-O2 -pipe -march=alderlake"
export CXXFLAGS="${CFLAGS}"

# Library and pkg-config paths.
# Some packages, such as util-linux, may install libraries and their
# pkg-config files under /usr/lib64 on x86_64. Include both /usr/lib
# and /usr/lib64 so the linker and pkg-config can locate them during
# builds, regardless of which directory provides the required files.
export LDFLAGS="-Wl,-O1 -L/usr/lib -L/usr/lib64"
export LIBRARY_PATH="/usr/lib:/usr/lib64"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib64/pkgconfig"

export PREFIX="/usr"

export MAKEOPTS="-j6"

# Xorg-specific build environment (used by packages/xorg-libs and any
# X11-related package).

export XORG_PREFIX="${PREFIX}"
export XORG_CONFIG="--prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static"
EOF

    if [ $? -ne 0 ]; then
        error "Failed to create lambda make.conf"
        exit 1
    fi

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

    cat > /etc/lambda/system.json << 'EOF'
{
  "packages": [
    "llvm",
    "clang-config"
  ]
}
EOF

    if [ $? -ne 0 ]; then
        error "Failed to create lambda system configuration"
        exit 1
    fi

    touch "$MARKERS/.lambda_config_done"
fi
