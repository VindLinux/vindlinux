#!/bin/sh

# 06-install-base-system.sh
#
# As the name suggests, it installs de base system and patches some recipes

. ./vind-config.sh

export MARKERS="/building/markers"

mkdir -p "$MARKERS" || {
    error "Failed to create markers directory"
    exit 1
}

# remove gcc pass 2

if [ ! -f "$MARKERS/.gcc_pass2_removed_done" ]; then
    xargs -a /var/log/gcc-pass2.manifest rm -f || {
        error "Failed to remove GCC pass 2 files"
        exit 1
    }

    rm -f /var/log/gcc-pass2.manifest || {
        error "Failed to remove GCC pass 2 manifest"
        exit 1
    }

    # gcc should no longer exist

    if which gcc >/dev/null 2>&1; then
        error "gcc is still present after GCC pass 2 removal"
        exit 1
    fi

    if gcc --version >/dev/null 2>&1; then
        error "gcc is still executable after GCC pass 2 removal"
        exit 1
    fi

    if ! clang --version >/dev/null 2>&1; then
        error "clang is not available"
        exit 1
    fi

    ln -sf clang /usr/bin/cc || {
        error "Failed to create cc symlink"
        exit 1
    }

    ln -sf clang /usr/bin/gcc || {
        error "Failed to create gcc symlink"
        exit 1
    }

    ln -sf clang++ /usr/bin/c++ || {
        error "Failed to create c++ symlink"
        exit 1
    }

    ln -sf clang++ /usr/bin/g++ || {
        error "Failed to create g++ symlink"
        exit 1
    }

    touch "$MARKERS/.gcc_pass2_removed_done" || {
        error "Failed to create GCC pass 2 marker"
        exit 1
    }
fi

# lambda system configuration

if [ ! -f "$MARKERS/.base_system_config_done" ]; then
    cat > /etc/lambda/system.json <<'EOF'
{
  "packages": [
    "clang-config",
    "busybox",
    "ln",
    "realpath",
    "diffutils",
    "libnl",
    "pkgconf",
    "libc++",
    "dhcpcd",
    "llvm",
    "cmake",
    "ninja",
    "m4",
    "iproute2",
    "kmod",
    "musl-obstack",
    "openssh",
    "sqlite3",
    "zstd",
    "efibootmgr",
    "curl",
    "popt",
    "dosfstools",
    "libelf",
    "musl-fts",
    "libffi",
    "efivar",
    "grub",
    "nghttp2",
    "libc++abi",
    "shadow",
    "make",
    "libpsl",
    "argp-standalone",
    "perl",
    "python",
    "setuptools",
    "meson",
    "kbd",
    "dracut",
    "ncurses",
    "dash",
    "iwd",
    "zlib",
    "eudev",
    "parted",
    "expat",
    "openssl",
    "readline",
    "libarchive",
    "gawk",
    "xz",
    "libuv",
    "autoconf",
    "automake",
    "libtool",
    "e2fsprogs",
    "gfetch",
    "ca-certificates",
    "dbus",
    "util-linux",
    "bash",
    "gzip",
    "tzdata"
  ]
}
EOF

    if [ $? -ne 0 ]; then
        error "Failed to create lambda system configuration"
        exit 1
    fi

    touch "$MARKERS/.base_system_config_done" || {
        error "Failed to create base system configuration marker"
        exit 1
    }
fi

# install base system

if [ ! -f "$MARKERS/.base_system_done" ]; then
    lambda reconcile || {
        error "Failed to reconcile base system"
        exit 1
    }

    touch "$MARKERS/.base_system_done" || {
        error "Failed to create base system marker"
        exit 1
    }
fi

info "install base system done"
