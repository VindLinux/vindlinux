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

export TOOLS="$VIND/tools"

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

    mv "$SOURCES/musl-cross-make-sources/musl-cross-make" . || {
        error "Failed to move musl-cross-make"
        exit 1
    }

    cd musl-cross-make || {
        error "Failed to enter musl-cross-make"
        exit 1
    }

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

    mv "$SOURCES"/musl-cross-make-sources/* sources/ || {
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

export PREFIX=/usr
export DESTDIR="$VIND"
export CC="$TOOLS/bin/x86_64-pc-linux-musl-gcc"
export HOST=x86_64-pc-linux-musl
export MAKEOPTS=-j$(nproc)
export PATH="$TOOLS/bin:$PATH"

# musl

if [ ! -f "$MARKERS/.musl_done" ]; then
    info "Building musl"

    mv "$SOURCES/minimal-system/musl-1.2.5.tar.gz" "$VIND/sources" || {
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

# busybox

if [ ! -f "$MARKERS/.busybox_done" ]; then
    info "Building busybox"

    mv "$SOURCES/minimal-system/busybox-1.37.0.tar.bz2" "$VIND/sources" || {
        error "Failed to move busybox source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf busybox-1.37.0.tar.bz2 || {
        error "Failed to extract busybox"
        exit 1
    }

    cd busybox-1.37.0 || {
        error "Failed to enter busybox source directory"
        exit 1
    }

    make defconfig || {
        error "Failed to configure busybox"
        exit 1
    }

    sed -i \
        -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
        -e 's/^# CONFIG_ASH is not set/CONFIG_ASH=y/' \
        -e 's/^# CONFIG_SH_IS_ASH is not set/CONFIG_SH_IS_ASH=y/' \
        -e 's/^# CONFIG_AWK is not set/CONFIG_AWK=y/' \
        -e 's/^# CONFIG_SED is not set/CONFIG_SED=y/' \
        -e 's/^# CONFIG_TR is not set/CONFIG_TR=y/' \
        -e 's/^# CONFIG_EXPR is not set/CONFIG_EXPR=y/' \
        -e 's/^# CONFIG_CUT is not set/CONFIG_CUT=y/' \
        -e 's/^# CONFIG_SORT is not set/CONFIG_SORT=y/' \
        -e 's/^# CONFIG_HEAD is not set/CONFIG_HEAD=y/' \
        -e 's/^# CONFIG_TAIL is not set/CONFIG_TAIL=y/' \
        -e 's/^# CONFIG_WC is not set/CONFIG_WC=y/' \
        -e 's/^# CONFIG_NTPD is not set/CONFIG_NTPD=y/' \
        -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
        .config || {
        error "Failed to configure busybox options"
        exit 1
    }

    make clean || {
        error "Failed to clean busybox"
        exit 1
    }

    CC="$CC" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip \
    make $MAKEOPTS || {
        error "Busybox build failed"
        exit 1
    }

    mkdir -p "$VIND/usr/bin" || {
        error "Failed to create /usr/bin"
        exit 1
    }

    cp busybox "$VIND/usr/bin/busybox" || {
        error "Failed to install busybox"
        exit 1
    }

    chmod 755 "$VIND/usr/bin/busybox" || {
        error "Failed to chmod busybox"
        exit 1
    }

    cd "$VIND/usr/bin" || {
        error "Failed to enter /usr/bin"
        exit 1
    }

    for cmd in $(./busybox --list); do
        [ "$cmd" = "busybox" ] && continue

        ln -sf busybox "$cmd" || {
            error "Failed to create busybox symlink: $cmd"
            exit 1
        }
    done

    touch "$MARKERS/.busybox_done"
fi

# dash

if [ ! -f "$MARKERS/.dash_done" ]; then
    info "Building dash"

    mv "$SOURCES/minimal-system/dash-0.5.12.tar.gz" "$VIND/sources" || {
        error "Failed to move dash source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf dash-0.5.12.tar.gz || {
        error "Failed to extract dash"
        exit 1
    }

    cd dash-0.5.12 || {
        error "Failed to enter dash source directory"
        exit 1
    }

    ./configure --prefix="$PREFIX" --host="$HOST" || {
        error "dash configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "dash build failed"
        exit 1
    }

    make DESTDIR="$DESTDIR" install || {
        error "dash installation failed"
        exit 1
    }

    touch "$MARKERS/.dash_done"
fi

# flex

if [ ! -f "$MARKERS/.flex_done" ]; then
    info "Building flex"

    mv "$SOURCES/minimal-system/flex-2.6.4.tar.gz" "$VIND/sources" || {
        error "Failed to move flex source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf flex-2.6.4.tar.gz || {
        error "Failed to extract flex"
        exit 1
    }

    cd flex-2.6.4 || {
        error "Failed to enter flex source directory"
        exit 1
    }

    ac_cv_func_malloc_0_nonnull=yes \
    ac_cv_func_realloc_0_nonnull=yes \
    ./configure \
        --prefix="$PREFIX" \
        --host="$HOST" \
        --disable-static \
        --disable-nls \
        --docdir="$PREFIX/share/doc/flex-2.6.4" \
        --disable-bootstrap || {
        error "flex configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "flex build failed"
        exit 1
    }

    make DESTDIR="$DESTDIR" install || {
        error "flex installation failed"
        exit 1
    }

    ln -sv flex "$DESTDIR$PREFIX/bin/lex" || {
        error "Failed to create lex symlink"
        exit 1
    }

    ln -sv flex.1 "$DESTDIR$PREFIX/share/man/man1/lex.1" || {
        error "Failed to create lex man symlink"
        exit 1
    }

    touch "$MARKERS/.flex_done"
fi

# make

if [ ! -f "$MARKERS/.make_done" ]; then
    info "Building make"

    mv "$SOURCES/minimal-system/make-4.4.1.tar.gz" "$VIND/sources" || {
        error "Failed to move make source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf make-4.4.1.tar.gz || {
        error "Failed to extract make"
        exit 1
    }

    cd make-4.4.1 || {
        error "Failed to enter make source directory"
        exit 1
    }

    ./configure --prefix="$PREFIX" --host="$HOST" || {
        error "make configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "make build failed"
        exit 1
    }

    make DESTDIR="$DESTDIR" install || {
        error "make installation failed"
        exit 1
    }

    touch "$MARKERS/.make_done"
fi

# binutils

if [ ! -f "$MARKERS/.binutils_done" ]; then
    info "Building binutils"

    mv "$SOURCES/minimal-system/binutils-2.42.tar.xz" "$VIND/sources" || {
        error "Failed to move binutils source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf binutils-2.42.tar.xz || {
        error "Failed to extract binutils"
        exit 1
    }

    cd binutils-2.42 || {
        error "Failed to enter binutils source directory"
        exit 1
    }

    BUILD_TRIPLE=$(/usr/bin/gcc -dumpmachine)

    ./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" \
        --disable-multilib --disable-nls --disable-gprofng || {
        error "binutils configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "binutils build failed"
        exit 1
    }

    touch /tmp/binutils-marker

    make DESTDIR="$DESTDIR" install || {
        error "binutils installation failed"
        exit 1
    }

    mkdir -p "$VIND/var/log" || {
        error "Failed to create log directory"
        exit 1
    }

    find "$DESTDIR" \( -type f -o -type l \) -newer /tmp/binutils-marker \
        | sed "s|^$DESTDIR||" \
        > "$VIND/var/log/binutils.manifest" || {
        error "Failed to create binutils manifest"
        exit 1
    }

    touch "$MARKERS/.binutils_done"
fi

# linux headers

if [ ! -f "$MARKERS/.linux-headers_done" ]; then
    info "Installing Linux headers"

    mv "$SOURCES/minimal-system/linux-6.6.79.tar.xz" "$VIND/sources" || {
        error "Failed to move Linux source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf linux-6.6.79.tar.xz || {
        error "Failed to extract Linux"
        exit 1
    }

    cd linux-6.6.79 || {
        error "Failed to enter Linux source directory"
        exit 1
    }

    make headers_install ARCH=x86_64 INSTALL_HDR_PATH="$VIND/usr" || {
        error "Linux headers installation failed"
        exit 1
    }

    touch "$MARKERS/.linux-headers_done"
fi

# gcc pass 2

if [ ! -f "$MARKERS/.gcc-pass2_done" ]; then
    info "Building GCC pass 2"

    mv "$SOURCES/minimal-system/gcc-13.3.0.tar.xz" "$VIND/sources" || {
        error "Failed to move GCC source"
        exit 1
    }

    cd "$VIND/sources" || {
        error "Failed to enter sources directory"
        exit 1
    }

    tar -xf gcc-13.3.0.tar.xz || {
        error "Failed to extract GCC"
        exit 1
    }

    cd gcc-13.3.0 || {
        error "Failed to enter GCC source directory"
        exit 1
    }

    ./contrib/download_prerequisites || {
        error "Failed to download GCC prerequisites"
        exit 1
    }

    mkdir -p build-pass2 || {
        error "Failed to create GCC build directory"
        exit 1
    }

    cd build-pass2 || {
        error "Failed to enter GCC build directory"
        exit 1
    }

    BUILD_TRIPLE=$(/usr/bin/gcc -dumpmachine)

    CC_FOR_BUILD=/usr/bin/gcc \
    CC="$TOOLS/bin/x86_64-pc-linux-musl-gcc" \
    ../configure \
        --build="$BUILD_TRIPLE" \
        --host="$HOST" \
        --target="$HOST" \
        --prefix=/usr \
        --with-build-sysroot="$VIND" \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-bootstrap \
        --disable-libsanitizer || {
        error "GCC pass 2 configure failed"
        exit 1
    }

    make $MAKEOPTS || {
        error "GCC pass 2 build failed"
        exit 1
    }

    touch /tmp/gcc-pass2-marker

    make DESTDIR="$DESTDIR" install || {
        error "GCC pass 2 installation failed"
        exit 1
    }

    ln -sf gcc "$VIND/usr/bin/cc" || {
        error "Failed to create cc symlink"
        exit 1
    }

    ln -sf g++ "$VIND/usr/bin/c++" || {
        error "Failed to create c++ symlink"
        exit 1
    }

    mkdir -p "$VIND/var/log" || {
        error "Failed to create log directory"
        exit 1
    }

    find "$DESTDIR" \( -type f -o -type l \) -newer /tmp/gcc-pass2-marker \
        | sed "s|^$DESTDIR||" \
        > "$VIND/var/log/gcc-pass2.manifest" || {
        error "Failed to create GCC pass 2 manifest"
        exit 1
    }

    echo /usr/bin/cc  >> "$VIND/var/log/gcc-pass2.manifest"
    echo /usr/bin/c++ >> "$VIND/var/log/gcc-pass2.manifest"

    touch "$MARKERS/.gcc-pass2_done"
fi
