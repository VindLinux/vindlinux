# How to Build Vind Linux (UEFI)

> Hit an error partway through a step? Check [building-troubleshooting.md](building-troubleshooting.md) before assuming something's wrong with your host — it's indexed by section number and covers the failures people actually run into at each step.

This guide builds Vind Linux from a live host, through a working `chroot`, up to a system that is ready to boot on its own. The build is split into two big stages:

- **Phase 1 — Bootstrap.** Cross-compile from the host just enough to get a working `chroot`: musl, a shell, and a compiler that *runs inside* musl. Everything here is built with `--host`/cross flags, which is exactly the kind of setup that produces confusing header/library mismatches (wrong `stdio.h`, wrong `vswprintf` prototype, etc.) — so we keep this phase as small as possible.

  Phase 1 itself builds two compilers, one after the other — this is where the **Pass 1** / **Pass 2** naming used later in this guide comes from:

  - **Pass 1** — a *cross*-compiler that runs on the host and targets musl (section 6). It's scaffolding only, never part of the final system, and can be deleted once Phase 1 is done.
  - **Pass 2** — a *native-target* compiler: still cross-built on the host, but linked against musl so it runs **inside** Vind Linux once you `chroot` in (section 8). This is the compiler Phase 2 starts with.

- **Phase 2 — Native.** `chroot` into Vind Linux and build everything else natively, with a plain `./configure && make && make install`. No cross flags, no `DESTDIR`, no host/target mismatches — this is where the bulk of the system gets built, including `lambda` (Vind Linux's package manager), LLVM/Clang, and eventually the bootloader.

  Phase 2 starts out using the Pass 2 GCC from Phase 1 just long enough to get `lambda` running (section 11) and to build LLVM/Clang (section 12) — GCC's only job is to bootstrap the rest of the toolchain, not to ship as part of it. Once Clang is confirmed working, Vind Linux removes GCC entirely (section 12.5) and builds the whole base system (section 13 onward) with Clang from the start, so nothing in the final system ever needs a second build to get off GCC's ABI.

Packages built by hand early in this guide get reinstalled through `lambda` once it exists, so the system ends up with a proper manifest instead of files dropped in by hand — see section 11 for how `lambda` itself gets built and used.

---

# Phase 1 — Bootstrap

## 1. Prepare the host

We use a Gentoo LiveGUI ISO as the host, since it ships with most tools we need.

Set the host's DNS resolver before anything else in this guide tries to reach the network — `git clone` (section 6), `musl-cross-make`'s own source fetches, and every `wget`/`curl` from here through the end of Phase 1 all depend on it, and a live ISO's default resolver setup can't be relied on (some ship with none configured at all, others hand you whatever the DHCP lease on the install network provided, which may not survive a network change mid-build):

```sh
cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

This is the same pair of resolvers section 15.1 sets up again later, inside the chroot — that one configures the *target* system's `/etc/resolv.conf`, entirely separate from the host's. They happen to live in different files on different filesystems, so setting one doesn't carry over to the other.

## 2. Partition the disk

List your disks and find the target one:

```sh
livecd ~ # lsblk
NAME  MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
fd0     2:0    1    4K  0 disk
loop0   7:0    0    4G  1 loop /run/rootfsbase
sr0    11:0    1  4.2G  1 rom  /run/initramfs/live
vda   253:0    0   50G  0 disk   # <- target disk
```

Partition it:

```sh
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

```sh
livecd ~ # mkfs.fat -F32 /dev/vda1
livecd ~ # mkfs.ext4 /dev/vda3
livecd ~ # mkswap /dev/vda2
```

## 4. Mount the target

```sh
export VIND=/mnt/vind

livecd ~ # mount --mkdir /dev/vda3 $VIND
livecd ~ # mount --mkdir /dev/vda1 $VIND/boot/efi
livecd ~ # swapon /dev/vda2
```

## 5. Create the base rootfs layout

(Adapted from LFS.)

```sh
mkdir -pv "$VIND"/{etc,var}
mkdir -pv "$VIND"/usr/{bin,lib,sbin,include,share,src}

for i in bin lib sbin; do
    ln -sv usr/"$i" "$VIND"/"$i"
done

mkdir -pv "$VIND"/{dev,proc,sys,run,tmp,home,root,mnt,opt}
chmod 1777 "$VIND/tmp"
chmod 1777 "$VIND/var/tmp"
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

Build it inside `$VIND`, not on the live ISO's own disk. The live ISO's root filesystem is usually a small RAM-backed overlay, and a full gcc build writes several gigabytes of files while it works — we'd run out of space partway through if we built it there. `$VIND` is our real 45G disk, so that's where the whole build happens.

```sh
mkdir -p "$VIND/tools-src"
cd "$VIND/tools-src"
git clone https://github.com/richfelker/musl-cross-make
cd musl-cross-make
```

Check free space before starting:

```sh
df -h $VIND
```

Configure it:

```sh
export TOOLS="$VIND/tools"

cat > config.mak << EOF
TARGET = x86_64-pc-linux-musl
OUTPUT = $TOOLS
GCC_VER = 13.3.0
EOF
```

If your host has a broken or non-routable IPv6 setup (common on cloud/VM images — see building-troubleshooting.md), also add a line forcing downloads over IPv4, since `musl-cross-make` fetches its sources itself during `make`:

```sh
echo 'DL_CMD = wget -4 -c -O' >> config.mak
```

- `TARGET` uses the `pc` triple to match LFS-style naming, and it's the name we use to call the compiler everywhere else in this guide.
- `OUTPUT` goes to `$TOOLS` (`$VIND/tools`), not `$VIND/usr`. This toolchain is a build tool, stays in its own folder, and can be deleted entirely once we're done — same idea as LFS's `$LFS/tools`.
- `GCC_VER` is pinned to a modern release instead of `musl-cross-make`'s old default (9.4.0), mainly for general compiler quality, and it does **not**, on its own, avoid the musl/`libstdc++` wide-char issue described in building-troubleshooting.md. That issue is a header-level incompatibility, not a version issue, and it's one more reason C++-heavy builds (like LLVM) are deferred to Phase 2 instead of being cross-built here.

Build and install:

```sh
make -j$(nproc)
make install
```

This builds binutils, a bootstrap gcc, musl, then the final gcc linked against musl. If a previous attempt failed partway through, run `rm -rf build` before retrying.

If `make` or `make install` fails to download a source tarball (`502 Bad Gateway`, connection reset, etc.), or keeps re-downloading one you already fetched by hand — see [building-troubleshooting.md](building-troubleshooting.md).

Should you see a wall of undefined reference to ... errors from ld while building GCC (Pass 1 or later), spread across several seemingly unrelated .o files, this is almost always a parallel build race condition, not a source or configuration bug. See the specific solution in [building-troubleshooting.md](building-troubleshooting.md) before chasing the problem elsewhere.

Put it on your `PATH`:

```sh
export PATH="$TOOLS/bin:$PATH"
```

You'll need to re-run this in any new shell for the rest of Phase 1.

Check it works:

```sh
x86_64-pc-linux-musl-gcc -dumpmachine
# should print: x86_64-pc-linux-musl
```

Compile a test program and confirm it links against musl:

```sh
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

```sh
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ar"     /usr/bin/ar
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-ranlib" /usr/bin/ranlib
ln -sf "$TOOLS/bin/x86_64-pc-linux-musl-strip"  /usr/bin/strip
```

## 7. Cross-build the minimal target system

This is deliberately short: just enough packages, cross-built with the Pass 1 toolchain, to get musl, a shell, basic coreutils, and `make` onto disk so we can `chroot` in and build natively.

```sh
mkdir -pv $VIND/sources
export PREFIX=/usr
export DESTDIR="$VIND"
export CC="$TOOLS/bin/x86_64-pc-linux-musl-gcc"
export HOST=x86_64-pc-linux-musl
export MAKEOPTS=-j$(nproc)
export PATH="$TOOLS/bin:$PATH"
```

If you open a new shell partway through this section, re-export these — otherwise builds silently fall back to the host's own glibc compiler instead of failing loudly (see building-troubleshooting.md).

### 7.1 musl

The C library itself — what every dynamically-linked binary in `$VIND` loads at runtime. Its `configure` script is custom (not autoconf-generated), so it doesn't take `--host`.

Download the source:

```sh
cd "$VIND/sources"
curl -fL --retry 3 --retry-delay 2 -o musl-1.2.5.tar.gz \
    https://musl.libc.org/releases/musl-1.2.5.tar.gz
```

If the official musl server is unavailable, you can use the Void Linux sources mirror instead:

```sh
cd "$VIND/sources"
wget https://sources.voidlinux.org/musl-1.2.5/musl-1.2.5.tar.gz
```

Then extract and build:

```sh
tar -xf musl-1.2.5.tar.gz
cd musl-1.2.5

./configure --prefix="$PREFIX" --syslibdir="$PREFIX/lib"
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```

`--syslibdir` is where the dynamic loader (`ld-musl-x86_64.so.1`) gets installed — `$PREFIX/lib`, i.e. `/usr/lib` inside `$VIND`.

Verify:

```sh
find "$VIND" -name 'ld-musl-x86_64.so.1'
```

This should list a file inside `$VIND/usr/lib`.

If nothing is found, dynamically-linked binaries will not run once you `chroot` into the system. See building-troubleshooting.md.

### 7.2 Busybox

#### Download

```sh
cd "$VIND/sources"

curl -fL --retry 3 --retry-delay 2 \
    -o busybox-1.37.0.tar.bz2 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2

tar -xf busybox-1.37.0.tar.bz2
cd busybox-1.37.0
```

#### Configure

```sh
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
    -e 's/^# CONFIG_NTPD is not set/CONFIG_NTPD=y/' \
    -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
    .config

make clean
```

`CONFIG_NTPD=y` is enabled here — not used anywhere in Phase 1, but section 15.2 relies on `busybox ntpd` for a minimal one-shot clock sync at boot, and it's cheaper to flip this on now than to rebuild Busybox later just for one applet.

#### Build

```sh
CC="$CC" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip \
make $MAKEOPTS
```

Don't pass `--sysroot` here (an earlier draft of this section set `CFLAGS='--sysroot=/' LDFLAGS='--sysroot=/'`). The Pass 1 cross-compiler from section 6 already defaults to its own bundled musl sysroot — that's the entire point of building it with `musl-cross-make`. Overriding it to `--sysroot=/` points the compiler at the **host's** root filesystem instead, i.e. Gentoo's own glibc headers under `/usr/include`, which is exactly the kind of host/target header mismatch section 6 warns about. Busybox is statically linked (`CONFIG_STATIC=y`), so this wouldn't necessarily fail loudly — it can silently pick up glibc struct layouts/macros at compile time while still linking against musl's `crt`/`libc.a`, producing a binary that builds cleanly but misbehaves at runtime. Leave `CFLAGS`/`LDFLAGS` unset and let the cross-compiler use its own default sysroot. If Busybox already built without those flags set but still misbehaves at runtime, see building-troubleshooting.md.

#### Install

```sh
mkdir -p "$VIND/usr/bin"
cp busybox "$VIND/usr/bin/busybox"
chmod 755 "$VIND/usr/bin/busybox"

cd "$VIND/usr/bin"
for cmd in $(./busybox --list); do
    [ "$cmd" = "busybox" ] && continue
    ln -sf busybox "$cmd"
done
```

Verify:

```sh
file "$VIND/usr/bin/busybox"
"$VIND/usr/bin/busybox" | head -1
```

`file` should show the same static/musl signature as the other Phase 1 packages — never a glibc interpreter. Running the binary directly should print its version banner; since it's built static (`CONFIG_STATIC=y`), this works even before `chroot`.

### 7.3 dash

Small, fast POSIX-compliant shell derived from ash. Used as a lightweight `/bin/sh`.

```sh
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

```sh
file "$VIND/bin/dash"
```

Should show `interpreter /lib/ld-musl-x86_64.so.1` (dynamic musl) or no interpreter at all (static) — never `/lib64/ld-linux...` (glibc).

### 7.4 flex

Fast lexical analyzer generator. Required as a bootstrap tool for building packages such as Bison and other parser/lexer generators. 2.6.4 (2017) is still upstream's latest tagged release — there is no newer version to move to.

Flex 2.6.4 requires an existing `flex` executable during `configure`, so the host's `flex` is used only to bootstrap the Vind Linux copy.

**Cross-compiled flex 2.6.4 segfaults on any real input — this needs two `ac_cv_func_*` overrides, not just a plain `./configure`.** With `--host` set, `configure` cannot run a test binary on the build host to check whether `malloc(0)`/`realloc(p, 0)` behave the GNU-compatible way (returning a unique non-NULL pointer instead of `NULL`). Unable to run the check, it assumes the conservative "no" and falls back to gnulib's `rpl_malloc`/`rpl_realloc` wrappers — visible afterward as `HAVE_MALLOC 0` / `HAVE_REALLOC 0` and `#define malloc rpl_malloc` / `#define realloc rpl_realloc` in `config.h`. musl's `malloc`/`realloc` are already GNU-compatible here, so the fallback isn't just unnecessary, it's actively broken: the generated `scan.c` includes `<stdlib.h>` (which musl's headers pull in transitively) *before* `config.h` defines those macros, so `rpl_malloc`/`rpl_realloc` get called with no visible prototype in scope. GCC treats them as implicitly returning `int`, truncates the real 64-bit pointer they return down to 32 bits, and the corrupted pointer segfaults the moment flex actually allocates a scanner buffer — i.e. the instant it processes a real `.l` file, while `--version`/`--help` never touch that code path and look fine. This is a long-standing upstream bug ([flex#247](https://github.com/westes/flex/issues/247), [flex#436](https://github.com/westes/flex/issues/436)) that was never patched into the 2.6.4 tarball. Rather than patch flex's source, tell `configure` the true, correct answer for musl directly so it skips the substitution entirely:

```sh
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

```sh
file "$VIND$PREFIX/bin/flex"
```

Should show `interpreter /lib/ld-musl-x86_64.so.1` (dynamic musl) or no interpreter at all (static) — never `/lib64/ld-linux...` (glibc).

Verify the bootstrap installation — with a real `.l` file, not just `--version`, since that's the only thing that actually exercises the code path the fix above targets:

```sh
"$VIND$PREFIX/bin/flex" --version
"$VIND$PREFIX/bin/lex" --version

printf '%%%%\n.    ECHO;\n%%%%\n' > /tmp/min.l
"$VIND$PREFIX/bin/flex" -o /tmp/min.c /tmp/min.l && echo OK
```

What this check is actually looking for is the absence of a **segfault**, not a guaranteed `OK`. This binary was cross-compiled against musl but is being invoked here on the glibc host, so whether the last command prints `OK` or exits with an error is host-dependent — either outcome is fine. A segfault is not: that's the specific failure this check exists to catch, and it's the one outcome that means the `ac_cv_func_*` overrides above weren't actually applied.

If this still segfaults, check `config.h` in the build tree for `#define malloc rpl_malloc` — its presence means the `ac_cv_func_*` overrides above weren't picked up (a stale `config.cache` from an earlier attempt is the usual cause; `rm -f config.cache` and reconfigure).

The resulting `flex` and `lex` binaries belong to the Vind Linux toolchain and can be used by subsequent package builds.

### 7.5 make

GNU Make. Needed to build anything with a `Makefile` — including everything in Phase 2 — so it has to exist inside `$VIND` before we `chroot` in.

```sh
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

```sh
file "$VIND/usr/bin/make"
```

Same check as before — should show `ld-musl-x86_64.so.1`, not glibc.

### 7.6 binutils

`as` (assembler) and `ld` (linker) — `gcc` doesn't do either of these itself, it shells out to these two. The Pass 1 toolchain has its own copy, but that copy is a **host** binary (runs on glibc, targets musl) — useless once you're inside the chroot, where there's no glibc runtime to run it at all. This one needs to be a musl binary too, cross-built the same way as `make` above, so it actually runs natively inside `$VIND`.

```sh
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

touch /tmp/binutils-marker
make DESTDIR="$DESTDIR" install
```

`--disable-gprofng` skips `gprofng`, a statistical profiler bundled with binutils since 2.38. It doesn't build against musl — it uses `fopen64`/`fseeko64`/`ftello64`, glibc-specific large-file-support functions that musl never needed (musl is 64-bit-only everywhere, so it has no separate `*64` variants to begin with). It's not part of the core toolchain (`ar`, `as`, `ld`, `nm`, `ranlib`, `strip` all build fine without it), so this is the standard fix other musl-based distros use too, rather than patching gprofng's source.

`binutils` is a multi-directory project (`gas`, `libiberty`, `zlib`, `libsframe`, ...), and each subdirectory runs its own `configure`, each doing its own `--build` auto-detection independently. Since `$PATH`/`$CC` are already biased toward the musl cross-compiler at this point (section 7's exports), that auto-detection gets confused for some of these subdirectories — same root cause as the `--build` issue explained in section 8. Passing `--build` explicitly here sidesteps it for all of them at once, rather than letting each subdirectory guess on its own.

Verify:

```sh
file "$VIND/usr/bin/as" "$VIND/usr/bin/ld"
```

Both should show `ld-musl-x86_64.so.1`, not glibc — and definitely not the host's binutils under `$TOOLS`.

This has to be done before entering the chroot (section 9) — without it, `gcc` inside the chroot can produce assembly but has nothing to turn it into an actual object file, which is exactly the `cannot execute 'as'` error you get if this step is skipped. See building-troubleshooting.md if `configure` fails partway through a subdirectory despite `--build` being set explicitly above, or if you're already inside the chroot when you discover this step was skipped.

#### 7.6.1 Recording a manifest for later removal

Like the Pass 2 GCC in section 8, this `binutils` was installed by hand, outside `lambda` entirely, so there's no package manifest tracking which files belong to it. Once Clang/LLD provide their own equivalents for `as`/`ld`/`ar`/`nm`/`ranlib`/`strip` and are confirmed working, this native GNU `binutils` can be removed the same way section 12.5 removes GCC — by deleting exactly the files this install wrote, not by asking `lambda` to `purge` a package it never installed. Build that file list now, while `/tmp/binutils-marker` (created just before `make install` above) still marks the exact instant this install started writing into `$VIND`:

```sh
mkdir -p "$VIND/var/log"

find "$DESTDIR" \( -type f -o -type l \) -newer /tmp/binutils-marker \
    | sed "s|^$DESTDIR||" \
    > "$VIND/var/log/binutils.manifest"
```

Same technique as section 8.1: `find -newer` catches every file `make install` wrote as a before/after snapshot rather than anything parsed out of build output, and the `sed` strips the `$DESTDIR` (i.e. `$VIND`) prefix so the manifest stores paths the way they'll actually be seen once you're inside the chroot (`/usr/bin/as`, not `/mnt/vind/usr/bin/as`). The manifest lives at `$VIND/var/log/binutils.manifest`, i.e. `/var/log/binutils.manifest` once you `chroot` in — keep it there until you're actually ready to remove this binutils, the same way `gcc-pass2.manifest` sits unused between section 8.1 and section 12.5.

Unlike GCC, this guide doesn't remove `binutils` anywhere yet — `ar`/`as`/`ld`/`nm`/`ranlib`/`strip` are still relied on directly by name in several places after this point (section 8's build and `lambda`'s own recipes, among others). Treat this manifest as prep work for a future cleanup pass once LLVM's tools are confirmed to cover everything this system actually needs, not as something section 12 or 13 acts on automatically.

### 7.7 Linux kernel headers

`musl` (section 7.1) is the C library, but it doesn't bundle the full Linux UAPI header surface — `linux/*.h`, `asm/*.h`, `asm-generic/*.h`. On a glibc-based host these normally come from a separate `linux-headers` package that the distro already has installed alongside glibc; nothing in this guide has installed the equivalent into `$VIND` yet. Most of what's built so far doesn't need them, but some packages later (OpenSSL's secure-heap code in particular, which reaches for `linux/mman.h`) do, and the failure if this step is skipped is a plain `fatal error: linux/mman.h: No such file or directory` deep inside a Phase 2 build — by which point there's no `curl` yet inside the chroot to fetch the fix. Do it now, from the host, the same way `musl` itself was populated into the sysroot:

```sh
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

```sh
find "$VIND/usr/include/linux" -name mman.h
```

Should print a path inside `$VIND/usr/include/linux`. If it doesn't, OpenSSL's build in section 10.1 will fail with `fatal error: linux/mman.h: No such file or directory` partway through — see building-troubleshooting.md.

## 8. Pass 2 — native-target GCC (built on the host)

This is the step that lets us stop cross-compiling. We use the Pass 1 toolchain (still running on the host) to build *another* GCC — one that, once built, is itself a musl binary that runs **inside** Vind Linux. That compiler is what we'll use natively after `chroot`.

This is a "cross-native" build: `--build` is the host triple, `--host` and `--target` are both the musl triple. It's a standard pattern (Cross-LFS uses the same approach for glibc).

`configure` can't be trusted to detect `--build` on its own here: by this point `$CC` and `$PATH` are set up (from section 7) to favor the musl cross-compiler, so `config.guess`'s auto-detection — and even `configure`'s own default choice of compiler for build-time tools — end up pointing at the musl compiler instead of the host's real glibc `gcc`. That produces `checking build system type... x86_64-pc-linux-musl` (wrong) and later `cannot run C compiled programs`, since the live ISO can't execute musl binaries directly. Passing the build triple and `CC_FOR_BUILD` explicitly sidesteps the auto-detection entirely:

```sh
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

touch /tmp/gcc-pass2-marker
make DESTDIR="$DESTDIR" install
```

`/tmp/gcc-pass2-marker` is a plain timestamp file, created on the host right before `make install` writes anything into `$VIND`. It has no purpose yet on its own — section 8.1 below uses it to work out exactly which files this install touched.

- `/usr/bin/gcc -dumpmachine` (absolute path) gives the real host triple without going through `config.guess`, which is unreliable here since the shell environment is deliberately biased toward the cross-compiler.
- `CC_FOR_BUILD=/usr/bin/gcc` makes sure the build-time tools (which run *now*, on the live ISO) use the host's native compiler — only the final target compiler uses the musl cross-compiler.
- `--with-build-sysroot="$VIND"` tells this GCC where to find musl's headers and libs (already installed in section 7.1) while it's being built on the host. This is different from `--with-sysroot`, which would bake that same absolute host path (`$VIND`, e.g. `/mnt/vind`) into the compiler as its permanent default — breaking it the moment you `chroot` in, since that path stops meaning anything once `$VIND` becomes `/`. `--with-build-sysroot` only affects this build; the resulting compiler defaults to sysroot `/`, which is exactly right once it's running natively inside the chroot. (If `--with-sysroot` gets used by mistake here, the symptom shows up later, inside the chroot, as headers not found at paths that clearly exist — see building-troubleshooting.md.)
- `--disable-bootstrap` skips GCC's usual 3-stage self-bootstrap, which doesn't apply here since we're cross-building it once.

If `configure`/`make` for this step picks up the host's glibc headers instead of musl's (`CPATH`/`C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH` set in the shell are the usual cause), or if `libstdc++` itself fails to build with a `__to_xstring`-related error, see building-troubleshooting.md — both are covered there.

Verify the result is actually a musl binary meant to run inside the chroot, not the host:

```sh
file "$VIND/usr/bin/gcc"
```

A lot of build systems (`configure` scripts especially) look for a compiler named plain `cc`/`c++`, not `gcc`/`g++` specifically. Symlink those now, still from the host, so anything expecting the generic names finds them once you're inside the chroot:

```sh
ln -sf gcc "$VIND/usr/bin/cc"
ln -sf g++ "$VIND/usr/bin/c++"
```

### 8.1 Recording a manifest for later removal

The whole reason Pass 2 GCC gets built at all is to bootstrap LLVM/Clang (section 12) — nothing in the final system is meant to depend on it afterward (section 12.5 removes it). Since this GCC was installed by hand, outside `lambda` entirely, there's no package manifest anywhere tracking which files belong to it. Build one now, while `/tmp/gcc-pass2-marker` (created just before `make install` above) still marks the exact instant this install started writing into `$VIND`:

```sh
mkdir -p "$VIND/var/log"

find "$DESTDIR" \( -type f -o -type l \) -newer /tmp/gcc-pass2-marker \
    | sed "s|^$DESTDIR||" \
    > "$VIND/var/log/gcc-pass2.manifest"

echo /usr/bin/cc  >> "$VIND/var/log/gcc-pass2.manifest"
echo /usr/bin/c++ >> "$VIND/var/log/gcc-pass2.manifest"
```

- `find -newer /tmp/gcc-pass2-marker` catches every file GCC's own `make install` wrote, without needing GCC's build system to cooperate or print anything — it's a before/after snapshot, not something parsed out of build output.
- The `sed` strips the `$DESTDIR` (i.e. `$VIND`) prefix from each path, so the manifest stores paths the way they'll actually be seen once you're inside the chroot (`/usr/bin/gcc`, not `/mnt/vind/usr/bin/gcc`).
- The `cc`/`c++` symlinks created just above are already covered by running `find` after them, since `-newer` catches symlinks too — the two `echo` lines are there anyway, so the manifest stays correct even if a future edit moves the symlink step around.
- The manifest lives at `$VIND/var/log/gcc-pass2.manifest`, which is just `/var/log/gcc-pass2.manifest` once you `chroot` in — section 12.5 reads it from there to remove GCC without routing it through `lambda` at all.

This is deliberately a plain file list, not a `lambda` package: GCC is a bootstrap tool this guide needs *once*, not a package Vind Linux ships, so it doesn't need `lambda`'s dependency tracking, versioning, or upgrade path — just a reliable way to know what to delete.

---

# Phase 2 — Native builds inside the chroot

## 9. Enter the chroot

### 9.1 Pre-fetch what lambda's prerequisites need

Before entering the chroot, there's a chicken-and-egg problem worth heading off: section 10.1 builds `zlib`, `perl`, `openssl`, `curl`, `wget`, `jq`, and `git` *inside* the chroot, but their recipes use `curl` to download the source — and `curl` doesn't exist yet in there. Nothing inside a fresh chroot can reach the network at all.

Fetch these now, from the host (which already has `curl` and a trusted set of CA certificates), straight into `$VIND` — since `$VIND` becomes `/` once you're inside the chroot, anything you put here now is just there waiting for you:

```sh
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

```sh
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

`tar -tzf` only proves the archive isn't truncated or an HTML error page — it says nothing about whether the bytes are actually what upstream published. A mirror can serve a structurally valid, complete tarball that's still the wrong one (compromised mirror, MITM on a plain-HTTP fallback, stale cache serving an old CVE-affected release). This matters more here than in a normal package install, because everything in this batch runs with root privileges the moment it's built (`make install` as root inside the chroot), and `openssl`/`curl` specifically become the TLS trust anchor for every download after them — a tampered copy of either one undermines every "we verified this over HTTPS" claim made later in this guide. Check each archive's hash against the one upstream publishes before extracting:

```sh
sha256sum zlib-1.3.1.tar.gz perl-5.40.0.tar.gz openssl-3.5.7.tar.gz \
    curl-8.11.0.tar.gz pkg-config-0.29.2.tar.gz wget-1.24.5.tar.gz \
    jq-1.7.1.tar.gz git-2.47.0.tar.xz gettext-0.22.5.tar.gz
```

Compare the output against the `SHA256SUMS`/checksum file each project publishes next to its release (linked from the same release page as the tarball itself) — this guide doesn't pin the hashes inline since they change every time a version in this guide is bumped, but the comparison itself should never be skipped for anything landing outside the chroot's own `curl`-verified HTTPS chain. The same applies to every other hand-fetched tarball earlier in this guide (musl in 7.1, busybox in 7.2, flex in 7.4, and so on) — this note is placed here because 9.1 is the last batch fetched from the host rather than through the chroot's own (by-then-trusted) `curl`, but the habit should start in Phase 1, not here.

`cacert.pem` isn't source code — it's the [Mozilla CA bundle that the curl project mirrors](https://curl.se/ca/cacert.pem) specifically for bootstrapping cases like this one. Nothing inside the chroot can be trusted to fetch its *own* trust store over HTTPS before it has one, so this rides in from the host the same way the tarballs do; section 10.1 (`openssl`) installs it as the default CA file once OpenSSL exists to use it.

The download order above matches the build order in section 10.1, not alphabetical — `perl` and `openssl` come before `curl`/`wget`/`pkg-config` on purpose (curl/wget need a real TLS backend to build against), `pkg-config` comes right before `wget` (see 10.1 for why it's needed there specifically), and `openssl`/`curl` are both built well before `git` (see 10.1 for why).

Once curl itself is built inside the chroot (in 10.1), downloading from within the chroot works normally for everything after that — this pre-fetch step is only needed for these.

### 9.2 Mount and chroot in

Mount the virtual filesystems the chroot needs, then enter it:

```sh
mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"

chroot "$VIND" /bin/dash
```

`/bin/ash` (from Busybox, section 7.2 — built with `CONFIG_ASH=y`) works here too, and is already present at this point regardless of whether dash's own build succeeded: `chroot "$VIND" /bin/ash`. Either shell is fine for everything in this guide; use whichever is actually on disk.

### 9.3 Reset the environment for native builds

`chroot` only changes the filesystem root — it does **not** clear environment variables. Every Phase 1 export (`CC`, `PREFIX`, `DESTDIR`, `HOST`, `TOOLS`, and the `$TOOLS/bin`-prefixed `PATH`) is still set in this shell, and now points at things that don't work inside the chroot: `$CC` is still the Pass 1 cross-compiler's absolute host path, which `configure` scripts will use directly (`autoconf`'s `AC_PROG_CC` prefers an already-set `$CC` over searching `PATH` itself) — and that binary can't even execute here, since it's a glibc-linked binary and this chroot has no glibc runtime, only musl. Left in place, this produces `configure: error: C compiler cannot create executables` on the very first package you try to build (see building-troubleshooting.md if this happens in a later shell that skipped this reset).

`$DESTDIR` is the more dangerous one of these, because leaving it set doesn't fail loudly. It's still `$VIND` (e.g. `/mnt/vind`) from section 7, and most `make install` targets honor `$DESTDIR` automatically without you passing it explicitly. Since you're now *inside* the chroot, that same string is just a path — `make install` happily creates `/mnt/vind/usr/lib` etc. as an ordinary, empty subdirectory of the chroot itself, and installs everything there instead of into the real `/usr/lib`. The build succeeds, `make install` reports no error, and the package is simply missing from where anything else will ever look for it (see building-troubleshooting.md).

Clear the Phase 1 (host/cross) variables, then set the native ones this chroot actually needs. Every build in Phase 2 assumes both halves of this have already run:

```sh
unset CC CXX PREFIX DESTDIR HOST TOOLS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/usr/lib/llvm/22/bin"
export CC=gcc
export CXX=g++
export CFLAGS="-I/usr/include"
export CPPFLAGS="-I/usr/include"
export LDFLAGS="-L/usr/lib"
```

- `CC`/`CXX` are set explicitly (not just left to `configure`'s auto-detection) because a couple of packages later in this guide — zlib's custom `configure` in particular — don't reliably search `PATH` on their own and abort with `Missing or broken C compiler.` without it.
- `CFLAGS`/`CPPFLAGS`/`LDFLAGS` point at `/usr/include` and `/usr/lib` — the real paths *inside* the chroot (remember, `$VIND` no longer means anything in here; it's just `/`). These are already the default search paths for a native compiler, so this isn't strictly required for every package, but it removes a class of "header exists but isn't found" failures for anything that doesn't pass its own `-I`/`-L` (see building-troubleshooting.md) and costs nothing to set once, up front.
- `CPATH`/`C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH` are unset defensively — if any of these leaked in from a Phase 1 shell (they aren't set anywhere in this guide, but are easy to pick up from a host's own `/etc/profile` or similar), they'd get searched before the sysroot and can reproduce the same "header exists but isn't found" symptom.

Confirm it's now picking up the Pass 2 compiler from section 8, not the Pass 1 one:

```sh
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

```sh
cd /usr/src
tar -xf zlib-1.3.1.tar.gz
cd zlib-1.3.1

export CC=gcc
./configure --prefix=/usr
make
make install
```

zlib's `configure` is a custom script (not autotools). Unlike the autotools scripts used everywhere else in this guide, it doesn't reliably search `PATH` for a compiler on its own — even with a perfectly working `gcc` on `PATH` (confirm with `gcc --version`), it can still abort with `Missing or broken C compiler.` unless `$CC` is set explicitly first, hence the `export CC=gcc` above (already set as part of section 9.3, but harmless to repeat; see building-troubleshooting.md if it still aborts). `--prefix` works the same as with autotools, though. Only needed here because git's build requires it unconditionally — nothing else in this guide links against it yet. `zlib.net` only serves the *current* release at the short URL pattern (`zlib.net/zlib-<version>.tar.gz`); older releases, including this one, live under `zlib.net/fossils/zlib-<version>.tar.gz` instead — see building-troubleshooting.md if the pinned version here goes stale too.

zlib is a library, not a program — there's no `zlib` command to run afterward. Verify the install landed in the right place instead:

```sh
ls /usr/include/zlib.h /usr/lib/libz.so.1.3.1
```

If this comes back `No such file or directory` even though `make install` reported no error, `$DESTDIR` was still set from Phase 1 and everything got installed one level too deep, under `/mnt/vind/usr/...` instead of `/usr/...` — see building-troubleshooting.md.

#### perl

Needed only so OpenSSL's `Configure` script (a Perl script, not autoconf-generated) has something to run — nothing else in this bootstrap batch calls `perl` directly.

```sh
cd /usr/src
tar -xf perl-5.40.0.tar.gz
cd perl-5.40.0

./Configure -des -Dprefix=/usr
make
make install
```

`-des` tells Perl's own (non-autoconf, non-autotools) `Configure` script to accept its defaults (`-d`) silently, without an interactive Q&A session (`-e`, `-s`) — fine for a build-time-only Perl that nothing else in this guide depends on directly. Verify:

```sh
perl -v
```

#### openssl

This is what actually gives `curl`/`wget` — and, transitively, `git` — real HTTPS support: a TLS library, not just an HTTP client. It needs the `perl` built just above to run its own `Configure` script; there's no autotools/CMake alternative for OpenSSL's build system, the same way there's none for musl's. See building-troubleshooting.md if `Configure` can't find `perl` even though it was just built.

```sh
cd /usr/src
tar -xf openssl-3.5.7.tar.gz
cd openssl-3.5.7

./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared
make
make install
```

- `--libdir=lib` overrides OpenSSL's own default, which is not simply `--prefix/lib`: for the `linux-x86_64` target, `Configure` assumes a multilib layout and picks `lib64` for the actual shared objects (visible in the build log as e.g. `-DENGINESDIR="\"/usr/lib64/engines-3\""`), the same convention a multilib glibc distro uses to keep 32-bit and 64-bit libraries apart. Vind Linux has no such split — section 7.1 installed musl itself straight into `/usr/lib` (`--syslibdir="$PREFIX/lib"`), and nothing in this guide ever creates a `/usr/lib64`. Left at its default, `make install` drops `libssl.so`/`libcrypto.so` into a `/usr/lib64` that nothing else uses or looks in, and every program linked against them — starting with the `openssl` binary itself — fails at startup with `Error loading shared library libssl.so.3: No such file or directory`, even though the file exists, just one directory over. `--libdir=lib` makes `Configure` install everything into `/usr/lib` instead, matching where musl's dynamic loader actually searches by default. (If a *later* rebuild of OpenSSL — by hand or through a `lambda` recipe — drops this flag, the same symptom comes back; see building-troubleshooting.md.)
- `--openssldir=/etc/ssl` is separate from `--prefix`: `--prefix` is where the libraries, headers, and the `openssl` binary itself go (`/usr/lib`, `/usr/include`, `/usr/bin`), while `--openssldir` is where OpenSSL looks for its trust store by default — a cert file at `$OPENSSLDIR/cert.pem` and a hashed cert directory at `$OPENSSLDIR/certs`. Getting these mixed up (or omitting `--openssldir`, which defaults to something under `--prefix`) is a common cause of "TLS handshake succeeds but every certificate fails to verify."
- `shared` builds `libssl.so`/`libcrypto.so`, matching the shared-by-default build of `zlib` above — `curl`/`wget` link against these dynamically rather than being statically bundled.

Install the CA bundle pre-fetched in section 9.1 as OpenSSL's default trust store. Without this step, OpenSSL (and anything linked against it) can complete a TLS handshake but has no certificates to check it against, and every `https://` request still fails, just with a certificate-verification error instead of a protocol error:

```sh
mkdir -p /etc/ssl
cp /usr/src/cacert.pem /etc/ssl/cert.pem
```

Verify:

```sh
openssl version
```

#### curl

```sh
cd /usr/src
tar -xf curl-8.11.0.tar.gz
cd curl-8.11.0

./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed
make
make install
```

`--with-openssl` links this `curl` against the `openssl` built just above, instead of curl's older default of building with no TLS backend at all — without a TLS backend, `curl`/`libcurl` don't merely "prefer HTTP," they have no code path for the `https://` scheme whatsoever, and reject it outright. `--with-ca-bundle=/etc/ssl/cert.pem` points this `curl` at the CA bundle installed alongside `openssl` above; without it, `curl` falls back to a compile-time guess about where the trust store lives that doesn't match this layout, and certificate verification fails even though the handshake itself works. `--without-libpsl` is needed even though nothing earlier in this guide installs `libpsl` and `pkg-config` isn't present either: most of curl's optional dependencies (brotli, zstd, LDAP, GSS-API, ...) degrade gracefully to "not found, feature disabled" when absent, but PSL (Public Suffix List, used for cookie-domain checks) is treated as on-by-default and its absence is a hard `configure: error: libpsl libs and/or directories were not found where specified!` unless explicitly disabled — this build doesn't need PSL support for anything (see building-troubleshooting.md if `configure` still fails on this after adding the flag, or if `perl` can't be found despite being installed just above).

`--disable-docs` and `--without-ca-embed` are no longer *forced* by a missing `perl` the way they would have been earlier in this guide — `perl` is already installed by this point (it's a dependency of `openssl`, built two steps above). They're kept here purely for minimalism: `--disable-docs` skips man pages and the built-in `--help` manual, which this bootstrap `curl` doesn't need; `--without-ca-embed` skips baking a copy of the CA bundle directly into the `curl` binary, since `--with-ca-bundle` above already points it at a CA file on disk, so an embedded copy would just be redundant weight. From here on, `curl` works inside the chroot for both plain HTTP and `https://`, so any package after this point can go back to the normal Download step from section 10.

Verify:

```sh
curl --version
curl -sI https://github.com
```

The first line confirms `curl` reports an `OpenSSL` (not `none`/no-TLS) build; the second is the actual proof it works, since it's a real `https://` handshake against a live server rather than just a linked-library check.

#### pkg-config

Needed only so `wget`'s `configure` (next) can find the `openssl` built above — nothing else in this bootstrap batch calls `pkg-config` directly, and `curl`'s own `configure` above didn't need it.

```sh
cd /usr/src
tar -xf pkg-config-0.29.2.tar.gz
cd pkg-config-0.29.2

./configure --prefix=/usr --with-internal-glib
make
make install
```

`--with-internal-glib` builds against the minimal copy of `glib` vendored inside pkg-config's own tarball instead of linking a system `glib` — nothing in this guide installs `glib` at any point, and pulling in the real thing would drag in a much bigger dependency chain than this one bootstrap tool is worth. Verify:

```sh
pkg-config --version
```

#### wget

```sh
cd /usr/src
tar -xf wget-1.24.5.tar.gz
cd wget-1.24.5

./configure --prefix=/usr --with-ssl=openssl
make
make install
```

Same `openssl` as `curl` above, but detected differently: `wget`'s `configure` looks for OpenSSL via the `pkg-config` built just above (see that subsection for why `curl` doesn't need this same step) rather than a manual library probe — see building-troubleshooting.md if `configure` still can't find it. `wget` picks up OpenSSL's default trust store (`/etc/ssl/cert.pem`, set via `--openssldir` when `openssl` was built) automatically, so there's no separate `--with-ca-bundle`-equivalent flag to pass here the way there was for `curl`.

Verify:

```sh
wget --version
```

Should report `+https` in its feature list — if it shows `-https` instead, `pkg-config` didn't actually find `openssl` at configure time even though it built without error; see building-troubleshooting.md.

#### jq

```sh
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

```sh
cd /usr/src
tar -xf gettext-0.22.5.tar.gz
cd gettext-0.22.5

./configure --prefix=/usr --disable-shared
make
make install
```

`--disable-shared` keeps this to a static build — nothing else in this minimal bootstrap links against `libgettextlib`/`libgettextpo` dynamically, and it avoids adding another `.so` to track before `lambda` exists to manage it. If you don't need `msgfmt` for anything beyond Git, skip this package entirely and use `--disable-nls` in Git's `configure` instead (see below) — that's the path this guide follows by default, to keep this batch of hand-built prerequisites as small as possible.

If you did build it, verify:

```sh
msgfmt --version
```

#### git

Built last in this batch, after `perl`/`openssl`/`curl`/`wget`/`jq` — see the build-order note above. `git clone` over `git://` or local paths would work regardless of order, but `git clone https://...` only works if `curl` — built with real TLS support — already existed when `git` itself was configured and built.

Git's build also defaults to compiling `git-gui` and other Tcl/Tk-based tools, and to building translated message catalogs with `msgfmt` — neither of which exists yet in this minimal chroot, and neither of which is needed for a minimal bootstrap. Skip both explicitly:

```sh
cd /usr/src
tar -xf git-2.47.0.tar.xz
cd git-2.47.0

make configure
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```

Git's own `INSTALL` doc recommends `make configure` (it generates `./configure` from `configure.ac`) over a plain autoconf-generated one — its `Makefile` already probes for available features via `uname` and doesn't need a full autoconf `configure` to work correctly. `--disable-nls` (plus `NO_GETTEXT=1` on the `make` line, since Git's `Makefile` checks for this independently of what `configure` decided) skips the `msgfmt`-built message catalogs entirely, which is what actually caused the `Error 127` — nothing in this guide builds `gettext`/`msgfmt` by default (see above if you'd rather build it instead of skipping translations). `--without-tcltk` (plus `NO_TCLTK=1`) skips `git-gui`/`gitk`, which need Tcl/Tk — also not built anywhere in this guide, and not needed for a minimal, script-driven bootstrap. Since `curl` was already built — with real TLS support — earlier in this same section, `configure` should auto-detect it and compile in `git-remote-https`, and that helper should actually be able to complete an `https://` handshake rather than just exist. Verify with `git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check` once installed (see building-troubleshooting.md if this fails with `Protocol "https" not supported` or with `remote helper 'https' aborted session` — they're different failures with different fixes).

If `git`'s `make` fails with `fatal error: zlib.h: No such file or directory`, or with `MSGFMT po/bg.msg` / `Error 127` — see building-troubleshooting.md, both are covered there.

#### resolv.conf

Before we can clone the `lambda-manager` repo, we need a valid `resolv.conf` so DNS resolution actually works.

```sh
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

```sh
cd /usr/src
git clone https://github.com/VindLinux/lambda-manager
```

Then pull in the actual package recipes — a separate repo, since `lambda` itself ships with none:

```sh
git clone https://github.com/VindLinux/packages
cp packages/packages/* lambda-manager/packages/
```

Finally, install:

```sh
cd lambda-manager
./install.sh
```

Run it as-is, without `sudo` — everything in this guide happens as root inside the chroot already, and nothing built anywhere in this guide provides a `sudo` binary (Busybox's applet list in section 7.2 doesn't enable one), so prefixing this with `sudo` just fails with a "not found"/`applet not found` error rather than doing anything useful.

Check it's working:

```sh
lambda --help
```

### 11.2 Before using

`lambda`'s default `make.conf` template uses `clang` as `CC` and `clang++` as `CXX`. Clang doesn't exist yet at this point in the guide — only the Pass 2 GCC from section 8 — so override it to GCC for now:

```sh
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

```sh
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

```sh
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

**This list is aspirational at this exact point in the guide, not yet true.** Nothing built so far installs real GNU `bash`, `coreutils`, `tar`, `gzip`, or `sed` — the chroot is still running on Busybox's applets (section 7.2: `ash` as `/bin/sh`, plus its built-in `cp`/`tar`/`sed`/`grep`/etc.) and `dash` as the interactive shell. That's been enough to get here, since every step through section 11 only ever needed a POSIX-ish shell and the specific applets Busybox's `defconfig` enables. The recipe convention above describes where Vind Linux is *heading* — full GNU tool names on `PATH`, matching what most upstream `configure`/build scripts assume — not the state of the system in this chroot right now. Section 13's package list closes that gap by installing the real `bash` and `coreutils` (plus `gzip`/`grep`/`sed`, which Busybox's applets don't cover in this guide's `.config`) through `lambda` itself, so by the time you're writing your own recipes and relying on this convention, it's actually accurate. Until section 13 finishes, treat any recipe step that assumes GNU-specific flags (long options Busybox's applets don't implement, GNU `sed -i` with a backup suffix, etc.) as untested in this shell.

Everything else — `zlib`, `ncurses`, `meson`, `cmake`, whatever a package actually needs — gets listed explicitly, even if it happens to already be present from an earlier step in this guide. The rule of thumb: if it's part of the guaranteed bootstrap toolchain, omit it; if it's a library or tool the package actually needs to build, list it.

### 11.6 DESTDIR

`lambda` supports installing into an alternate root, same idea as the `DESTDIR="$VIND"` pattern from Phase 1:

```sh
DESTDIR=/some/path lambda install vim
```

Not needed for anything in this guide (we're already native inside the chroot by this point), but relevant if this whole process ever gets restarted from a different host, or used to stage a second Vind Linux install.

---

## 12. Bootstrapping Clang/LLVM

An earlier pass of this guide built the entire base system first (the full package list now in section 13) under GCC, and only switched to Clang afterward. That ordering has a real problem: everything installed under GCC links against `libstdc++`, and switching `make.conf` to Clang afterward doesn't retroactively relink anything already on disk — it only affects packages built *after* the switch. Any C++ package caught on the wrong side of that line stays permanently mismatched with the rest of the system's `libc++`/`libc++abi` ABI (different exception-unwinding mechanism, different internal layouts for types like `std::string`), silently, until something actually tries to link across that boundary. Rather than document that as a known footgun, this section moves Clang's bootstrap ahead of the base system entirely: the only thing built under GCC is LLVM itself, and everything from section 13 onward is compiled with Clang from its very first build. Nothing gets built twice, and nothing ends up on the wrong side of an ABI line.

### 12.1 Build LLVM/Clang under the Pass 2 GCC

Replace `/etc/lambda/system.json` with a minimal list — just enough to get Clang onto disk, not the rest of the system yet:

```sh
cat > /etc/lambda/system.json <<'EOF'
{
  "packages": [
    "llvm",
    "clang-config"
  ]
}
EOF

lambda reconcile
```

GCC is deliberately **not** in this list. The Pass 2 compiler on disk (section 8) was installed by hand, outside `lambda` entirely — bringing it into the manifest here would mean `lambda` builds and installs a second, separately-tracked copy of GCC just so there's something for it to purge later, redoing a slow C/C++ bootstrap build for a compiler this guide already has, and needs only long enough to build one thing. Section 8.1 covers this instead: it already recorded, by hand, exactly which files the Pass 2 install wrote into `$VIND`. Section 12.5 removes GCC by deleting those files directly, and doesn't need `lambda` to have ever heard of it.

`llvm` has to be built under GCC — there's no way around that chicken-and-egg step. LLVM's own build system needs a working C++ compiler to compile itself, and the only one that exists anywhere in the system at this point is the Pass 2 GCC, sitting on disk at `/usr/bin/gcc` (or reached via the `cc`/`c++` symlinks) — `lambda`'s `llvm` recipe finds it there and uses it the same way it would use any other compiler on `$PATH`, whether or not GCC itself is in `system.json`. This is also why the list above is so short: LLVM is the *only* real package this guide needs GCC for. Everything else — all thirty-some packages in section 13 — has no such requirement and gains nothing from being built before Clang exists.

This step is still going to take a while (LLVM is a large codebase), but it's a small fraction of the time section 13's full reconcile takes, and unlike the old ordering, none of this work gets redone later.

### 12.2 Switch the build environment to Clang

`lambda`'s default `make.conf` template assumes Clang (`CC=clang`, `CXX=clang++`); section 11.2 overrode it to GCC so 12.1's `llvm` build had a known-good, already-native compiler to work with. Now that Clang exists, switch back:

```sh
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

```sh
which clang clang++
clang --version
```

### 12.3 Build the C++ runtime with Clang: libc++ and libc++abi

GCC's C++ runtime (`libstdc++`) and Clang's (`libc++`) aren't interchangeable at the ABI level, so a Clang-based system needs its own. Build and install them through `lambda`, now that `make.conf` points at Clang — `lambda mutate append` adds they to `system.json` and `lambda reconcile` install them so they stay tracked going forward:

```sh
lambda mutate append libc++ libc++abi
lambda reconcile
```

### 12.4 Verify Clang can build packages on its own

Before removing GCC, confirm Clang is actually capable of standing on its own — both as a compiler and for linking against the new `libc++`:

```sh
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

Then confirm `lambda reconcile` itself works end-to-end with Clang as the active compiler. `curl` is a good candidate for this — it's been sitting on disk since section 10.1, hand-built and untracked, exactly the kind of package the intro promised would eventually get "reinstalled through `lambda` once it exists." Folding it into the manifest now, under Clang, does double duty as both the verification step and that promised cleanup:

```sh
lambda mutate append curl
lambda reconcile
```

If both of these succeed, Clang is genuinely doing the compiling from here on, not just sitting on disk unused. Whatever recipe `lambda` used to rebuild `curl` here should still pass `--with-ca-bundle=/etc/ssl/cert.pem` the way the hand-built one in section 10.1 did — if it doesn't, `curl` silently falls back to autodetecting a CA path and TLS verification breaks in a way that's easy to miss (see building-troubleshooting.md).

### 12.5 Remove GCC

With Clang confirmed working, GCC has done its job: it built musl, itself (twice, in Phase 1), and LLVM/Clang. Nothing else in Vind Linux is meant to depend on it — and because section 13's base system hasn't been touched yet, removing GCC now means nothing installed from this point forward was ever built with it. GCC was never in `lambda`'s manifest (section 12.1), so there's nothing to `purge` — instead, delete exactly the files section 8.1 recorded:

```sh
xargs -a /var/log/gcc-pass2.manifest rm -f
rm -f /var/log/gcc-pass2.manifest
```

`xargs -a` reads the manifest one path per line and hands each to `rm -f`, which is quiet about paths that don't exist — harmless here, but worth knowing if the manifest ever ends up stale (a re-run of section 8 without regenerating it, for instance). Deleting the manifest file afterward isn't required for anything later in this guide, but there's no reason to leave a list of already-deleted paths lying around either.

Confirm it's actually gone:

```sh
which gcc      # should print nothing
gcc --version  # should fail: command not found
clang --version
```

From this point on, Clang/LLVM is the only compiler in Vind Linux's final system state — `gcc` will not appear in `system.json`, on disk, or in `lambda`'s manifest again unless deliberately reinstalled. If a specific package in section 13 turns out to genuinely need GCC (a GNU extension Clang doesn't accept, for instance), rebuilding it the way section 8 did and repeating this removal afterward is the only path back — there's no `lambda mutate append gcc` shortcut anymore, since GCC was never a `lambda` package to begin with.

## 13. Installing the base system

With Clang in place and GCC gone, the rest of the base system installs through `lambda` the same way `llvm`/`libc++`/`libc++abi`/`curl` just did — except this time every package in the list below compiles against `libc++`/`libc++abi` from its very first build, not as a later rebuild. That's the entire payoff of doing section 12 first: this reconcile only needs to happen once.

Replace `/etc/lambda/system.json` with the full base package set below, then reconcile. This is going to take a long time — `lambda reconcile` resolves and builds this entire list from source. `llvm`, `libc++`, `libc++abi`, and `curl` are already installed from section 12 and stay listed here since `system.json` describes the system's whole desired state, not just what's new; leaving them out would tell `lambda` to remove them. `gcc` is deliberately *not* in this list — it was never a `lambda` package to begin with (section 12.1), section 12.5 already deleted it from disk, and it should stay that way.

`bash`, `gzip`, `grep`, `sed`, and `tzdata` are included for the same reason discussed in section 11.5: the recipe convention of treating those first five as an already-guaranteed bootstrap toolchain only becomes true once they're actually installed, and this is where that happens. Once `lambda reconcile` finishes, real GNU `bash` replaces `dash`/`ash` as the interactive shell and `/bin/sh` (update `/etc/passwd`'s shell field and the `EOF`-terminated `#!/bin/sh` assumption in `/etc/profile` if you want `bash` as the default rather than just available), and GNU `gzip`/`grep`/`sed` shadow the Busybox applets of the same name earlier in `$PATH`. `tzdata` provides the `/usr/share/zoneinfo` database that section 14.5 (timezone) and any package doing real date/time handling need — nothing before this point in the guide installs it, and musl's own C library has no bundled zoneinfo data the way some libc's do.

```sh
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
```

Then reconcile:

```sh
lambda reconcile
```

Run `lambda reconcile` until it converges — i.e. until it reports nothing left to do, rather than treating a single pass as the finished step. On this particular reconcile, expect to need it **twice**: the first pass mostly ends up removing packages that don't belong in this manifest (leftovers from sections 11–12's smaller `system.json` files), and it's only the second pass that actually fetches and builds the full list above.

If a package fails to build, retry `lambda reconcile` once before assuming something's actually wrong — some package dependencies aren't fully tracked yet, so a package can attempt to build before one of its own dependencies has been installed, and a second pass usually clears it. If it fails the same way twice in a row, or if the system boots afterward but a `util-linux`/`kmod`/`eudev` binary fails at runtime with a relocation or missing-library error, see building-troubleshooting.md.

## 14. System configuration

### 14.1 Creating the root user

Before building and booting the kernel, we need to create the basic user database. Without it, programs such as `whoami` cannot resolve a UID to a username.

Create the required directories:

```sh
mkdir -p /etc
```

Create `/etc/passwd`:

```sh
cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/sh
EOF
```

Create `/etc/group`:

```sh
cat > /etc/group << "EOF"
root:x:0:
EOF
```

Create `/etc/shadow`:

```sh
cat > /etc/shadow << "EOF"
root:!:19000:0:99999:7:::
EOF
chmod 600 /etc/shadow
chown root:root /etc/shadow
```

Create `/etc/gshadow`:

```sh
cat > /etc/gshadow << "EOF"
root:!::
EOF
chmod 600 /etc/gshadow
```

Create `/etc/pam.d/other` and `/etc/pam.d/passwd`:

```sh
mkdir -p /etc/pam.d

cat > /etc/pam.d/other << "EOF"
auth     required pam_unix.so
account  required pam_unix.so
password required pam_unix.so
session  required pam_unix.so
EOF

cat > /etc/pam.d/passwd << "EOF"
auth     required pam_unix.so
account  required pam_unix.so
password required pam_unix.so
session  required pam_unix.so
EOF
```

Create the root user's home directory:

```sh
mkdir -p /root
chmod 700 /root
```

And finally set the password:

```sh
passwd
```

The `root` user uses UID `0` and GID `0`.

### 14.2 Creating a non-root user (optional)

Everything up to this point in the guide runs as `root` — there's no other choice inside a chroot, and every package built by hand or through `lambda` so far installs as root regardless. That's fine for finishing the build, but running your day-to-day session as `root` afterward is worth avoiding for the usual reason: any bug in something as ordinary as a text editor or a web browser runs with full filesystem access instead of a limited one. `shadow` (installed in section 13) provides `useradd`/`usermod`/`groupadd`, the same tools that created `root`'s account structure above:

```sh
useradd -m -G wheel -s /bin/sh <username>
passwd <username>
```

`-m` creates the home directory (`/home/<username>`), matching the `home` directory this guide's section 5 already created at the top level. `-G wheel` adds the account to a `wheel` group for later use with `su`/a `sudo`-equivalent — Busybox provides neither `sudo` nor a working `su` on its own (section 11.4's note about `sudo` still applies), so privilege escalation for this user is deliberately left unconfigured here rather than half-configured with a tool that doesn't exist yet. Installing and configuring `sudo` (or `doas`, or relying on `su` plus a shared root password) is a policy decision this guide doesn't make on your behalf — do it through `lambda` once you've picked one.

This step is skippable if Vind Linux is being built purely as a base for something else (a container image, a recovery environment, a from-scratch appliance) where a `root`-only account is the actual intended end state — nothing later in this guide depends on a non-root user existing.

### 14.3 Configuring the hostname

Create `/etc/hostname` and define the system hostname:

```sh
echo "vind-linux" > /etc/hostname
```

### 14.4 Configuring /etc/profile

Basic `/etc/profile`:

```sh
cat > /etc/profile << 'EOF'
# /etc/profile

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig"

export SHELL=/bin/sh
export EDITOR=vi

umask 22

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

export PS1='\u@\h:\w\$ '
EOF
```

`LANG`/`LC_ALL` are set to `C.UTF-8` rather than left unset or pointed at something like `en_US.UTF-8`. This isn't the same situation as a glibc-based distro: glibc ships (and, on most distros, lets you generate via `locale-gen`) a real locale database under `/usr/lib/locale` with actual collation rules, date formats, and so on per locale. musl doesn't — musl's locale support is intentionally minimal, and in practice it treats any locale name it doesn't specifically recognize as `C`/`POSIX` and moves on, rather than erroring. `C.UTF-8` is the one exception worth setting explicitly: it gets programs UTF-8-aware string handling (multibyte-safe `wc`, correct-width terminal output, etc.) without depending on a locale database musl doesn't ship. Setting `LANG` to something like `en_US.UTF-8` on this system won't produce an error, but it also won't produce US date/number formatting — it'll silently behave exactly like `C.UTF-8`, which is worth knowing before spending time debugging why a locale-dependent format string isn't doing what it would on a glibc system.

### 14.5 Timezone

`/etc/localtime` is how every timezone-aware program (`date`, log timestamps, anything using the C library's `localtime()`) finds out the system's local offset from UTC — without it, the system defaults to UTC, which is a reasonable fallback but not usually what you actually want. This needs the `tzdata` package (section 13) installed first, since that's what provides the `/usr/share/zoneinfo` database `/etc/localtime` points into:

```sh
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
```

Replace `America/Sao_Paulo` with whichever zone applies — `ls /usr/share/zoneinfo` lists everything `tzdata` installed, organized the same `Region/City` way as on any other Linux distro, since the zoneinfo database itself is upstream, not something this guide or musl redefines. There's no separate `/etc/timezone` file to keep in sync the way some glibc distros use — `/etc/localtime` being a symlink to the right zoneinfo file is the whole mechanism musl's C library reads.

If the system's hardware clock (RTC) isn't already set to UTC — a common default on a fresh VM — `hwclock`, from `util-linux` (already in section 13's package set), can check and correct it once a kernel is installed and `/dev/rtc` exists:

```sh
hwclock --show
hwclock --systohc --utc
```

This only matters once there's a kernel to expose `/dev/rtc` at all (section 16.2), so it's easy to defer past this point in the guide — 15.4's one-shot `ntpd` correction at every boot covers for a wrong RTC in the meantime, just less precisely than a correctly-set hardware clock would.

### 14.6 Configuring available shells

Create `/etc/shells` and list the shells available on the system:

```sh
cat > /etc/shells << 'EOF'
/bin/sh
/bin/ash
/bin/dash
EOF
```

### 14.7 /etc/os-release and GRUB defaults

`/etc/os-release` is how everything from `neofetch` to `systemd`-derived tooling to a package's own `configure` script identifies which distribution it's running on — without it, this is just "some Linux system" as far as any of that tooling can tell:

```sh
cat > /etc/os-release << 'EOF'
NAME="Vind Linux"
ID=vind
PRETTY_NAME="Vind Linux"
VERSION="1.0"
VERSION_ID="1.0"
HOME_URL="https://github.com/VindLinux"
EOF
```

`grub` (installed in section 13) reads `/etc/default/grub` when `grub-mkconfig` (section 16.4) generates the actual boot menu. Creating it here, rather than waiting until section 16.4, keeps every plain-text system-identity file next to the others this chapter already writes:

```sh
mkdir -p /etc/default

cat > /etc/default/grub << 'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Vind Linux"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
EOF
```

`GRUB_DISTRIBUTOR` is what `grub-mkconfig` uses to label the menu entries it generates ("Vind Linux" instead of a generic "GNU/Linux"); the other four are GRUB's own usual baseline (a 5-second menu timeout, no extra kernel command-line arguments) rather than anything Vind-specific. Section 16.4 only needs to run `grub-install`/`grub-mkconfig` against this file — it doesn't need to create or append to it itself.

### 14.8 Cleaning up the system

Everything the base system needs is now installed (section 13) and configured (this chapter, so far). One thing is still sitting on disk that doesn't need to be: leftover build material from every section since Phase 1.

**Temporary and build files.** `$VIND/sources` (section 7 onward) held every tarball this guide downloaded and every directory it was extracted and built in — none of that is needed once `make install` has already copied the result into `/usr`. `$VIND/tools` and `$VIND/tools-src` (section 6) are the Pass 1 cross-toolchain and its build tree; Phase 1 already noted these could be deleted once Phase 2 started, and nothing since then has touched them. `/usr/src` held the kernel and other source trees fetched from section 9.1 onward and is no longer needed by anything built so far (see section 16.2 for the separate note about the kernel source tree specifically, which is worth keeping around a little longer). Since all of these live inside `$VIND`, they appear as ordinary top-level directories once you're inside the chroot:

```sh
rm -rf /sources
rm -rf /tools /tools-src
rm -rf /usr/src
rm -rf /tmp/*
```

Leave `/var/tmp` alone — `chmod 1777` was set on it back in section 5 specifically so ordinary programs can use it at runtime; it's meant to stay, unlike the build-only directories above.

## 15. Networking

`/etc/resolv.conf` (below) is the only piece of networking this guide has actually needed so far — it's what let `git`/`curl` inside the chroot resolve hostnames at all back in section 10.1. It says nothing about how an interface gets an address in the first place, which matters once you're booting on real hardware (or a VM) instead of relying on whatever the live ISO's own network setup left behind. This section covers that: bringing an interface up automatically, keeping the clock correct enough for TLS to keep working after reboot, and where firewalling would fit if you need it. The actual "start this at boot" wiring depends on `runit` (installed in section 16.3, right after this), so the pieces below are configuration only — section 16.3 comes back and turns them into running services once there's an init system to hand them to.

### 15.1 Configuring DNS

Create `/etc/resolv.conf` with the DNS servers to use:

```sh
cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

This is the same file section 10.1 created before `git clone`d `lambda-manager` — repeated here because a DHCP client (15.2) will typically want to overwrite it with whatever the network hands out, and it's worth having a known-good static fallback on disk in case that ever needs debugging.

### 15.2 Wired networking with dhcpcd

`dhcpcd` is already part of the base package set installed in section 13 — Busybox's applet list (section 7.2) doesn't enable `udhcpc`, so this is the only DHCP client anywhere in this system, not one option among several. Confirm the interface name first; `eudev` (also in section 13's package set) is what assigns it, and on a VM built the way section 1–4 set this one up, it's usually something like `enp0s3` or `eth0`, not a name you get to choose:

```sh
ip link
```

A minimal `/etc/dhcpcd.conf` is enough to get an address automatically on whichever interface `dhcpcd` finds:

```sh
mkdir -p /etc
cat > /etc/dhcpcd.conf << 'EOF'
# Minimal dhcpcd config for Vind Linux.
hostname
option rapid_commit
option domain_name_servers, domain_name, domain_search
option classless_static_routes
option interface_mtu
require dhcp_server_identifier
slaac private
EOF
```

This is upstream `dhcpcd`'s own recommended baseline (privacy-preserving SLAAC, a couple of DHCP options most networks expect a client to request) rather than anything Vind-specific — nothing here depends on musl or on choices made earlier in this guide. Test it by hand once, before wiring it into `runit` in 16.3:

```sh
dhcpcd <interface-name>
ip addr show <interface-name>
```

If an address shows up and `cat /etc/resolv.conf` now shows whatever DNS servers the network handed out (overwriting the static ones from 15.1), it worked. `dhcpcd -k <interface-name>` releases the lease and tears the config back down if you want to retest.

### 15.3 Wireless networking with iwd (optional)

`iwd` is also already in section 13's package set, for laptops/hardware where a wired connection isn't an option — skip this subsection entirely on a VM built per sections 1–4, since virtual NICs are wired by definition. `iwd` ships its own control CLI, `iwctl`:

```sh
iwctl
[iwd]# device list
[iwd]# station <device> scan
[iwd]# station <device> get-networks
[iwd]# station <device> connect <SSID>
[iwd]# exit
```

`iwd` handles authentication and the link itself, but — unlike some other wireless daemons — it doesn't run a DHCP client or touch `/etc/resolv.conf` on its own; once `station connect` succeeds, the interface is associated but still has no IP address until `dhcpcd` (15.2) runs against it the same way it would against a wired interface. `iwd` stores known-network credentials under `/var/lib/iwd`, so reconnecting after a reboot only needs 15.4's boot-time wiring, not re-entering a passphrase.

### 15.4 Time synchronization

This is easy to skip and easy to regret skipping: without a battery-backed RTC keeping reasonable time across reboots (common on VMs and some real hardware), the system can come up with a clock that's wrong by hours or years. That's not just cosmetic — every TLS handshake `curl`, `git`, or `lambda reconcile` does depends on the certificate's validity window, and OpenSSL (built in section 10.1) rejects a handshake with an otherwise-perfectly-good certificate if the system clock thinks it hasn't started yet, or has already expired. This is why `CONFIG_NTPD=y` was enabled back in section 7.2 — Busybox's `ntpd` applet is enough for a one-shot correction and doesn't pull in a separate package:

```sh
busybox ntpd -n -q -p pool.ntp.org
```

`-n` keeps it in the foreground instead of daemonizing, `-q` exits immediately after the first successful sync instead of continuing to run and slew the clock over time, and `-p pool.ntp.org` picks a server explicitly rather than relying on Busybox's compiled-in default (which may not be reachable everywhere). Section 16.3 runs this once, early, as part of the boot sequence, before anything that depends on TLS gets a chance to run. This is deliberately a one-shot correction, not continuous drift discipline — if the system stays up for weeks at a time and needs its clock kept accurate throughout (rather than just correct right after boot), that's a case for a real NTP daemon (`chrony`, `openntpd`) installed through `lambda` once the base system exists; not covered by this guide.

### 15.5 A note on firewalling

Nothing in section 13's package list provides a firewall (`nftables`/`iptables`), and this guide doesn't set one up. That's a deliberate scope decision, not an oversight: a sensible default ruleset depends heavily on what the machine is actually going to do (a workstation behind a router needs very different rules than something with a public IP), and shipping one here would either be a no-op default-allow policy that gives false confidence, or a set of assumptions about your network that don't hold. If you need one, `nftables` can be installed the same way as anything else in section 13 (`lambda mutate append nftables`) once the base system is up; writing the ruleset itself is out of scope for this guide.

## 16. Preparing for boot

The system is functionally complete. What's left is making it bootable on its own hardware (or VM), without the live installer: a filesystem table, a kernel, an init system, and a bootloader.

### 16.1 /etc/fstab

Based on the partition layout from section 2:

```sh
cat > /etc/fstab <<'EOF'
# <file system>   <mount point>  <type>  <options>        <dump> <pass>
/dev/vda3         /              ext4    defaults         0      1
/dev/vda1         /boot/efi      vfat    umask=0077       0      2
/dev/vda2         swap           swap    defaults         0      0
EOF
```

This uses the raw device paths (`/dev/vda1`/`/dev/vda2`/`/dev/vda3`) to match how this guide partitioned the disk in section 2. Swapping these for `UUID=...` entries (from `blkid`) is more robust against device renumbering on real hardware, and worth doing before relying on this install long-term — but it isn't required to boot.

### 16.2 Kernel

The kernel is **not included in the Lambda repository**. You must either compile it yourself or use the [Vind-Kernel](https://github.com/VindLinux/vind-kernel) tree.

Clone the Vind branch with a shallow clone to avoid downloading the entire repository history:

```sh
git clone --depth 1 --single-branch --branch vind https://github.com/VindLinux/vind-kernel.git
```

Vind-Kernel provides some basic `defconfig` files for different use cases. Hardware-specific drivers are left to the user and can be selected using `make nconfig`, `make menuconfig`, or any other preferred method.

See the [VIND.md](https://github.com/VindLinux/vind-kernel/blob/vind/VIND.md) for kernel-specific build instructions and available configurations.

Once the kernel and its modules are installed, generate an initramfs with `dracut`. A few adjustments are required for this to work correctly on musl:

```sh
# depmod must come from kmod, not busybox
rm -f /usr/bin/depmod
ln -s /usr/bin/kmod /usr/bin/depmod
depmod <kernel-version>

# disable i18n unless you need keymap/locale support inside the initramfs
echo 'omit_dracutmodules+=" i18n "' > /etc/dracut.conf.d/no-i18n.conf
```

With these in place, `dracut --force /boot/initramfs-<kernel-version>.img <kernel-version>` should complete successfully.

**Kernel source tree (optional cleanup).** The `vind-kernel` checkout itself can be deleted once the kernel and modules are installed — nothing later in this guide needs it on disk. It's worth holding off on that, though: it's recommended to only delete it *after* confirming the system actually boots, since keeping the source around until then means that if boot fails or something needs a config tweak, you can still recompile without re-cloning and reconfiguring from scratch.

**CPU microcode (optional, real hardware only).** Skip this on a VM — the hypervisor's own vCPU presentation doesn't need or use it. On real hardware, the kernel can load a CPU microcode update very early in boot (before most of the kernel itself has initialized) to patch certain silicon-level bugs and security issues that a BIOS/UEFI update alone doesn't always cover. This isn't packaged anywhere in this guide's `lambda` recipes yet — Intel and AMD each publish their own microcode bundles (`intel-ucode`/`linux-firmware`'s AMD equivalent), and getting one installed and picked up by `dracut`'s early-microcode mechanism is a real gap in Vind Linux's current package set, not something worked around here. If this matters for your hardware, it's worth writing a `lambda` recipe for it before relying on this build long-term.

### 16.3 Init system

**runit** is the default init system for Vind. However, Vind follows an **init-freedom** approach, so you are free to use another init system if you prefer.

If you choose a different init system, you must install and configure it manually or create a custom Lambda recipe to handle the installation.

To install the default runit setup:

```sh
lambda mutate append vind-runit
lambda reconcile
```

`vind-runit` installs runit along with basic utilities and the default stage scripts required by Vind. If boot completes and `runit` starts but every `runsv` fails immediately with `unable to open supervise/lock: read-only file system`, see building-troubleshooting.md.

#### 16.3.1 Wiring up networking and time sync

Section 15 prepared `dhcpcd`'s config and enabled Busybox `ntpd`, but stopped short of making either run automatically — there was no init system yet to hand them to. There is now. `runit` services live under `/etc/sv/<name>`, each with a `run` script that `exec`s the long-running process directly (no forking, no PID files — that's `runsvdir`'s job, not the service's own); enabling one is a matter of symlinking it into `/etc/service`, which `runsvdir` watches:

`dhcpcd`'s own `-B`/`--background` flag (the default behavior most other init systems expect) would be wrong here: it tells `dhcpcd` to fork and exit its parent, but the `run` script's own process exiting is exactly what tells `runsv` a service has died — `runsv` would immediately respawn it, spawning another backgrounded copy on top of the first, forever. `exec dhcpcd --nobackground` avoids that: `exec` replaces the `run` script's own process with `dhcpcd` itself, running in the foreground, so the process `runsv` is watching and the process actually doing the work are the same one.

```sh
mkdir -p /etc/sv/dhcpcd/log
cat > /etc/sv/dhcpcd/run << 'EOF'
#!/bin/sh
exec dhcpcd --nobackground
EOF
chmod +x /etc/sv/dhcpcd/run

ln -sf /etc/sv/dhcpcd /etc/service/dhcpcd
```

Time sync is a one-shot job, not a long-running daemon (15.4 deliberately used `ntpd -n -q`, which exits after the first successful correction) — `runit` handles that as a `run` script that does its work and exits cleanly, rather than something meant to be respawned forever:

```sh
mkdir -p /etc/sv/ntpsync
cat > /etc/sv/ntpsync/run << 'EOF'
#!/bin/sh
busybox ntpd -n -q -p pool.ntp.org
exec sleep 999999
EOF
chmod +x /etc/sv/ntpsync/run

ln -sf /etc/sv/ntpsync /etc/service/ntpsync
```

The trailing `sleep` isn't decorative — a `run` script that exits immediately after a successful one-shot job looks, to `runsv`, identical to a crashing daemon, and gets respawned in a tight loop (visible as constant CPU churn from repeated `ntpd` invocations hammering the same NTP server). Sleeping keeps the "service" alive without repeating the sync; `runit` naturally re-runs `ntpd` on the next reboot, which is the only time this actually needs to happen again.

### 16.4 Bootloader (GRUB)

`grub` and `efibootmgr` are already installed as part of section 13's package set. Install GRUB into the EFI System Partition mounted at `/boot/efi` (section 4), and generate its configuration:

```sh
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=VindLinux --removable
```

`/etc/default/grub` — including `GRUB_DISTRIBUTOR` — was already created back in section 14.7; `grub-mkconfig` picks it up automatically, so no further edits are needed here before generating the config:

```sh
grub-mkconfig -o /boot/grub/grub.cfg
```

`--removable` additionally installs a fallback bootloader path (`EFI/BOOT/BOOTX64.EFI`) alongside the `--bootloader-id`-named one. That's worth keeping on a VM/disk image, where the firmware's NVRAM boot entries (which `efibootmgr` would otherwise manage) may not persist reliably across the specific virtualized firmware in use — drop it on real hardware where a single, normal NVRAM entry is preferred instead.

`grub-mkconfig` scans `/boot` for kernels to generate menu entries for, so this step depends on section 16.2 (the kernel) already being in place. Re-run it any time a kernel is added, updated, or removed.

### 16.5 Leave the chroot and boot

Unmount everything cleanly and leave the live environment:

```sh
exit                                   # leave the chroot
umount -R "$VIND/dev" "$VIND/proc" "$VIND/sys" "$VIND/run"
swapoff /dev/vda2
umount -R "$VIND"
reboot
```

Remove the live ISO/installer media before the system restarts, so the firmware boots from `/dev/vda` instead of the live environment again. Once GRUB starts and hands off to Vind Linux's own kernel (section 16.2) and init (section 16.3), the system built by this guide is up and running on its own.

### 16.6 Post-boot smoke test

A short checklist to run before trusting this install for anything real — each of these exercises a different part of the guide, so a failure here points back at a specific section rather than "something's wrong somewhere":

```sh
whoami              # 14.1 — user database resolves UID 0 to root
uname -a             # 16.2 — confirms the kernel that's actually running
mount | grep vda3    # 2/16.1 — root is mounted from the right partition
ip addr show         # 15.2/16.3.1 — dhcpcd brought an interface up
cat /etc/resolv.conf  # 15.1 — DNS config is in place (static or DHCP-provided)
date                 # 15.4 — clock is sane, not 1970 or decades off
ping -c 1 1.1.1.1     # network reaches the outside world
curl -sI https://github.com  # 10.1 — TLS trust chain actually works end to end
gcc --version 2>&1 | head -1  # should fail: "command not found" — 12.5 removed it
clang --version      # 12.2 — Clang is the live compiler
lambda --help        # 11.1 — package manager is intact post-reboot
sv status dhcpcd ntpsync  # 16.3.1 — both services are up under runit
```

If everything above checks out, the system isn't just booting — every subsystem this guide built (toolchain, package manager, networking, time, TLS trust) is actually working together, not just present on disk.
