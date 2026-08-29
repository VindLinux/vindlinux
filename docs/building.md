# How to Build Vind Linux

This guide builds Vind Linux from a live host, through a working `chroot`, up to a system that is ready to boot on its own. The build is split into two big stages:

- **Phase 1 — Bootstrap.** Cross-compile from the host just enough to get a working `chroot`: musl, a shell, and a compiler that *runs inside* musl. Everything here is built with `--host`/cross flags, which is exactly the kind of setup that produces confusing header/library mismatches (wrong `stdio.h`, wrong `vswprintf` prototype, etc.) — so we keep this phase as small as possible.

  Phase 1 itself builds two compilers, one after the other — this is where the **Pass 1** / **Pass 2** naming used later in this guide comes from:

  - **Pass 1** — a *cross*-compiler that runs on the host and targets musl (section 6). It's scaffolding only, never part of the final system, and can be deleted once Phase 1 is done.
  - **Pass 2** — a *native-target* compiler: still cross-built on the host, but linked against musl so it runs **inside** Vind Linux once you `chroot` in (section 8). This is the compiler Phase 2 starts with.

- **Phase 2 — Native.** `chroot` into Vind Linux and build everything else natively, with a plain `./configure && make && make install`. No cross flags, no `DESTDIR`, no host/target mismatches — this is where the bulk of the system gets built, including `lambda` (Vind Linux's package manager), LLVM/Clang, and eventually the bootloader.

  Phase 2 starts out compiling everything with the Pass 2 GCC from Phase 1. Once LLVM/Clang exists, Vind Linux switches its own build environment to Clang and removes GCC from the final system — GCC's only job is to bootstrap the rest of the toolchain, not to ship as part of it (see section 13).

Packages built by hand early in this guide get reinstalled through `lambda` once it exists, so the system ends up with a proper manifest instead of files dropped in by hand — see section 11 for how `lambda` itself gets built and used.

---

# Phase 1 — Bootstrap

## 1. Prepare the host

We use a Gentoo LiveGUI ISO as the host, since it ships with most tools we need.

## 2. Partition the disk

List your disks and find the target one:

```bash
livecd ~ # lsblk
NAME  MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
fd0     2:0    1    4K  0 disk
loop0   7:0    0    4G  1 loop /run/rootfsbase
sr0    11:0    1  4.2G  1 rom  /run/initramfs/live
vda   253:0    0   50G  0 disk   # <- target disk
```

Partition it:

```bash
livecd ~ # fdisk /dev/vda
```

Three partitions: EFI, swap, and one big Linux partition for everything else:

```text
Device        Start      End       Sectors Size Type
/dev/vda1      2048  2099199      2097152   1G EFI System
/dev/vda2   2099200 10487807      8388608   4G Linux swap
/dev/vda3  10487808 104857599    94369792  45G Linux filesystem
```

You can split `/home` into its own partition if you want. This guide uses one root partition.

## 3. Format the partitions

```bash
livecd ~ # mkfs.fat -F32 /dev/vda1
livecd ~ # mkfs.ext4 /dev/vda3
livecd ~ # mkswap /dev/vda2
```

## 4. Mount the target

```bash
export VIND=/mnt/vind

livecd ~ # mount --mkdir /dev/vda3 $VIND
livecd ~ # mount --mkdir /dev/vda1 $VIND/boot/efi
livecd ~ # swapon /dev/vda2
```

## 5. Create the base rootfs layout

(Adapted from LFS.)

```bash
mkdir -pv "$VIND"/{etc,var}
mkdir -pv "$VIND"/usr/{bin,lib,sbin,include,share,src}

for i in bin lib sbin; do
    ln -sv usr/"$i" "$VIND"/"$i"
done

mkdir -pv "$VIND"/{dev,proc,sys,run,tmp,home,root,mnt,opt}
chmod 1777 "$VIND/tmp"
```

This is an empty skeleton. Before we can `chroot` into it, we need a compiler.

**No `/lib64`.** Unlike glibc-based LFS builds, Vind Linux does not create a
`/lib64` directory or symlink at any point. `/lib64` exists on glibc distros
because glibc's ELF interpreter path is hardcoded to
`/lib64/ld-linux-x86-64.so.2`, true even on non-multilib glibc systems — it's
an artifact of glibc's ABI, not of running 64-bit code. musl has no such
convention: its dynamic loader is installed at `/usr/lib/ld-musl-x86_64.so.1`
(section 7.1), and every compiler, linker, and library built in this guide
(sections 6–8) is built against `/usr/lib`, never `/lib64`. Since Vind Linux is
also explicitly non-multilib (no 32-bit compat libraries), there is nothing
for a `/lib64` directory — real or symlinked — to hold.

Leaving `/lib64` out entirely, rather than creating it empty, matters
downstream: some upstream `Configure`/`configure` scripts (OpenSSL's `Configure
linux-x86_64` target is the case this guide hits, in section 10.1) default to
a `lib64`-based install path purely because their target name implies a
multiarch/glibc convention — not because they inspected the filesystem. If an
empty `/lib64` existed, it would be exactly the kind of silently-writable
location where a package's own default assumption and the system's real
layout diverge without either side raising an error. Those packages still
need their own explicit `--libdir=lib` (or equivalent) to install to the
right place — that's a property of each package's own defaults, not a rootfs
workaround — but there is now no directory for a misconfigured build to fall
back into unnoticed.

## 6. Pass 1 — cross-toolchain (temporary, host-only)

Everything installed into `$VIND` during this phase needs to link against musl, not glibc (which the Gentoo host uses). So we need a compiler that runs on the host but produces musl binaries. That's a cross-toolchain, and we build it once with [musl-cross-make](https://github.com/richfelker/musl-cross-make).

This toolchain is scaffolding, not part of the final system, it exists only to get us to a working `chroot` (section 9). Once we're inside the chroot building natively, we never touch it again, and it can be deleted entirely afterward.

Build it inside `$VIND`, not on the live ISO's own disk. The live ISO's root filesystem is usually a small RAM-backed overlay, and a full gcc build writes several gigabytes of files while it works, we woudl get out of space partway through if built there. `$VIND` is our real 45G disk, so that's where the whole build happens.

```bash
mkdir -p "$VIND/tools-src"
cd "$VIND/tools-src"
git clone https://github.com/richfelker/musl-cross-make
cd musl-cross-make
```

Check free space before starting:

```bash
df -h $VIND
```

Configure it:

```bash
export TOOLS="$VIND/tools"

cat > config.mak << EOF
TARGET = x86_64-pc-linux-musl
OUTPUT = $TOOLS
GCC_VER = 13.3.0
EOF
```

If your host has a broken or non-routable IPv6 setup (common on cloud/VM images — see the FAQ), also add a line forcing downloads over IPv4, since `musl-cross-make` fetches its sources itself during `make`:

```bash
echo 'DL_CMD = wget -4 -c -O' >> config.mak
```

- `TARGET` uses the `pc` triple to match LFS-style naming, and it's the name we use to call the compiler everywhere else in this guide.
- `OUTPUT` goes to `$TOOLS` (`$VIND/tools`), not `$VIND/usr`. This toolchain is a build tool, stays in its own folder, and can be deleted entirely once we're done — same idea as LFS's `$LFS/tools`.
- `GCC_VER` is pinned to a modern release instead of `musl-cross-make`'s old default (9.4.0), mainly for general compiler quality, and it does **not**, on its own, avoid the musl/`libstdc++` wide-char issue described in the FAQ. That issue is a header-level incompatibility, not a version issue, and it's one more reason C++-heavy builds (like LLVM) are deferred to Phase 2 instead of being cross-built here.

Build and install:

```bash
make -j$(nproc)
make install
```

This builds binutils, a bootstrap gcc, musl, then the final gcc linked against musl. If a previous attempt failed partway through, run `rm -rf build` before retrying.

Put it on your `PATH`:

```bash
export PATH="$TOOLS/bin:$PATH"
```

You'll need to re-run this in any new shell for the rest of Phase 1.

Check it works:

```bash
x86_64-pc-linux-musl-gcc -dumpmachine
# should print: x86_64-pc-linux-musl
```

Compile a test program and confirm it links against musl:

```bash
cat > /tmp/hello.c << 'EOF'
#include <stdio.h>
int main(void) {
    printf("hello from musl\n");
    return 0;
}
EOF

x86_64-pc-linux-musl-gcc -static -o /tmp/hello /tmp/hello.c
/tmp/hello
file /tmp/hello
```

It should not mention `dynamically linked, interpreter /lib64/ld-linux...` — that line means glibc.

Point the host's plain `ar`, `ranlib`, and `strip` at the toolchain's versions, since later builds expect those names on `PATH` without a target prefix:

```bash
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ar"     /usr/bin/ar
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ranlib" /usr/bin/ranlib
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-strip"  /usr/bin/strip
```

## 7. Cross-build the minimal target system

This is deliberately short: just enough packages, cross-built with the Pass 1 toolchain, to get musl, a shell, basic coreutils, and `make` onto disk so we can `chroot` in and build natively.

```bash
mkdir -pv $VIND/sources
export PREFIX=/usr
export DESTDIR="$VIND"
export CC="$TOOLS/bin/x86_64-pc-linux-musl-gcc"
export HOST=x86_64-pc-linux-musl
export MAKEOPTS=-j$(nproc)
export PATH="$TOOLS/bin:$PATH"
```

If you open a new shell partway through this section, re-export these — otherwise builds silently fall back to the host's own glibc compiler instead of failing loudly.

### 7.1 musl

The C library itself — what every dynamically-linked binary in `$VIND` loads at runtime. Its `configure` script is custom (not autoconf-generated), so it doesn't take `--host`.

```bash
cd "$VIND/sources"
curl -fL --retry 3 --retry-delay 2 -o musl-1.2.5.tar.gz https://musl.libc.org/releases/musl-1.2.5.tar.gz
tar -xf musl-1.2.5.tar.gz
cd musl-1.2.5

./configure --prefix="$PREFIX" --syslibdir="$PREFIX/lib"
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

`--syslibdir` is where the dynamic loader (`ld-musl-x86_64.so.1`) gets installed — `$PREFIX/lib`, i.e. `/usr/lib` inside `$VIND`.

Verify:

```bash
find "$VIND" -name 'ld-musl-x86_64.so.1'
```

Should list a file inside `$VIND/usr/lib`. If nothing shows up, dynamically-linked binaries won't run once you `chroot` — see the FAQ.

### 7.2 Busybox

#### Download

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o busybox-1.37.0.tar.bz2 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2

tar -xf busybox-1.37.0.tar.bz2
cd busybox-1.37.0
```

#### Configure

```bash
make defconfig

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
    -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
    .config

make clean
```

#### Build

```bash
CC="$CC" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip \
make $MAKEOPTS
```

Don't pass `--sysroot` here (an earlier draft of this section set `CFLAGS='--sysroot=/' LDFLAGS='--sysroot=/'`). The Pass 1 cross-compiler from section 6 already defaults to its own bundled musl sysroot — that's the entire point of building it with `musl-cross-make`. Overriding it to `--sysroot=/` points the compiler at the **host's** root filesystem instead, i.e. Gentoo's own glibc headers under `/usr/include`, which is exactly the kind of host/target header mismatch section 6 warns about. Busybox is statically linked (`CONFIG_STATIC=y`), so this wouldn't necessarily fail loudly — it can silently pick up glibc struct layouts/macros at compile time while still linking against musl's `crt`/`libc.a`, producing a binary that builds cleanly but misbehaves at runtime. Leave `CFLAGS`/`LDFLAGS` unset and let the cross-compiler use its own default sysroot.

#### Install

```bash
mkdir -p "$VIND/usr/bin"
cp busybox "$VIND/usr/bin/busybox"
chmod 755 "$VIND/usr/bin/busybox"

cd "$VIND/usr/bin"
for cmd in $(./busybox --list); do
    [ "$cmd" = "busybox" ] && continue
    ln -sf busybox "$cmd"
done
```

### 7.3 dash

Small, fast POSIX-compliant shell derived from ash. Used as a lightweight `/bin/sh`.

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o dash-0.5.12.tar.gz \
    http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.12.tar.gz

tar -xf dash-0.5.12.tar.gz
cd dash-0.5.12

./configure --prefix="$PREFIX" --host="$HOST"
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

Verify:

```bash
file "$VIND/bin/dash"
```

Should show `interpreter /lib/ld-musl-x86_64.so.1` (dynamic musl) or no interpreter at all (static) — never `/lib64/ld-linux...` (glibc).

### 7.4 flex

Fast lexical analyzer generator. Required as a bootstrap tool for building packages such as Bison and other parser/lexer generators. 2.6.4 (2017) is still upstream's latest tagged release — there is no newer version to move to.

Flex 2.6.4 requires an existing `flex` executable during `configure`, so the host's `flex` is used only to bootstrap the Vind Linux copy.

**Cross-compiled flex 2.6.4 segfaults on any real input — this needs two `ac_cv_func_*` overrides, not just a plain `./configure`.** With `--host` set, `configure` cannot run a test binary on the build host to check whether `malloc(0)`/`realloc(p, 0)` behave the GNU-compatible way (returning a unique non-NULL pointer instead of `NULL`). Unable to run the check, it assumes the conservative "no" and falls back to gnulib's `rpl_malloc`/`rpl_realloc` wrappers — visible afterward as `HAVE_MALLOC 0` / `HAVE_REALLOC 0` and `#define malloc rpl_malloc` / `#define realloc rpl_realloc` in `config.h`. musl's `malloc`/`realloc` are already GNU-compatible here, so the fallback isn't just unnecessary, it's actively broken: the generated `scan.c` includes `<stdlib.h>` (which musl's headers pull in transitively) *before* `config.h` defines those macros, so `rpl_malloc`/`rpl_realloc` get called with no visible prototype in scope. GCC treats them as implicitly returning `int`, truncates the real 64-bit pointer they return down to 32 bits, and the corrupted pointer segfaults the moment flex actually allocates a scanner buffer — i.e. the instant it processes a real `.l` file, while `--version`/`--help` never touch that code path and look fine. This is a long-standing upstream bug ([flex#247](https://github.com/westes/flex/issues/247), [flex#436](https://github.com/westes/flex/issues/436)) that was never patched into the 2.6.4 tarball. Rather than patch flex's source, tell `configure` the true, correct answer for musl directly so it skips the substitution entirely:

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o flex-2.6.4.tar.gz \
    https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz

tar -xf flex-2.6.4.tar.gz
cd flex-2.6.4

ac_cv_func_malloc_0_nonnull=yes \
ac_cv_func_realloc_0_nonnull=yes \
./configure \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --disable-static \
    --disable-nls \
    --docdir="$PREFIX/share/doc/flex-2.6.4" \
    --disable-bootstrap

make $MAKEOPTS

make DESTDIR="$DESTDIR" install

ln -sv flex "$DESTDIR$PREFIX/bin/lex"
ln -sv flex.1 "$DESTDIR$PREFIX/share/man/man1/lex.1"
```

`--disable-bootstrap` is upstream's own escape hatch for exactly this situation (cross-compiling flex to build flex): without it, `configure` tries to run a freshly-built `stage1flex` on the build host to regenerate `scan.c`, which fails outright since that binary targets musl, not the host. With it, the pre-generated `scan.c` shipped in the tarball is used as-is — this only works because it's a *release* tarball (not a `git` checkout), which is why this guide pins a release rather than cloning `master`.

Verify:

```bash
file "$VIND$PREFIX/bin/flex"
```

Should show `interpreter /lib/ld-musl-x86_64.so.1` (dynamic musl) or no interpreter at all (static) — never `/lib64/ld-linux...` (glibc).

Verify the bootstrap installation — with a real `.l` file, not just `--version`, since that's the only thing that actually exercises the code path the fix above targets:

```bash
"$VIND$PREFIX/bin/flex" --version
"$VIND$PREFIX/bin/lex" --version

printf '%%%%\n.    ECHO;\n%%%%\n' > /tmp/min.l
"$VIND$PREFIX/bin/flex" -o /tmp/min.c /tmp/min.l && echo OK
```

If this still segfaults, check `config.h` in the build tree for `#define malloc rpl_malloc` — its presence means the `ac_cv_func_*` overrides above weren't picked up (a stale `config.cache` from an earlier attempt is the usual cause; `rm -f config.cache` and reconfigure).

The resulting `flex` and `lex` binaries belong to the Vind Linux toolchain and can be used by subsequent package builds.

### 7.5 make

GNU Make. Needed to build anything with a `Makefile` — including everything in Phase 2 — so it has to exist inside `$VIND` before we `chroot` in.

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o make-4.4.1.tar.gz \
    https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz

tar -xf make-4.4.1.tar.gz
cd make-4.4.1

./configure --prefix="$PREFIX" --host="$HOST"
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

Verify:

```bash
file "$VIND/usr/bin/make"
```

Same check as before — should show `ld-musl-x86_64.so.1`, not glibc.

### 7.6 binutils

`as` (assembler) and `ld` (linker) — `gcc` doesn't do either of these itself, it shells out to these two. The Pass 1 toolchain has its own copy, but that copy is a **host** binary (runs on glibc, targets musl) — useless once you're inside the chroot, where there's no glibc runtime to run it at all. This one needs to be a musl binary too, cross-built the same way as `make` above, so it actually runs natively inside `$VIND`.

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o binutils-2.42.tar.xz \
    https://ftp.gnu.org/gnu/binutils/binutils-2.42.tar.xz

tar -xf binutils-2.42.tar.xz
cd binutils-2.42

BUILD_TRIPLE=$(/usr/bin/gcc -dumpmachine)

./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" \
    --disable-multilib --disable-nls --disable-gprofng
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

`--disable-gprofng` skips `gprofng`, a statistical profiler bundled with binutils since 2.38. It doesn't build against musl — it uses `fopen64`/`fseeko64`/`ftello64`, glibc-specific large-file-support functions that musl never needed (musl is 64-bit-only everywhere, so it has no separate `*64` variants to begin with). It's not part of the core toolchain (`ar`, `as`, `ld`, `nm`, `ranlib`, `strip` all build fine without it), so this is the standard fix other musl-based distros use too, rather than patching gprofng's source.

`binutils` is a multi-directory project (`gas`, `libiberty`, `zlib`, `libsframe`, ...), and each subdirectory runs its own `configure`, each doing its own `--build` auto-detection independently. Since `$PATH`/`$CC` are already biased toward the musl cross-compiler at this point (section 7's exports), that auto-detection gets confused for some of these subdirectories — same root cause as the `--build` issue explained in section 8. Passing `--build` explicitly here sidesteps it for all of them at once, rather than letting each subdirectory guess on its own.

Verify:

```bash
file "$VIND/usr/bin/as" "$VIND/usr/bin/ld"
```

Both should show `ld-musl-x86_64.so.1`, not glibc — and definitely not the host's binutils under `$TOOLS`.

This has to be done before entering the chroot (section 9) — without it, `gcc` inside the chroot can produce assembly but has nothing to turn it into an actual object file, which is exactly the `cannot execute 'as'` error you get if this step is skipped.

### 7.7 Linux kernel headers

`musl` (section 7.1) is the C library, but it doesn't bundle the full Linux UAPI header surface — `linux/*.h`, `asm/*.h`, `asm-generic/*.h`. On a glibc-based host these normally come from a separate `linux-headers` package that the distro already has installed alongside glibc; nothing in this guide has installed the equivalent into `$VIND` yet. Most of what's built so far doesn't need them, but some packages later (OpenSSL's secure-heap code in particular, which reaches for `linux/mman.h`) do, and the failure if this step is skipped is a plain `fatal error: linux/mman.h: No such file or directory` deep inside a Phase 2 build — by which point there's no `curl` yet inside the chroot to fetch the fix. Do it now, from the host, the same way `musl` itself was populated into the sysroot:

```bash
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 -o linux-6.6.79.tar.xz \
    https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.79.tar.xz
tar -xf linux-6.6.79.tar.xz
cd linux-6.6.79

make headers_install ARCH=x86_64 INSTALL_HDR_PATH="$VIND/usr"
```

`headers_install` is the kernel's own target for producing the sanitized, userspace-safe subset of its headers (stripping out kernel-internal-only bits) — it's not something to hand-copy from `include/` directly. It only needs a working host `gcc`/`make` (already present on the Gentoo LiveGUI host) to build a couple of small host-side helper tools (`unifdef`, `fixdep`); it doesn't touch the musl cross-compiler or `$VIND`'s own toolchain at all. `INSTALL_HDR_PATH="$VIND/usr"` lands everything at `$VIND/usr/include/{linux,asm,asm-generic,...}` — i.e. plain `/usr/include/...` once you're inside the chroot, exactly where `gcc`'s default search path already looks.

The exact kernel version pinned here isn't load-bearing — UAPI headers are stable and backward-compatible by policy, so any reasonably recent release works; this doesn't need to track the version of anything else in this guide.

Verify:

```bash
find "$VIND/usr/include/linux" -name mman.h
```

Should print a path inside `$VIND/usr/include/linux`. If it doesn't, OpenSSL's build in section 10.1 will fail with `fatal error: linux/mman.h: No such file or directory` partway through — see the FAQ.

## 8. Pass 2 — native-target GCC (built on the host)

This is the step that lets us stop cross-compiling. We use the Pass 1 toolchain (still running on the host) to build *another* GCC — one that, once built, is itself a musl binary that runs **inside** Vind Linux. That compiler is what we'll use natively after `chroot`.

This is a "cross-native" build: `--build` is the host triple, `--host` and `--target` are both the musl triple. It's a standard pattern (Cross-LFS uses the same approach for glibc).

`configure` can't be trusted to detect `--build` on its own here: by this point `$CC` and `$PATH` are set up (from section 7) to favor the musl cross-compiler, so `config.guess`'s auto-detection — and even `configure`'s own default choice of compiler for build-time tools — end up pointing at the musl compiler instead of the host's real glibc `gcc`. That produces `checking build system type... x86_64-pc-linux-musl` (wrong) and later `cannot run C compiled programs`, since the live ISO can't execute musl binaries directly. Passing the build triple and `CC_FOR_BUILD` explicitly sidesteps the auto-detection entirely:

```bash
cd "$VIND/sources"
curl -fL --retry 3 --retry-delay 2 -o gcc-13.3.0.tar.xz https://ftp.gnu.org/gnu/gcc/gcc-13.3.0/gcc-13.3.0.tar.xz
tar -xf gcc-13.3.0.tar.xz
cd gcc-13.3.0

# Bundles gmp, mpfr, mpc, isl into the source tree so they get statically
# linked into the compiler — this compiler needs to run on a bare system
# that has none of these installed yet.
./contrib/download_prerequisites

mkdir -p build-pass2 && cd build-pass2

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
    --disable-libsanitizer

make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

- `/usr/bin/gcc -dumpmachine` (absolute path) gives the real host triple without going through `config.guess`, which is unreliable here since the shell environment is deliberately biased toward the cross-compiler.
- `CC_FOR_BUILD=/usr/bin/gcc` makes sure the build-time tools (which run *now*, on the live ISO) use the host's native compiler — only the final target compiler uses the musl cross-compiler.
- `--with-build-sysroot="$VIND"` tells this GCC where to find musl's headers and libs (already installed in section 7.1) while it's being built on the host. This is different from `--with-sysroot`, which would bake that same absolute host path (`$VIND`, e.g. `/mnt/vind`) into the compiler as its permanent default — breaking it the moment you `chroot` in, since that path stops meaning anything once `$VIND` becomes `/`. `--with-build-sysroot` only affects this build; the resulting compiler defaults to sysroot `/`, which is exactly right once it's running natively inside the chroot.
- `--disable-bootstrap` skips GCC's usual 3-stage self-bootstrap, which doesn't apply here since we're cross-building it once.

Verify the result is actually a musl binary meant to run inside the chroot, not the host:

```bash
file "$VIND/usr/bin/gcc"
```

A lot of build systems (`configure` scripts especially) look for a compiler named plain `cc`/`c++`, not `gcc`/`g++` specifically. Symlink those now, still from the host, so anything expecting the generic names finds them once you're inside the chroot:

```bash
ln -sf gcc "$VIND/usr/bin/cc"
ln -sf g++ "$VIND/usr/bin/c++"
```

---

# Phase 2 — Native builds inside the chroot

## 9. Enter the chroot

### 9.1 Pre-fetch what lambda's prerequisites need

Before entering the chroot, there's a chicken-and-egg problem worth heading off: section 10.1 builds `zlib`, `perl`, `openssl`, `curl`, `wget`, `jq`, and `git` *inside* the chroot, but their recipes use `curl` to download the source — and `curl` doesn't exist yet in there. Nothing inside a fresh chroot can reach the network at all.

Fetch these now, from the host (which already has `curl` and a trusted set of CA certificates), straight into `$VIND` — since `$VIND` becomes `/` once you're inside the chroot, anything you put here now is just there waiting for you:

```bash
mkdir -p "$VIND/usr/src"
cd "$VIND/usr/src"

curl -fL --retry 3 --retry-delay 2 -o zlib-1.3.1.tar.gz \
    https://zlib.net/fossils/zlib-1.3.1.tar.gz
curl -fL --retry 3 --retry-delay 2 -o perl-5.40.0.tar.gz \
    https://www.cpan.org/src/5.0/perl-5.40.0.tar.gz
curl -fL --retry 3 --retry-delay 2 -o openssl-3.5.7.tar.gz \
    https://www.openssl.org/source/openssl-3.5.7.tar.gz
curl -fL --retry 3 --retry-delay 2 -o cacert.pem \
    https://curl.se/ca/cacert.pem
curl -fL --retry 3 --retry-delay 2 -o curl-8.11.0.tar.gz \
    https://curl.se/download/curl-8.11.0.tar.gz
curl -fL --retry 3 --retry-delay 2 -o pkg-config-0.29.2.tar.gz \
    https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
curl -fL --retry 3 --retry-delay 2 -o wget-1.24.5.tar.gz \
    https://ftp.gnu.org/gnu/wget/wget-1.24.5.tar.gz
curl -fL --retry 3 --retry-delay 2 -o jq-1.7.1.tar.gz \
    https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz
curl -fL --retry 3 --retry-delay 2 -o git-2.47.0.tar.xz \
    https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.47.0.tar.xz
curl -fL --retry 3 --retry-delay 2 -o gettext-0.22.5.tar.gz \
    https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.gz
```

Verify each archive is actually intact before moving on. This matters more than it looks: a flaky mirror (a redirector like `ftpmirror.gnu.org` bouncing you to an overloaded backend, a connection that drops mid-transfer, `curl -f` not catching every failure mode) can leave a `.tar.gz`/`.tar.xz` on disk that's really an HTML error page, or just truncated — `curl`'s exit code looks fine, the file exists, and the failure only shows up much later as a confusing `tar: Unexpected EOF` or `gzip: invalid compressed data` partway through section 10.1's build, far from where the actual problem happened:

```bash
tar -tzf zlib-1.3.1.tar.gz    >/dev/null && echo "zlib OK"
tar -tzf perl-5.40.0.tar.gz   >/dev/null && echo "perl OK"
tar -tzf openssl-3.5.7.tar.gz >/dev/null && echo "openssl OK"
tar -tzf curl-8.11.0.tar.gz   >/dev/null && echo "curl OK"
tar -tzf pkg-config-0.29.2.tar.gz >/dev/null && echo "pkg-config OK"
tar -tzf wget-1.24.5.tar.gz   >/dev/null && echo "wget OK"
tar -tzf jq-1.7.1.tar.gz      >/dev/null && echo "jq OK"
tar -tJf git-2.47.0.tar.xz    >/dev/null && echo "git OK"
tar -tzf gettext-0.22.5.tar.gz >/dev/null && echo "gettext OK"
```

`-t` just lists the archive's contents without extracting anything, so this is a cheap way to confirm each file is a valid, complete archive of the right compression type (`-z` for `.tar.gz`, `-J` for `.tar.xz`) before you're several packages deep inside the chroot. If any line doesn't print its `OK`, re-download that one file rather than proceeding — don't assume the others are fine just because these ran, since each archive can fail independently depending on which mirror it happened to land on. `cacert.pem` isn't a tar archive, so it isn't included here; eyeball it instead (`head -1 cacert.pem` should show a `#` comment line, not an HTML `<html>` tag — the latter means the download actually got an error page).

`cacert.pem` isn't source code — it's the [Mozilla CA bundle that the curl project mirrors](https://curl.se/ca/cacert.pem) specifically for bootstrapping cases like this one. Nothing inside the chroot can be trusted to fetch its *own* trust store over HTTPS before it has one, so this rides in from the host the same way the tarballs do; section 10.1 (`openssl`) installs it as the default CA file once OpenSSL exists to use it.

The download order above matches the build order in section 10.1, not alphabetical — `perl` and `openssl` come before `curl`/`wget`/`pkg-config` on purpose (curl/wget need a real TLS backend to build against), `pkg-config` comes right before `wget` (see 10.1 for why it's needed there specifically), and `openssl`/`curl` are both built well before `git` (see 10.1 for why).

Once curl itself is built inside the chroot (in 10.1), downloading from within the chroot works normally for everything after that — this pre-fetch step is only needed for these.

### 9.2 Mount and chroot in

Mount the virtual filesystems the chroot needs, then enter it:

```bash
mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"

chroot "$VIND" /bin/dash
```

`/bin/ash` (from Busybox, section 7.2 — built with `CONFIG_ASH=y`) works here too, and is already present at this point regardless of whether dash's own build succeeded: `chroot "$VIND" /bin/ash`. Either shell is fine for everything in this guide; use whichever is actually on disk.

### 9.3 Reset the environment for native builds

`chroot` only changes the filesystem root — it does **not** clear environment variables. Every Phase 1 export (`CC`, `PREFIX`, `DESTDIR`, `HOST`, `TOOLS`, and the `$TOOLS/bin`-prefixed `PATH`) is still set in this shell, and now points at things that don't work inside the chroot: `$CC` is still the Pass 1 cross-compiler's absolute host path, which `configure` scripts will use directly (`autoconf`'s `AC_PROG_CC` prefers an already-set `$CC` over searching `PATH` itself) — and that binary can't even execute here, since it's a glibc-linked binary and this chroot has no glibc runtime, only musl. Left in place, this produces `configure: error: C compiler cannot create executables` on the very first package you try to build.

`$DESTDIR` is the more dangerous one of these, because leaving it set doesn't fail loudly. It's still `$VIND` (e.g. `/mnt/vind`) from section 7, and most `make install` targets honor `$DESTDIR` automatically without you passing it explicitly. Since you're now *inside* the chroot, that same string is just a path — `make install` happily creates `/mnt/vind/usr/lib` etc. as an ordinary, empty subdirectory of the chroot itself, and installs everything there instead of into the real `/usr/lib`. The build succeeds, `make install` reports no error, and the package is simply missing from where anything else will ever look for it.

Clear the Phase 1 (host/cross) variables, then set the native ones this chroot actually needs. Every build in Phase 2 assumes both halves of this have already run:

```bash
unset CC CXX PREFIX DESTDIR HOST TOOLS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

export PATH=/usr/bin:/bin
export CC=gcc
export CXX=g++
export CFLAGS="-I/usr/include"
export CPPFLAGS="-I/usr/include"
export LDFLAGS="-L/usr/lib"
```

- `CC`/`CXX` are set explicitly (not just left to `configure`'s auto-detection) because a couple of packages later in this guide — zlib's custom `configure` in particular — don't reliably search `PATH` on their own and abort with `Missing or broken C compiler.` without it.
- `CFLAGS`/`CPPFLAGS`/`LDFLAGS` point at `/usr/include` and `/usr/lib` — the real paths *inside* the chroot (remember, `$VIND` no longer means anything in here; it's just `/`). These are already the default search paths for a native compiler, so this isn't strictly required for every package, but it removes a class of "header exists but isn't found" failures for anything that doesn't pass its own `-I`/`-L` (see the git/zlib FAQ entry below) and costs nothing to set once, up front.
- `CPATH`/`C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH` are unset defensively — if any of these leaked in from a Phase 1 shell (they aren't set anywhere in this guide, but are easy to pick up from a host's own `/etc/profile` or similar), they'd get searched before the sysroot and can reproduce the same "header exists but isn't found" symptom.

Confirm it's now picking up the Pass 2 compiler from section 8, not the Pass 1 one:

```bash
which gcc
gcc --version
```

`which gcc` should print `/usr/bin/gcc`. From here on, you're running commands as if you were already inside Vind Linux — no more `$VIND`, `DESTDIR`, `--host`, or cross-compiler paths. `gcc`/`cc` now mean the Pass 2 compiler from section 8, running natively, and every build in Phase 2 assumes this reset has already happened — redo it in any new terminal that re-enters the chroot.

## 10. Build the rest natively

With the Pass 2 compiler in place, anything still built by hand from here on is a normal `./configure && make && make install` — no cross flags, no `DESTDIR`. But right after `chroot`, the chroot has no network tool at all yet: no `curl`, `wget`, or `git`. Those are exactly what section 10.1 builds first, from the tarballs pre-fetched onto the host in 9.1 (since nothing inside the chroot can reach the network until one of them exists). Once `curl` is installed (partway through 10.1), the ordinary Download → Build → Install pattern works for anything after it, and packages get fetched with a plain `curl -fL -o <name>-<version>.tar.gz <url>` like any other native build.

### 10.1 lambda's own prerequisites

`lambda` itself needs to exist before it can install anything, so its build-time dependencies have to be built by hand, the same way — this is the last hand-built batch before `lambda` takes over. Nine packages: `zlib`, `perl`, `openssl`, `curl`, `pkg-config`, `wget`, `jq`, `gettext` (for `msgfmt`), and `git`. `lambda` is 100% shell script, so `jq` is its one real dependency — it's what `lambda` uses to read the package recipes (JSON) you've been writing. `zlib` isn't something `lambda` itself needs — it's here because `git`'s build unconditionally `#include`s `zlib.h`, and nothing earlier in this guide has installed a copy of it inside `$VIND`. `gettext` likewise isn't a `lambda` dependency — it's here purely because Git's default build tries to compile its own translated message catalogs (`po/*.msg`) with `msgfmt`, which nothing earlier in this guide provides. `pkg-config` isn't a `lambda` dependency either — it's here because `wget`'s `configure` (unlike `curl`'s) queries OpenSSL through `pkg-config` rather than falling back to a manual `-lssl -lcrypto` probe: since OpenSSL 1.0.0, `wget`'s `configure.ac` tries `pkg-config` first for detecting OpenSSL, and with no `pkg-config` on `PATH` at all it hard-fails with `configure: error: The pkg-config script could not be found or is too old` instead of degrading gracefully. `perl` and `openssl` are the odd ones out, and the reason this batch grew from six packages to eight; `pkg-config` is the ninth, added for `wget` specifically — see below.

Their source tarballs should already be sitting in `/usr/src` from section 9.1 — the steps below skip the download and start from `tar -xf`.

**A real TLS backend is required, not optional, and this is where it gets built.** Earlier drafts of this guide built `curl`/`wget` with `--without-ssl`, on the theory that plain HTTP was good enough for a bootstrap and a TLS library could be added "once decided." It can't be deferred: GitHub (where `lambda-manager` and its package recipes live, section 11.1) dropped the unencrypted `git://` protocol in 2022 and only accepts `https://` now, so `git clone https://github.com/...` — the very next step after this section — hard-fails without real TLS. `openssl` closes that gap. It in turn needs `perl` to run its `Configure`/`config` script — this isn't optional either; OpenSSL's build system is a set of Perl scripts, full stop, and there's no autotools/CMake alternative for it. Building a whole Perl just to satisfy one build-time script feels heavy for a minimal bootstrap, but it's the standard, well-trodden path (LFS itself builds Perl in its base system for exactly this reason — plenty of other packages' build systems assume it exists), and there's no smaller way to get a real `Configure` script to run.

Build order matters here, and it's the order these subsections are written in: `zlib` → `perl` → `openssl` → `curl` → `pkg-config` → `wget` → `jq` → `gettext` → `git`. `perl` has to exist before `openssl` (its `Configure` script needs it), `openssl` has to exist before `curl`/`wget` (they link against it for real HTTPS instead of just being told to skip TLS), `pkg-config` has to exist before `wget` specifically (see above — `curl`'s own `configure` doesn't need it), and `curl` has to exist — with that TLS support already linked in — before `git` (Git decides once, at its own build time, whether to compile `git-remote-https` and whether that helper has anything usable behind it).

#### zlib

```bash
cd /usr/src
tar -xf zlib-1.3.1.tar.gz
cd zlib-1.3.1

export CC=gcc
./configure --prefix=/usr
make
make install
```

zlib's `configure` is a custom script (not autotools). Unlike the autotools scripts used everywhere else in this guide, it doesn't reliably search `PATH` for a compiler on its own — even with a perfectly working `gcc` on `PATH` (confirm with `gcc --version`), it can still abort with `Missing or broken C compiler.` unless `$CC` is set explicitly first, hence the `export CC=gcc` above (already set as part of section 9.3, but harmless to repeat). `--prefix` works the same as with autotools, though. Only needed here because git's build requires it unconditionally — nothing else in this guide links against it yet. `zlib.net` only serves the *current* release at the short URL pattern (`zlib.net/zlib-<version>.tar.gz`); older releases, including this one, live under `zlib.net/fossils/zlib-<version>.tar.gz` instead — see the FAQ if the pinned version here goes stale too.

zlib is a library, not a program — there's no `zlib` command to run afterward. Verify the install landed in the right place instead:

```bash
ls /usr/include/zlib.h /usr/lib/libz.so.1.3.1
```

If this comes back `No such file or directory` even though `make install` reported no error, `$DESTDIR` was still set from Phase 1 and everything got installed one level too deep, under `/mnt/vind/usr/...` instead of `/usr/...` — see the FAQ.

#### perl

Needed only so OpenSSL's `Configure` script (a Perl script, not autoconf-generated) has something to run — nothing else in this bootstrap batch calls `perl` directly.

```bash
cd /usr/src
tar -xf perl-5.40.0.tar.gz
cd perl-5.40.0

./Configure -des -Dprefix=/usr
make
make install
```

`-des` tells Perl's own (non-autoconf, non-autotools) `Configure` script to accept its defaults (`-d`) silently, without an interactive Q&A session (`-e`, `-s`) — fine for a build-time-only Perl that nothing else in this guide depends on directly. Verify:

```bash
perl -v
```

#### openssl

This is what actually gives `curl`/`wget` — and, transitively, `git` — real HTTPS support: a TLS library, not just an HTTP client. It needs the `perl` built just above to run its own `Configure` script; there's no autotools/CMake alternative for OpenSSL's build system, the same way there's none for musl's.

```bash
cd /usr/src
tar -xf openssl-3.5.7.tar.gz
cd openssl-3.5.7

./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared
make
make install
```

- `--libdir=lib` overrides OpenSSL's own default, which is not simply `--prefix/lib`: for the `linux-x86_64` target, `Configure` assumes a multilib layout and picks `lib64` for the actual shared objects (visible in the build log as e.g. `-DENGINESDIR="\"/usr/lib64/engines-3\""`), the same convention a multilib glibc distro uses to keep 32-bit and 64-bit libraries apart. Vind Linux has no such split — section 7.1 installed musl itself straight into `/usr/lib` (`--syslibdir="$PREFIX/lib"`), and nothing in this guide ever creates a `/usr/lib64`. Left at its default, `make install` drops `libssl.so`/`libcrypto.so` into a `/usr/lib64` that nothing else uses or looks in, and every program linked against them — starting with the `openssl` binary itself — fails at startup with `Error loading shared library libssl.so.3: No such file or directory`, even though the file exists, just one directory over. `--libdir=lib` makes `Configure` install everything into `/usr/lib` instead, matching where musl's dynamic loader actually searches by default.
- `--openssldir=/etc/ssl` is separate from `--prefix`: `--prefix` is where the libraries, headers, and the `openssl` binary itself go (`/usr/lib`, `/usr/include`, `/usr/bin`), while `--openssldir` is where OpenSSL looks for its trust store by default — a cert file at `$OPENSSLDIR/cert.pem` and a hashed cert directory at `$OPENSSLDIR/certs`. Getting these mixed up (or omitting `--openssldir`, which defaults to something under `--prefix`) is a common cause of "TLS handshake succeeds but every certificate fails to verify."
- `shared` builds `libssl.so`/`libcrypto.so`, matching the shared-by-default build of `zlib` above — `curl`/`wget` link against these dynamically rather than being statically bundled.

Install the CA bundle pre-fetched in section 9.1 as OpenSSL's default trust store. Without this step, OpenSSL (and anything linked against it) can complete a TLS handshake but has no certificates to check it against, and every `https://` request still fails, just with a certificate-verification error instead of a protocol error:

```bash
mkdir -p /etc/ssl
cp /usr/src/cacert.pem /etc/ssl/cert.pem
```

Verify:

```bash
openssl version
```

#### curl

```bash
cd /usr/src
tar -xf curl-8.11.0.tar.gz
cd curl-8.11.0

./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed
make
make install
```

`--with-openssl` links this `curl` against the `openssl` built just above, instead of curl's older default of building with no TLS backend at all — without a TLS backend, `curl`/`libcurl` don't merely "prefer HTTP," they have no code path for the `https://` scheme whatsoever, and reject it outright. `--with-ca-bundle=/etc/ssl/cert.pem` points this `curl` at the CA bundle installed alongside `openssl` above; without it, `curl` falls back to a compile-time guess about where the trust store lives that doesn't match this layout, and certificate verification fails even though the handshake itself works. `--without-libpsl` is needed even though nothing earlier in this guide installs `libpsl` and `pkg-config` isn't present either: most of curl's optional dependencies (brotli, zstd, LDAP, GSS-API, ...) degrade gracefully to "not found, feature disabled" when absent, but PSL (Public Suffix List, used for cookie-domain checks) is treated as on-by-default and its absence is a hard `configure: error: libpsl libs and/or directories were not found where specified!` unless explicitly disabled — this build doesn't need PSL support for anything.

`--disable-docs` and `--without-ca-embed` are no longer *forced* by a missing `perl` the way they would have been earlier in this guide — `perl` is already installed by this point (it's a dependency of `openssl`, built two steps above). They're kept here purely for minimalism: `--disable-docs` skips man pages and the built-in `--help` manual, which this bootstrap `curl` doesn't need; `--without-ca-embed` skips baking a copy of the CA bundle directly into the `curl` binary, since `--with-ca-bundle` above already points it at a CA file on disk, so an embedded copy would just be redundant weight. From here on, `curl` works inside the chroot for both plain HTTP and `https://`, so any package after this point can go back to the normal Download step from section 10.

#### pkg-config

Needed only so `wget`'s `configure` (next) can find the `openssl` built above — nothing else in this bootstrap batch calls `pkg-config` directly, and `curl`'s own `configure` above didn't need it.

```bash
cd /usr/src
tar -xf pkg-config-0.29.2.tar.gz
cd pkg-config-0.29.2

./configure --prefix=/usr --with-internal-glib
make
make install
```

`--with-internal-glib` builds against the minimal copy of `glib` vendored inside pkg-config's own tarball instead of linking a system `glib` — nothing in this guide installs `glib` at any point, and pulling in the real thing would drag in a much bigger dependency chain than this one bootstrap tool is worth. Verify:

```bash
pkg-config --version
```

#### wget

```bash
cd /usr/src
tar -xf wget-1.24.5.tar.gz
cd wget-1.24.5

./configure --prefix=/usr --with-ssl=openssl
make
make install
```

Same `openssl` as `curl` above, but detected differently: `wget`'s `configure` looks for OpenSSL via the `pkg-config` built just above (see that subsection for why `curl` doesn't need this same step) rather than a manual library probe. `wget` picks up OpenSSL's default trust store (`/etc/ssl/cert.pem`, set via `--openssldir` when `openssl` was built) automatically, so there's no separate `--with-ca-bundle`-equivalent flag to pass here the way there was for `curl`.

#### jq

```bash
cd /usr/src
tar -xf jq-1.7.1.tar.gz
cd jq-1.7.1

./configure --prefix=/usr --with-oniguruma=builtin --disable-maintainer-mode
make
make install
```

`--with-oniguruma=builtin` builds jq's regex dependency (oniguruma) from the copy vendored inside the jq release tarball, instead of looking for a system-installed one — nothing provides it yet at this point in the build. `--disable-maintainer-mode` skips re-running `autoreconf` on the bundled `configure`, which needs `bison`/`flex` we haven't built. Once this is installed, `jq --version` should work.

#### gettext (for msgfmt)

Git's default build compiles its translated message catalogs (`po/*.msg`) using `msgfmt`, part of GNU `gettext`. Nothing earlier in this guide installs it, so `make` fails partway through Git's build with `MSGFMT po/bg.msg` / `Error 127` (`127` meaning the shell couldn't find `msgfmt` at all) even though everything up to that point succeeded. Build the whole `gettext` package now, or skip translations entirely at Git's `configure` step (see the note under Git below) — this guide takes the minimalist route and disables Git's translations instead of building all of `gettext` for a single tool, but `gettext` is documented here in case a later package needs it for real:

```bash
cd /usr/src
tar -xf gettext-0.22.5.tar.gz
cd gettext-0.22.5

./configure --prefix=/usr --disable-shared
make
make install
```

`--disable-shared` keeps this to a static build — nothing else in this minimal bootstrap links against `libgettextlib`/`libgettextpo` dynamically, and it avoids adding another `.so` to track before `lambda` exists to manage it. If you don't need `msgfmt` for anything beyond Git, skip this package entirely and use `--disable-nls` in Git's `configure` instead (see below) — that's the path this guide follows by default, to keep this batch of hand-built prerequisites as small as possible.

#### git

Built last in this batch, after `perl`/`openssl`/`curl`/`wget`/`jq` — see the build-order note above. `git clone` over `git://` or local paths would work regardless of order, but `git clone https://...` only works if `curl` — built with real TLS support — already existed when `git` itself was configured and built.

Git's build also defaults to compiling `git-gui` and other Tcl/Tk-based tools, and to building translated message catalogs with `msgfmt` — neither of which exists yet in this minimal chroot, and neither of which is needed for a minimal bootstrap. Skip both explicitly:

```bash
cd /usr/src
tar -xf git-2.47.0.tar.xz
cd git-2.47.0

make configure
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```

Git's own `INSTALL` doc recommends `make configure` (it generates `./configure` from `configure.ac`) over a plain autoconf-generated one — its `Makefile` already probes for available features via `uname` and doesn't need a full autoconf `configure` to work correctly. `--disable-nls` (plus `NO_GETTEXT=1` on the `make` line, since Git's `Makefile` checks for this independently of what `configure` decided) skips the `msgfmt`-built message catalogs entirely, which is what actually caused the `Error 127` — nothing in this guide builds `gettext`/`msgfmt` by default (see above if you'd rather build it instead of skipping translations). `--without-tcltk` (plus `NO_TCLTK=1`) skips `git-gui`/`gitk`, which need Tcl/Tk — also not built anywhere in this guide, and not needed for a minimal, script-driven bootstrap. Since `curl` was already built — with real TLS support — earlier in this same section, `configure` should auto-detect it and compile in `git-remote-https`, and that helper should actually be able to complete an `https://` handshake rather than just exist. Verify with `git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check` once installed (see the FAQ if this fails with `Protocol "https" not supported` or with `remote helper 'https' aborted session` — they're different failures with different fixes).

If `git`'s `make` fails with `fatal error: zlib.h: No such file or directory` even though `/usr/include/zlib.h` exists, the shell doesn't have the `CC`/`CFLAGS`/`CPPFLAGS`/`LDFLAGS` exports from section 9.3 — re-run those (or open a new chroot shell and redo section 9.3 in full) before retrying.

#### resolv.conf

Before being able to clone the lambda-manager repo we need a valid resolv.conf for being able to prob the adress.

```bash
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

## 11. Packaging with lambda

From this point on, the rest of the system — including libffi and LLVM/Clang/LLD, which earlier drafts of this guide built by hand — gets installed through `lambda` instead of living as loose hand-installed files. `lambda` is the package manager I wrote for Vind Linux: minimalist, written entirely in shell, and built around the idea that packages are built locally from JSON recipes rather than pulled as pre-built binaries. It handles downloading, building, installing, tracking, and removing packages and their dependencies, and gives the system a proper install manifest instead of an untracked pile of `make install` output.

Full docs, and source live at [github.com/VindLinux/lambda-manager](https://github.com/VindLinux/lambda-manager) — this section only covers what's needed to get it running inside the chroot.

### 11.1 Build and install lambda

`lambda`'s only real dependency is `jq`, already built in 10.1 — being a shell script, there's nothing to compile here, just install.

```bash
cd /usr/src
git clone https://github.com/VindLinux/lambda-manager
```

Then pull in the actual package recipes — a separate repo, since `lambda` itself ships with none:

```bash
git clone https://github.com/VindLinux/packages
cp packages/packages/* lambda-manager/packages/
```

Finally, install:

```bash
cd lambda-manager
./install.sh
```

Run it as-is, without `sudo` — everything in this guide happens as root inside the chroot already, and nothing built anywhere in this guide provides a `sudo` binary (Busybox's applet list in section 7.2 doesn't enable one), so prefixing this with `sudo` just fails with a "not found"/`applet not found` error rather than doing anything useful.

Check it's working:

```bash
lambda --help
```

### 11.2 Before using

`lambda`'s default `make.conf` template uses `clang` as `CC` and `clang++` as `CXX`. Clang doesn't exist yet at this point in the guide — only the Pass 2 GCC from section 8 — so override it to GCC for now:

```bash
cat > /etc/lambda/make.conf <<'EOF'
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
```

and create a ld-musl-x86_64.path

```bash
cat > /etc/ld-musl-x86_64.path <<'EOF'
/lib
/usr/local/lib
/usr/lib
/usr/lib64
EOF
```

### 11.3 Recommended dependencies

`lambda` itself only needs `jq`, but a lot of the recipes in Vind Linux's `packages` repo need extra tools to build. Worth having these on hand before installing much through `lambda`, since a missing build tool fails mid-recipe rather than up front:

```text
meson, xz, python3        (build tools)
git, zlib, bzip2, flex     (libraries and utilities)
setuptools, pip, wheel     (python packages)
```

`git` and `zlib` are already installed from section 10.1. The rest aren't covered in this guide yet — install them the same way as everything else in Phase 2 (plain `./configure && make && make install`, or via `lambda` once enough of the base system exists to bootstrap it).

### 11.4 Basic usage

```bash
lambda mutate append vim
lambda mutate purge nano
lambda reconcile
```

Everything from here — libffi, LLVM/Clang/LLD, and anything added later — gets installed with `lambda install <name>` instead of the manual Download/Build/Install pattern from section 10.

### 11.5 Package recipes and dependencies

Recipes are the JSON files under `packages/` — the same format used throughout section 7 and 10.1 of this guide (name, version, download, build, install steps), plus a `dependencies` list.

One rule worth keeping in mind when writing new recipes: the bootstrap toolchain doesn't belong in `dependencies`. `lambda` assumes these already exist on any system it runs on, so listing them just adds noise to the dependency graph:

```text
gcc, binutils, make, bash, coreutils, tar, gzip, xz, sed, grep
```

(The upstream `lambda` README also lists `glibc` here — Vind Linux uses musl instead, so that entry doesn't apply as-is; worth updating the recipe conventions to say `musl` if this guide's toolchain choice is final.)

Everything else — `zlib`, `ncurses`, `meson`, `cmake`, whatever a package actually needs — gets listed explicitly, even if it happens to already be present from an earlier step in this guide. The rule of thumb: if it's part of the guaranteed bootstrap toolchain, omit it; if it's a library or tool the package actually needs to build, list it.

### 11.6 DESTDIR

`lambda` supports installing into an alternate root, same idea as the `DESTDIR="$VIND"` pattern from Phase 1:

```bash
DESTDIR=/some/path lambda install vim
```

Not needed for anything in this guide (we're already native inside the chroot by this point), but relevant if this whole process ever gets restarted from a different host, or used to stage a second Vind Linux install.

---

## 12. Installing the base packages

At this point the system is very close to being complete. The remaining pieces are installed through `lambda` itself, instead of by hand, so they end up in `lambda`'s manifest with proper dependency tracking.

Replace `/etc/lambda/system.json` with the base package set below, then reconcile. This is going to take a long time — `lambda reconcile` resolves and builds this entire list from source, including LLVM.

`gcc` is deliberately included here, even though a working GCC (the Pass 2 compiler from section 8) is already on disk. That one was installed by hand, outside `lambda` entirely, so as far as `lambda`'s manifest is concerned GCC doesn't exist yet — there's nothing in there for `lambda` to ever cleanly remove. Listing `gcc` here has `lambda` build and install its own tracked copy (using the section 8 compiler to do it), which brings GCC under manifest management. That's what makes it possible to remove GCC cleanly later, once Clang is confirmed self-hosting (section 13) — a package `lambda` never installed can't be uninstalled through `lambda` either.

```bash
cat > /etc/lambda/system.json <<'EOF'
{
  "packages": [
    "gcc",
    "libnl",
    "pkgconf",
    "libc++",
    "dhcpcd",
    "llvm",
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
    "make",
    "libpsl",
    "argp-standalone",
    "ln",
    "perl",
    "kbd",
    "ncurses",
    "dash",
    "iwd",
    "busybox",
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
    "e2fsprogs",
    "gfetch",
    "ca-certificates",
    "dbus",
    "util-linux"
  ]
}
EOF
```

Then reconcile:

```bash
lambda reconcile
```

If a package fails to build, do not assume it is an actual problem immediately. Try running `lambda reconcile` again first.

This can happen because some package dependencies are not fully tracked yet. As a result, a package may attempt to build before one of its required dependencies has been installed.

## 13. Pass 2, continued: moving to Clang/LLVM

Vind Linux's target compiler is Clang, not GCC — section 12 already pulled `llvm` into the base system, built with the manifest-tracked GCC from that same step. This section switches the system's own build environment over to Clang/LLVM, confirms it actually works, and then removes GCC, which was only ever needed to get this far.

### 13.1 Switch the build environment to Clang

`lambda`'s default `make.conf` template assumes Clang (`CC=clang`, `CXX=clang++`); section 11.2 overrode it to GCC so the section 12 build had a known-good, already-native compiler to work with. Now that Clang exists, switch back:

```bash
cat > /etc/lambda/make.conf <<'EOF'
# Lambda build environment

export CC="clang"
export CXX="clang++"

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
```

Confirm the shell itself can find Clang too, not just `lambda`'s build environment:

```bash
which clang clang++
clang --version
```

### 13.2 Build the C++ runtime with Clang: libc++ and libc++abi

GCC's C++ runtime (`libstdc++`) and Clang's (`libc++`) aren't interchangeable at the ABI level, so a Clang-based system needs its own. Build and install them through `lambda`, now that `make.conf` points at Clang — `lambda mutate append` both builds them and adds them to `system.json`, so they stay tracked going forward:

```bash
lambda mutate append libc++ libc++abi
```

### 13.3 Verify Clang can build the system on its own

Before removing GCC, confirm Clang is actually capable of standing on its own — both as a compiler and for linking against the new `libc++`:

```bash
cat > /tmp/hello.cpp <<'EOF'
#include <iostream>
int main() {
    std::cout << "hello from clang/libc++\n";
    return 0;
}
EOF

clang++ -stdlib=libc++ -o /tmp/hello-cpp /tmp/hello.cpp
/tmp/hello-cpp
```

Then confirm `lambda reconcile` itself works end-to-end with Clang as the active compiler, by rebuilding something already tracked — `curl` is a low-risk pick:

```bash
lambda mutate append curl
lambda reconcile
```

If both of these succeed, Clang is genuinely doing the compiling from here on, not just sitting on disk unused.

### 13.4 Remove GCC

With Clang confirmed working, GCC has done its job: it built musl, itself (twice, in Phase 1), and eventually LLVM/Clang. Nothing in the final Vind Linux system is meant to depend on it. Remove it from the manifest:

```bash
lambda mutate purge gcc
lambda reconcile
```

Confirm it's actually gone, not just dropped from `system.json`:

```bash
which gcc      # should print nothing
gcc --version  # should fail: command not found
clang --version
```

From this point on, Clang/LLVM is the only compiler in Vind Linux's final system state — `gcc` will not appear in `system.json`, on disk, or in `lambda`'s manifest again unless deliberately reinstalled.

## 14. Preparing for boot

The system is functionally complete. What's left is making it bootable on its own hardware (or VM), without the live installer: a filesystem table, a kernel, an init system, and a bootloader.

### 14.1 /etc/fstab

Based on the partition layout from section 2:

```bash
cat > /etc/fstab <<'EOF'
# <file system>   <mount point>  <type>  <options>        <dump> <pass>
/dev/vda3         /              ext4    defaults         0      1
/dev/vda1         /boot/efi      vfat    umask=0077       0      2
/dev/vda2         swap           swap    defaults         0      0
EOF
```

This uses the raw device paths (`/dev/vda1`/`/dev/vda2`/`/dev/vda3`) to match how this guide partitioned the disk in section 2. Swapping these for `UUID=...` entries (from `blkid`) is more robust against device renumbering on real hardware, and worth doing before relying on this install long-term — but it isn't required to boot.

### 14.2 Kernel

*Not yet decided.* Vind Linux needs an actual kernel image (`vmlinuz`) installed to `/boot` before it can boot — everything built so far only installs the kernel's **headers** (section 7.7), not the kernel itself. How the kernel gets built and tracked — a `lambda` recipe like the rest of section 12, versus a hand-built package like section 10.1's prerequisites — hasn't been finalized yet, so it isn't documented here. This section will be filled in once that's settled; don't infer a package name or build command for it in the meantime.

Vind Linux does not use an initramfs: the kernel is expected to be self-contained (musl-compatible root filesystem support and any required drivers built in), so no `dracut`/`mkinitcpio`-style initrd generation step belongs in this guide.

### 14.3 Init system

*Not yet decided.* Something has to run as PID 1 once the kernel hands off. `system.json` (section 12) doesn't currently list a dedicated init system, and while Busybox's `init` applet is available (section 7.2), it isn't yet wired up as `/sbin/init` anywhere in this guide. This is left undocumented for the same reason as the kernel above — pin it down before writing the steps here.

### 14.4 Bootloader (GRUB)

`grub` and `efibootmgr` are already installed as part of section 12's package set. Install GRUB into the EFI System Partition mounted at `/boot/efi` (section 4), and generate its configuration:

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=VindLinux --removable
grub-mkconfig -o /boot/grub/grub.cfg
```

`--removable` additionally installs a fallback bootloader path (`EFI/BOOT/BOOTX64.EFI`) alongside the `--bootloader-id`-named one. That's worth keeping on a VM/disk image, where the firmware's NVRAM boot entries (which `efibootmgr` would otherwise manage) may not persist reliably across the specific virtualized firmware in use — drop it on real hardware where a single, normal NVRAM entry is preferred instead.

`grub-mkconfig` scans `/boot` for kernels to generate menu entries for, so this step depends on section 14.2 (the kernel) already being in place. Re-run it any time a kernel is added, updated, or removed.

### 14.5 Leave the chroot and boot

Unmount everything cleanly and leave the live environment:

```bash
exit                                   # leave the chroot
umount -R "$VIND/dev" "$VIND/proc" "$VIND/sys" "$VIND/run"
swapoff /dev/vda2
umount -R "$VIND"
reboot
```

Remove the live ISO/installer media before the system restarts, so the firmware boots from `/dev/vda` instead of the live environment again. Once GRUB starts and hands off to Vind Linux's own kernel (section 14.2) and init (section 14.3), the system built by this guide is up and running on its own.

## FAQ / Troubleshooting

### Section 6 — Pass 1 cross-toolchain

**`make` was interrupted or a previous attempt failed partway through.**
Run `rm -rf build` inside `musl-cross-make` before retrying `make -j$(nproc)`.

**`make` fails downloading a source tarball (e.g. musl) with `Connection refused` or `Network is unreachable`, even though the host clearly has working internet.**
Check `ip addr` / `ip route` / `ip -6 route`. If the host has an IPv6 address and default route configured *alongside* a working IPv4 one, the resolver may hand `wget` an IPv6 address first — and if that IPv6 setup isn't actually routable to the internet (e.g. it's a deprecated site-local `fec0::/64` address, or a route with no real path out, common on cloud/VM network setups), the download fails outright instead of falling back to IPv4, since plain `wget`/`curl` don't retry the other address family on their own.

Confirm by forcing IPv4 directly:
```bash
wget -4 https://musl.libc.org/releases/musl-1.2.6.tar.gz
```
If that succeeds where the plain download failed, this is it. Fix it for the rest of `musl-cross-make`'s own downloads (it fetches gcc, binutils, musl, gmp, mpfr, mpc, isl itself during `make`) by overriding its download command in `config.mak`:
```bash
echo 'DL_CMD = wget -4 -c -O' >> config.mak
```
This only affects `musl-cross-make`'s internal downloads. Any `curl` command written directly in this guide (sections 7 onward) would need `-4` added the same way if it hits the same issue on your host — e.g. `curl -4 -fL --retry 3 --retry-delay 2 -o ...`.

### Section 7 — Cross-build (general)

**A package build fails with `cannot run C compiled programs`, or silently uses the host's glibc gcc instead of the musl cross-compiler.**
The environment variables from the top of section 7 (`PREFIX`, `DESTDIR`, `CC`, `HOST`, `PATH`) aren't set in the current shell — common after opening a new terminal. Re-export them and retry.

### Section 7.1 — musl

**`find "$VIND" -name 'ld-musl-x86_64.so.1'` returns nothing.**
Double-check `--syslibdir="$PREFIX/lib"` was passed at configure time and that `make DESTDIR="$DESTDIR" install` completed without errors.

### Section 7.2 — Busybox

**Busybox builds without error, but binaries behave oddly, crash, or `busybox --list` shows applets that misbehave at runtime — even though `file` confirms they're musl-linked (or static).**
Check the build command for a stray `CFLAGS='--sysroot=/'` / `LDFLAGS='--sysroot=/'`. That overrides the Pass 1 cross-compiler's own bundled musl sysroot with the host's root filesystem, so the compiler picks up Gentoo's glibc headers at compile time while still linking against musl's `libc.a` — a header/ABI mismatch that can compile cleanly and still misbehave at runtime (this is exactly the class of bug section 6 exists to avoid). Rebuild without those flags:
```bash
cd "$VIND/sources/busybox-1.37.0"
make clean
CC="$CC" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip make $MAKEOPTS
cp busybox "$VIND/usr/bin/busybox"
```

### Section 7.6 — binutils

**`configure` fails with `cannot run C compiled programs` in one or more subdirectories (`gas`, `libiberty`, `zlib`, `libsframe`...), even though `--host` was passed correctly.**
This is the same `--build` auto-detection problem described in section 8's FAQ, just showing up here because `binutils` is a multi-directory project — each subdirectory runs its own `configure` and does its own `--build` detection, and `$PATH`/`$CC` being biased toward the musl compiler (from section 7's exports) confuses some of them. Fix by passing `--build` explicitly instead of letting it auto-detect:
```bash
BUILD_TRIPLE=$(/usr/bin/gcc -dumpmachine)
./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" --disable-multilib --disable-nls --disable-gprofng
```
If a previous attempt already left partial `Makefile`s in subdirectories, clean those up first — a stale sub-`Makefile` can keep using the old (wrong) detection even after you fix the top-level command:
```bash
rm -rf */Makefile
```
This same fix (`--build="$(/usr/bin/gcc -dumpmachine)"`) is worth trying first for **any** autotools package in section 7 that fails the same way, not just binutils — anything with several subdirectories cross-building against this toolchain can hit it.

**`make install` fails inside `gprofng` with `'fopen64' was not declared in this scope` (or `fseeko64`/`ftello64`).**
`gprofng` (binutils' bundled profiler, since 2.38) uses glibc's `*64` large-file-support functions, which musl doesn't have — musl doesn't need a separate 64-bit variant since it's always 64-bit. This isn't fixable by patching your environment; the standard fix (used by other musl-based distros too) is to not build gprofng at all, since it's not part of the core toolchain. Add `--disable-gprofng` to the `configure` command and rebuild:
```bash
./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" --disable-multilib --disable-nls --disable-gprofng
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```
`ar`, `as`, `ld`, `nm`, `ranlib`, and `strip` — everything this guide actually needs — build and install independently of gprofng, so this doesn't lose anything required.

**Inside the chroot, `gcc` compiles fine but fails with `cannot execute 'as': execvp: No such file or directory` (or the same for `ld`).**
Section 7.6 (binutils) was skipped or run before it existed in this guide. `as`/`ld` need to be a musl-native binutils build inside `$VIND`, separate from the Pass 1 toolchain's own host-side copy. Fix without restarting: exit the chroot, cross-build binutils from section 7.6, re-enter the chroot, and retry:
```bash
exit
# run section 7.6's Download/Build/Install, then:
mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"
chroot "$VIND" /bin/dash
echo "int main(){return 0;}" > /tmp/t.c && gcc -o /tmp/t /tmp/t.c && echo OK
```

### Section 7.7 — Linux kernel headers

**OpenSSL's build (section 10.1) fails with `fatal error: linux/mman.h: No such file or directory` while compiling `crypto/mem_sec.c`, even though `/usr/include/zlib.h` and other headers are all found fine.**
Section 7.7 (Linux kernel headers) was skipped, or `INSTALL_HDR_PATH` didn't point where you think it did. `musl` doesn't bundle the full Linux UAPI header set the way a glibc host's `linux-headers` package does — `linux/mman.h` (used by OpenSSL's secure-heap code) is one of the headers that's genuinely missing until this step runs, not a compiler-search-path issue like most other header FAQs in this guide.

The catch is that by the time you hit this, you're already inside the chroot, mid-way through building `openssl` — and `curl` doesn't exist there yet (it's built *after* `openssl` in section 10.1's order), so there's nothing to fetch the kernel tarball with from inside the chroot. Exit back to the host, run section 7.7 there, then re-enter:
```bash
exit   # leave the chroot — this needs the host's own curl
cd "$VIND/sources"
curl -fL --retry 3 --retry-delay 2 -o linux-6.6.79.tar.xz \
    https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.79.tar.xz
tar -xf linux-6.6.79.tar.xz
cd linux-6.6.79
make headers_install ARCH=x86_64 INSTALL_HDR_PATH="$VIND/usr"
find "$VIND/usr/include/linux" -name mman.h   # should print a path

mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"
chroot "$VIND" /bin/dash
```
Redo section 9.3 (the environment reset) in this new chroot shell, then retry the OpenSSL build from a clean extraction:
```bash
cd /usr/src/openssl-3.5.7
make clean 2>/dev/null
./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared
make
make install
```
No need to add `no-secure-memory` or any other feature-disabling flag to `Configure` — the header is genuinely available now, so OpenSSL's secure heap builds and works as intended rather than being switched off to route around a missing prerequisite.

**`openssl version` (or anything else linked against OpenSSL, including `curl` once it's built with `--with-openssl`) fails with `Error loading shared library libssl.so.3: No such file or directory` / `libcrypto.so.3: No such file or directory`, even though `make install` reported no error and the headers under `/usr/include/openssl` are all there.**
This isn't a missing-header problem like the one above — it's `--libdir` defaulting to the wrong place. OpenSSL's `Configure`, for the `linux-x86_64` target, assumes a multilib layout and installs the actual `.so` files under `$prefix/lib64` rather than `$prefix/lib` unless told otherwise. Vind Linux has no `/usr/lib64` — musl itself lives entirely in `/usr/lib` (section 7.1's `--syslibdir="$PREFIX/lib"`) — so the libraries land somewhere musl's dynamic loader never searches, and every program that depends on them fails at startup, not at compile or link time (which is why `make install` itself reports success). Confirm the libraries are indeed sitting in the wrong place:
```bash
find / -xdev -name 'libssl.so.3' -o -name 'libcrypto.so.3'
```
If that turns up `/usr/lib64/libssl.so.3` instead of `/usr/lib/libssl.so.3`, reconfigure and reinstall with `--libdir=lib` explicit:
```bash
cd /usr/src/openssl-3.5.7
make clean
./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared
make
make install
openssl version   # should now print without any "Error loading shared library" lines
```
The stray `/usr/lib64` directory left behind by the earlier install is inert and can be removed once the reinstall is confirmed working (`rm -rf /usr/lib64`) — nothing else in this guide reads from it. If `curl` or `wget` were already built against the broken OpenSSL, rebuild them too once this is fixed, the same way as any other package: `cd /usr/src/curl-8.11.0 && make clean && ./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed && make && make install`.

### Section 8 — Pass 2 GCC

**Inside the chroot, `gcc` fails on every build with `fatal error: string.h: No such file or directory` (or any other libc header) — even though the header clearly exists at `/usr/include`.**
This means the Pass 2 GCC was built with `--with-sysroot="$VIND"` instead of `--with-build-sysroot="$VIND"`. `--with-sysroot` bakes that absolute host path (e.g. `/mnt/vind`) into the compiler as its permanent default sysroot — which stops existing the moment you `chroot` in, since `$VIND` itself becomes `/`. The compiler ends up looking for headers under a path that no longer resolves to anything.

Fix by reconfiguring and rebuilding the Pass 2 GCC from the host (outside the chroot), swapping the flag:
```bash
exit   # leave the chroot first — this rebuild needs the host toolchain
cd "$VIND/sources/gcc-13.3.0"
rm -rf build-pass2 && mkdir build-pass2 && cd build-pass2
```
then redo the `configure`/`make`/`make install` from section 8 with `--with-build-sysroot="$VIND"` in place of `--with-sysroot="$VIND"`. Re-enter the chroot afterward and confirm with:
```bash
echo "int main(){return 0;}" > /tmp/t.c && gcc -o /tmp/t /tmp/t.c && echo OK
```

**Headers or library paths from the host (`/usr/include`, glibc) leak into the build instead of the musl sysroot.**
This is the failure mode that motivated splitting the build into two phases in the first place — cross-compiling C++-heavy software (like LLVM) directly against a Pass 1 toolchain is where this tends to show up, often as `__gnuc_va_list has not been declared` or `vswprintf`/`__to_xstring` mismatches pointing at `/usr/include/stdio.h` instead of the sysroot's. Check for `CPATH`, `C_INCLUDE_PATH`, or `CPLUS_INCLUDE_PATH` set in your shell — any of these get searched *before* the compiler's own sysroot and will cause exactly this. Unset them:
```bash
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
```
and confirm the search order with:
```bash
x86_64-pc-linux-musl-g++ -E -v -xc++ /dev/null 2>&1 | sed -n '/search starts here/,/End of search list/p'
```
The sysroot's musl `include` directories should appear before `/usr/include`.

**Build fails inside `libstdc++` with `no matching function for call to '__to_xstring<...>'` (affects `std::to_string`/`std::to_wstring`).**
This is [GCC bug 37522](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=37522) — a long-standing mismatch between `libstdc++`'s expected `vswprintf`/`vsnprintf` prototype and musl's actual one. It isn't fixed by changing the GCC version. The upstream fix (originally for MinGW) is the `_GLIBCXX_HAVE_BROKEN_VSWPRINTF` macro, which makes `libstdc++` skip the affected functions (only `to_wstring` is actually lost; `to_string`, `stoi`, etc. are unaffected). Find the installed target `c++config.h`:
```bash
find "$TOOLS" -name c++config.h
```
and add near the top:
```c
#ifndef _GLIBCXX_HAVE_BROKEN_VSWPRINTF
#define _GLIBCXX_HAVE_BROKEN_VSWPRINTF 1
#endif
```
then retry the build (clean the build directory first if it's CMake/Ninja-based — a stale cache still points at the old error state).

### Section 9 — Entering the chroot

**Inside the chroot, `./configure` fails with `configure: error: C compiler cannot create executables`, and `checking for gcc...` shows a path under `/mnt/vind/tools/...` (or wherever `$TOOLS` pointed on the host) instead of `/usr/bin/gcc`.**
Section 9.3 (resetting the environment) was skipped, or you're in a fresh shell that re-entered the chroot without redoing it. `chroot` doesn't clear environment variables — `$CC` is still the Pass 1 host cross-compiler's path from section 7, and `configure` uses an already-set `$CC` directly instead of searching for one. That binary is glibc-linked and can't execute at all inside this musl-only chroot, which is exactly why the compiler check fails outright rather than just picking the wrong compiler. Fix:
```bash
unset CC CXX PREFIX DESTDIR HOST TOOLS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
export PATH=/usr/bin:/bin
export CC=gcc CXX=g++
export CFLAGS="-I/usr/include"
export CPPFLAGS="-I/usr/include"
export LDFLAGS="-L/usr/lib"
which gcc   # should print /usr/bin/gcc
```
then retry the build. If you exit and re-enter the chroot in a new terminal, redo this each time — it's a property of the shell session, not something that sticks once fixed.

### Section 10.1 — zlib, perl, openssl, curl, pkg-config, wget, jq, gettext, git

**`make install` (for zlib, or anything else in Phase 2) reports no error, but files end up under `/mnt/vind/usr/...` instead of `/usr/...` inside the chroot.**
This is the `$DESTDIR` leak described in section 9.3's FAQ, showing up here specifically: `$DESTDIR` was still set to `$VIND` from section 7, `make install` honored it silently (most `Makefile`s do, without needing it passed explicitly), and everything got installed one level too deep — a harmless-looking `/mnt/vind/usr/lib` created *inside the chroot itself*, not the real `/usr/lib` anything else will look in. Fix the environment and reinstall:
```bash
unset CC CXX PREFIX DESTDIR HOST TOOLS
export CC=gcc CXX=g++ PATH=/usr/bin:/bin
cd /usr/src/zlib-1.3.1   # or wherever the affected package's build tree is
make install
```
The phantom directory tree left behind (e.g. `/mnt/vind/` inside the chroot) is inert and can be removed once you've confirmed the real install worked — just double-check you're removing it *from inside the chroot*, where that path is empty junk, not the host's real mount.

**zlib's `./configure` aborts with `Missing or broken C compiler.`, even though `gcc`/`cc` clearly work when run directly.**
zlib's `configure` isn't autotools-based, and doesn't search `PATH` for a compiler the way the autotools scripts elsewhere in this guide do — it needs `$CC` set explicitly. Section 9.3 already exports `CC=gcc` for the whole chroot session, so this shouldn't come up if that step was followed; if it does (e.g. a fresh shell that skipped 9.3), set it directly:
```bash
export CC=gcc
./configure --prefix=/usr
```

**OpenSSL's `./Configure` fails or can't find `perl`, or `make` for `openssl` aborts partway through with a Perl syntax/version error.**
`openssl`'s build system is Perl scripts, not autotools — `perl` (the subsection just above it in 10.1) has to be built and on `PATH` first. Confirm with `perl -v`; if that fails, build `perl` first, then retry `openssl`'s `./Configure`/`make`/`make install` from a clean extraction.

**`git clone https://...` fails inside Vind Linux with `fatal: unable to access '...': Protocol "https" not supported`, even though `git --version` works fine and everything up through `make install` reported success.**
This means `curl` was built with `--without-ssl` (i.e. with no TLS backend compiled in at all) instead of `--with-openssl`. Git's HTTPS support is implemented by the `git-remote-https` helper, which links against `libcurl` and simply hands it the URL — it doesn't speak TLS itself. If the `libcurl` behind it has no TLS backend, the helper is present and `git` looks completely normal, but it never registered a handler for the `https://` scheme at all, so every `https://` clone fails immediately with this exact "Protocol not supported" error. (This is different from the `remote helper 'https' aborted session` error below, which means the helper never got built in the first place.)

Fix by building `perl` and `openssl` (see the `perl`/`openssl` subsections above if skipped), rebuilding `curl` with real TLS support, and then rebuilding `git` against that `curl`:
```bash
cd /usr/src/curl-8.11.0
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed
make
make install

cd /usr/src/git-2.47.0
make clean
make configure
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```
Confirm with a real clone, not just `git --version` (which succeeds either way):
```bash
git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check
```

**`git`'s `make` fails with `fatal error: zlib.h: No such file or directory` (in `daemon.c` or elsewhere), even though `/usr/include/zlib.h` exists.**
Two possible causes, check both:
1. `zlib` (section 10.1) hasn't actually been built yet. Its tarball should already be in `/usr/src` from section 9.1; build it first:
   ```bash
   cd /usr/src
   tar -xf zlib-1.3.1.tar.gz
   cd zlib-1.3.1
   export CC=gcc
   ./configure --prefix=/usr
   make
   make install
   ```
2. `zlib` is installed, but the shell is missing the `CFLAGS`/`CPPFLAGS`/`LDFLAGS` exports from section 9.3 (e.g. a new terminal that re-entered the chroot without redoing that step) — Git's `Makefile` doesn't always pass an explicit `-I`/`-L` for zlib on its own, and relies on the compiler's default search path already including `/usr/include`/`/usr/lib`, which is normally true but is worth confirming:
   ```bash
   export CC=gcc CXX=g++ PATH=/usr/bin:/bin
   export CFLAGS="-I/usr/include" CPPFLAGS="-I/usr/include" LDFLAGS="-L/usr/lib"
   ```
Then retry `git`'s build from a clean tree (a partial `make` can leave stale `.o` files that skip re-checking headers):
```bash
cd /usr/src/git-2.47.0
make clean
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```

**`git`'s `make` fails with `MSGFMT po/bg.msg` / `make[1]: *** [Makefile:239: po/bg.msg] Error 127`.**
`Error 127` means the shell couldn't find the command at all — here, `msgfmt` (part of GNU `gettext`), which nothing earlier in this guide installs. Git's default `configure` still tries to build translated message catalogs unless told not to. This guide's Git build (section 10.1) already passes `--disable-nls` at configure time and `NO_GETTEXT=1` on the `make`/`make install` lines specifically to skip this; if you hit this error, you're most likely working from a `configure`/`make` invocation that dropped one of those flags. Reconfigure and rebuild with both in place:
```bash
cd /usr/src/git-2.47.0
make clean
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```
If you specifically need `msgfmt` for something else, build `gettext` first (see the "gettext (for msgfmt)" step in 10.1) and drop `--disable-nls`/`NO_GETTEXT=1` instead — but for a minimal bootstrap, skipping Git's translations is the smaller, faster path.

**`curl`'s `configure` fails with `configure: error: libpsl libs and/or directories were not found where specified!`, even though nothing in this guide installs `libpsl` and the log shows `pkg-config... no` right above it.**
Most of curl's optional dependencies (brotli, zstd, LDAP, GSS-API, and others) auto-disable with just a `checking for ... no` when they're missing — but PSL (Public Suffix List) support defaults to *on* in curl's `configure`, and its absence is treated as a hard error rather than a silent skip. This build has no need for PSL support. Reconfigure with it explicitly disabled:
```bash
cd /usr/src/curl-8.11.0
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl
make
make install
```
If `configure` had already failed, there's no `Makefile` yet — the `make: *** No targets specified and no makefile found` and `make: *** No rule to make target 'install'` errors right after are just downstream symptoms of the same failed `configure`, not separate problems; they resolve once `configure` succeeds.

**`curl`'s `configure` fails with `configure: error: perl was not found, needed for docs, manual and CA embed`, even though `perl` was built earlier in section 10.1.**
This means `perl` isn't on `PATH` in the current shell (e.g. a fresh terminal that re-entered the chroot without re-running section 9.3, or `perl`'s own `make install` didn't actually complete). Confirm with `perl -v`; if it's missing, rebuild it from the `perl` subsection above. If docs genuinely aren't wanted regardless, the flags below skip them without needing `perl` at all:
```bash
cd /usr/src/curl-8.11.0
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed
make
make install
```
`--disable-docs` covers both the man pages and the built-in `--help` manual (it disables the manual automatically once docs are off); `--without-ca-embed` is unrelated to TLS itself — it only skips baking a copy of the CA bundle into the `curl` binary, which is unnecessary here since `--with-ca-bundle` already points `curl` at `/etc/ssl/cert.pem` on disk.

**`curl -v https://...` shows `CApath: /etc/ssl/certs` (no `CAfile` line at all) and every request fails by default with `SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)`, even though the same request succeeds with `curl --cacert /etc/ssl/cert.pem ...`, and `/etc/ssl/cert.pem` clearly exists with a full set of certificates in it.**
This means the `curl` being run wasn't built with `--with-ca-bundle=/etc/ssl/cert.pem` (section 10.1's flag) — most commonly because it's a *later* rebuild that dropped the flag, e.g. `lambda`'s own `curl` recipe (section 12's `system.json` lists `curl` again, to be reinstalled through `lambda` for a proper manifest) using a generic autotools recipe instead of this guide's explicit one. Without that flag, `curl`'s `configure` falls back to autodetecting a default CA location from a fixed list of common paths, and lands on `/etc/ssl/certs` — which exists only because `openssl`'s own `--openssldir=/etc/ssl` (section 10.1) created it as an empty directory, not because anything in this guide ever populated it with the hashed certificate symlinks (`c_rehash`-style) that CApath-based verification actually needs. An existing-but-empty directory is enough for the autodetection to pick it and stop looking, which is why no `CAfile` ever gets set at all — `/etc/ssl/cert.pem` (the real, populated file from section 9.1/10.1) is simply never found. Confirm which `curl` and flags produced the broken binary:
```bash
curl -V   # note the version — does it match section 10.1's 8.11.0, or something newer?
strings "$(command -v curl)" | grep -E '^/etc/ssl'
```
Fix by rebuilding with the flag explicit, same as section 10.1 — whether that means redoing the hand-built recipe from a clean extraction, or fixing whichever `lambda` recipe produced this one:
```bash
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl
make
make install
curl -v https://dbus.freedesktop.org/ -o /dev/null 2>&1 | grep CAfile   # should now print /etc/ssl/cert.pem
```

**`wget`'s `configure` fails with `configure: error: The pkg-config script could not be found or is too old`, even though `openssl` built fine and `curl` already works with `--with-openssl`.**
Unlike `curl`, `wget`'s `configure.ac` detects OpenSSL by querying it through `pkg-config` (has done so since OpenSSL 1.0.0) instead of falling back to a manual `-lssl -lcrypto` probe — with no `pkg-config` on `PATH` at all, that lookup can't even attempt the fallback and `configure` aborts outright. Build `pkg-config` first (see the `pkg-config` subsection in 10.1, right before `wget`), confirm it's on `PATH` with `pkg-config --version`, then retry:
```bash
cd /usr/src/wget-1.24.5
./configure --prefix=/usr --with-ssl=openssl
make
make install
```

**`git clone https://...` fails with `git: 'remote-https' is not a git command` / `fatal: remote helper 'https' aborted session`, even though `curl` is installed and working.**
Git only compiles its `git-remote-https` helper — the piece that actually implements the `https://` transport — if a usable `curl` was already present *when `git` itself was configured and built*. This is decided once, at Git's own build time, not looked up again later: installing `curl` afterward does not retroactively add HTTPS support to a `git` that was already built without it. This guide's build order (section 10.1: `zlib` → `perl` → `openssl` → `curl` → `pkg-config` → `wget` → `jq` → `gettext` → `git`) is arranged specifically so a TLS-capable `curl` exists before `git`'s build runs — if you built them in a different order (e.g. `git` before `curl`), the fix is to rebuild `git`, not to reinstall `curl`:
```bash
cd /usr/src/git-2.47.0
make clean
make configure
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```
Confirm with a real clone afterward, not just `git --version` (which succeeds either way):
```bash
git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check
```
If the error is instead `Protocol "https" not supported` (helper present, but no scheme handler behind it), that's a different root cause — see the dedicated entry above.

**`curl` to `zlib.net/zlib-<version>.tar.gz` returns `404`.**
`zlib.net` only hosts the current release at that short URL — once a new zlib version ships, the old filename moves to `zlib.net/fossils/zlib-<version>.tar.gz` (or gets replaced by a newer version at the short URL, if this guide's pinned version is now stale). This guide already pins the fossils URL (`https://zlib.net/fossils/zlib-1.3.1.tar.gz`) for exactly this reason. Check [zlib.net](https://zlib.net/) for the current version if this specific pinned version also 404s in the future, and update the version number in sections 9.1 and 10.1 to match:
```bash
curl -fL --retry 3 --retry-delay 2 -o zlib-<newer-version>.tar.gz \
    https://zlib.net/fossils/zlib-<newer-version>.tar.gz
```
