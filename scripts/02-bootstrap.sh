#!/bin/sh

source ./vind-config.sh
source ./vind-utils.sh

mkdir -p "$MARKERS" || {
    error "Failed to create markers directory"
    exit 1
}

# resolv.conf

if [ ! -f "$MARKERS/.resolv_done" ]; then
    info "Configuring resolv.conf"

    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    if [ $? -ne 0 ]; then
        error "Failed to configure resolv.conf"
        exit 1
    fi

    touch "$MARKERS/.resolv_done"
fi

# rootfs

if [ ! -f "$MARKERS/.rootfs_done" ]; then
    info "Creating rootfs"

    mkdir -pv "$VIND"/{etc,var} || {
        error "Failed to create rootfs directories"
        exit 1
    }

    mkdir -pv "$VIND"/var/tmp || {
        error "Failed to create /var/tmp"
        exit 1
    }

    mkdir -pv "$VIND"/usr/{bin,lib,sbin,include,share,src} || {
        error "Failed to create /usr directories"
        exit 1
    }

    for i in bin lib sbin; do
        ln -sv usr/"$i" "$VIND"/"$i" || {
            error "Failed to create /$i symlink"
            exit 1
        }
    done

    mkdir -pv "$VIND"/{dev,proc,sys,run,tmp,home,root,mnt,opt} || {
        error "Failed to create rootfs directories"
        exit 1
    }

    chmod 1777 "$VIND/tmp" || {
        error "Failed to chmod $VIND/tmp"
        exit 1
    }

    chmod 1777 "$VIND/var/tmp" || {
        error "Failed to chmod $VIND/var/tmp"
        exit 1
    }

    touch "$MARKERS/.rootfs_done"
fi

# musl-cross-make

if [ ! -f "$MARKERS/.musl-cross-make_done" ]; then
    info "Building musl-cross-make"

    mkdir -p "$VIND/tools-src" || {
        error "Failed to create tools-src"
        exit 1
    }

    cd "$VIND/tools-src" || {
        error "Failed to enter tools-src"
        exit 1
    }

    mv $SOURCES/musl-cross-make-sources/musl-cross-make . || {
        error "Failed to move musl-cross-make"
        exit 1
    }

    cd musl-cross-make || {
        error "Failed to enter musl-cross-make"
        exit 1
    }

    export TOOLS="$VIND/tools"

    cat > config.mak << EOF
TARGET = x86_64-pc-linux-musl
OUTPUT = $TOOLS
GCC_VER = 13.3.0
EOF

    if [ $? -ne 0 ]; then
        error "Failed to create config.mak"
        exit 1
    fi

    mkdir -p sources || {
        error "Failed to create sources directory"
        exit 1
    }

    mv $SOURCES/musl-cross-make-sources/* sources/ || {
        error "Failed to move musl-cross-make sources"
        exit 1
    }

    touch sources/* || {
        error "Failed to touch musl-cross-make sources"
        exit 1
    }

    make -j$(nproc) || {
        error "musl-cross-make build failed"
        exit 1
    }

    make install || {
        error "musl-cross-make installation failed"
        exit 1
    }

    ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ar" /usr/bin/ar || {
        error "Failed to create ar symlink"
        exit 1
    }

    ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ranlib" /usr/bin/ranlib || {
        error "Failed to create ranlib symlink"
        exit 1
    }

    ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-strip" /usr/bin/strip || {
        error "Failed to create strip symlink"
        exit 1
    }

    touch "$MARKERS/.musl-cross-make_done"
fi

# minimal system

mkdir -p "$VIND/sources" || {
    error "Failed to create sources directory"
    exit 1
}

# musl

if [ ! -f "$MARKERS/.musl_done" ]; then
    info "Building musl"

    mv $SOURCES/minimal-system/musl-1.2.5.tar.gz "$VIND/sources" || {
        error "Failed to move musl source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf musl-1.2.5.tar.gz || {
        error "Failed to extract musl"
        exit 1
    }

    cd musl-1.2.5 || {
        error "Failed to enter musl source directory"
        exit 1
    }

    ./configure --prefix="$PREFIX" --syslibdir="$PREFIX/lib" || {
        error "musl configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "musl build failed"
        exit 1
    }

    make DESTDIR="$DESTDIR" install || {
        error "musl installation failed"
        exit 1
    }

    touch "$MARKERS/.musl_done"
fi
