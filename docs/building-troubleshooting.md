# Vind Linux — Build Troubleshooting / FAQ

Companion to [building.md](building.md). Entries are indexed by the section number of the step in that guide where the problem shows up — use that to jump straight to the relevant one instead of reading top to bottom.

### Section 6 — Pass 1 cross-toolchain

**`make` was interrupted or a previous attempt failed partway through.**
Run `rm -rf build` inside `musl-cross-make` before retrying `make -j$(nproc)`.

**`make install` fails to download a source tarball with `502 Bad Gateway` (or a connection reset), and it isn't the IPv6 issue below.**
`musl-cross-make` fetches GCC, binutils, and its other prerequisites from `https://ftpmirror.gnu.org`, a redirector that bounces each request to an essentially random GNU mirror — if it lands you on one that's temporarily down, that single request fails even though the rest of the internet is fine. Just retry `make install` a few times; it'll usually land on a different, working mirror.

**You downloaded the missing tarball by hand from a working mirror and dropped it into `musl-cross-make/sources/`, but `make install` still insists on re-downloading it instead of using the file that's already there.**
This isn't `make` failing to notice the file — it's comparing timestamps and deciding the file is stale. `musl-cross-make`'s download rule (`Makefile`) treats `sources/gcc-<version>.tar.xz` as out of date unless it's *newer* than `musl-cross-make`'s own `hashes/gcc-<version>.tar.xz.sha1` file. Plain `wget`, by default, sets a downloaded file's local timestamp to match the *server's* `Last-Modified` header — for a release tarball, that's whenever that version actually shipped (months or years ago), not the moment you downloaded it. So the tarball you just fetched can already look "older" than the hash file `musl-cross-make` compares it against, and `make` reruns the whole download recipe to be safe. Fix it by bumping the file's timestamp to now after moving it into place, instead of leaving `wget`'s server-provided one:
```sh
mv gcc-13.3.0.tar.xz sources/
touch sources/gcc-13.3.0.tar.xz
make install
```
This applies to any source `musl-cross-make` fetches this way, not just GCC — the same fix works for `binutils`, `musl`, `gmp`, `mpfr`, `mpc`, or `isl` if one of those hits the same symptom.

**`make` fails downloading a source tarball (e.g. musl) with `Connection refused` or `Network is unreachable`, even though the host clearly has working internet.**
Check `ip addr` / `ip route` / `ip -6 route`. If the host has an IPv6 address and default route configured *alongside* a working IPv4 one, the resolver may hand `wget` an IPv6 address first — and if that IPv6 setup isn't actually routable to the internet (e.g. it's a deprecated site-local `fec0::/64` address, or a route with no real path out, common on cloud/VM network setups), the download fails outright instead of falling back to IPv4, since plain `wget`/`curl` don't retry the other address family on their own.

Confirm by forcing IPv4 directly:
```sh
wget -4 https://musl.libc.org/releases/musl-1.2.6.tar.gz
```
If that succeeds where the plain download failed, this is it. Fix it for the rest of `musl-cross-make`'s own downloads (it fetches gcc, binutils, musl, gmp, mpfr, mpc, isl itself during `make`) by overriding its download command in `config.mak`:
```sh
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
```sh
cd "$VIND/sources/busybox-1.37.0"
make clean
CC="$CC" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip make $MAKEOPTS
cp busybox "$VIND/usr/bin/busybox"
```

### Section 7.6 — binutils

**`configure` fails with `cannot run C compiled programs` in one or more subdirectories (`gas`, `libiberty`, `zlib`, `libsframe`...), even though `--host` was passed correctly.**
This is the same `--build` auto-detection problem described in section 8's FAQ, just showing up here because `binutils` is a multi-directory project — each subdirectory runs its own `configure` and does its own `--build` detection, and `$PATH`/`$CC` being biased toward the musl compiler (from section 7's exports) confuses some of them. Fix by passing `--build` explicitly instead of letting it auto-detect:
```sh
BUILD_TRIPLE=$(/usr/bin/gcc -dumpmachine)
./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" --disable-multilib --disable-nls --disable-gprofng
```
If a previous attempt already left partial `Makefile`s in subdirectories, clean those up first — a stale sub-`Makefile` can keep using the old (wrong) detection even after you fix the top-level command:
```sh
rm -rf */Makefile
```
This same fix (`--build="$(/usr/bin/gcc -dumpmachine)"`) is worth trying first for **any** autotools package in section 7 that fails the same way, not just binutils — anything with several subdirectories cross-building against this toolchain can hit it.

**`make install` fails inside `gprofng` with `'fopen64' was not declared in this scope` (or `fseeko64`/`ftello64`).**
`gprofng` (binutils' bundled profiler, since 2.38) uses glibc's `*64` large-file-support functions, which musl doesn't have — musl doesn't need a separate 64-bit variant since it's always 64-bit. This isn't fixable by patching your environment; the standard fix (used by other musl-based distros too) is to not build gprofng at all, since it's not part of the core toolchain. Add `--disable-gprofng` to the `configure` command and rebuild:
```sh
./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD_TRIPLE" --disable-multilib --disable-nls --disable-gprofng
make $MAKEOPTS
make DESTDIR="$DESTDIR" install
```
`ar`, `as`, `ld`, `nm`, `ranlib`, and `strip` — everything this guide actually needs — build and install independently of gprofng, so this doesn't lose anything required.

**Inside the chroot, `gcc` compiles fine but fails with `cannot execute 'as': execvp: No such file or directory` (or the same for `ld`).**
Section 7.6 (binutils) was skipped or run before it existed in this guide. `as`/`ld` need to be a musl-native binutils build inside `$VIND`, separate from the Pass 1 toolchain's own host-side copy. Fix without restarting: exit the chroot, cross-build binutils from section 7.6, re-enter the chroot, and retry:
```sh
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
```sh
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
```sh
cd /usr/src/openssl-3.5.7
make clean 2>/dev/null
./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared
make
make install
```
No need to add `no-secure-memory` or any other feature-disabling flag to `Configure` — the header is genuinely available now, so OpenSSL's secure heap builds and works as intended rather than being switched off to route around a missing prerequisite.

**`openssl version` (or anything else linked against OpenSSL, including `curl` once it's built with `--with-openssl`) fails with `Error loading shared library libssl.so.3: No such file or directory` / `libcrypto.so.3: No such file or directory`, even though `make install` reported no error and the headers under `/usr/include/openssl` are all there.**
This isn't a missing-header problem like the one above — it's `--libdir` defaulting to the wrong place. OpenSSL's `Configure`, for the `linux-x86_64` target, assumes a multilib layout and installs the actual `.so` files under `$prefix/lib64` rather than `$prefix/lib` unless told otherwise. Vind Linux has no `/usr/lib64` — musl itself lives entirely in `/usr/lib` (section 7.1's `--syslibdir="$PREFIX/lib"`) — so the libraries land somewhere musl's dynamic loader never searches, and every program that depends on them fails at startup, not at compile or link time (which is why `make install` itself reports success). Confirm the libraries are indeed sitting in the wrong place:
```sh
find / -xdev -name 'libssl.so.3' -o -name 'libcrypto.so.3'
```
If that turns up `/usr/lib64/libssl.so.3` instead of `/usr/lib/libssl.so.3`, reconfigure and reinstall with `--libdir=lib` explicit:
```sh
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
```sh
exit   # leave the chroot first — this rebuild needs the host toolchain
cd "$VIND/sources/gcc-13.3.0"
rm -rf build-pass2 && mkdir build-pass2 && cd build-pass2
```
then redo the `configure`/`make`/`make install` from section 8 with `--with-build-sysroot="$VIND"` in place of `--with-sysroot="$VIND"`. Re-enter the chroot afterward and confirm with:
```sh
echo "int main(){return 0;}" > /tmp/t.c && gcc -o /tmp/t /tmp/t.c && echo OK
```

**Headers or library paths from the host (`/usr/include`, glibc) leak into the build instead of the musl sysroot.**
This is the failure mode that motivated splitting the build into two phases in the first place — cross-compiling C++-heavy software (like LLVM) directly against a Pass 1 toolchain is where this tends to show up, often as `__gnuc_va_list has not been declared` or `vswprintf`/`__to_xstring` mismatches pointing at `/usr/include/stdio.h` instead of the sysroot's. Check for `CPATH`, `C_INCLUDE_PATH`, or `CPLUS_INCLUDE_PATH` set in your shell — any of these get searched *before* the compiler's own sysroot and will cause exactly this. Unset them:
```sh
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
```
and confirm the search order with:
```sh
x86_64-pc-linux-musl-g++ -E -v -xc++ /dev/null 2>&1 | sed -n '/search starts here/,/End of search list/p'
```
The sysroot's musl `include` directories should appear before `/usr/include`.

**Build fails inside `libstdc++` with `no matching function for call to '__to_xstring<...>'` (affects `std::to_string`/`std::to_wstring`).**
This is [GCC bug 37522](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=37522) — a long-standing mismatch between `libstdc++`'s expected `vswprintf`/`vsnprintf` prototype and musl's actual one. It isn't fixed by changing the GCC version. The upstream fix (originally for MinGW) is the `_GLIBCXX_HAVE_BROKEN_VSWPRINTF` macro, which makes `libstdc++` skip the affected functions (only `to_wstring` is actually lost; `to_string`, `stoi`, etc. are unaffected). Find the installed target `c++config.h`:
```sh
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
```sh
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
```sh
unset CC CXX PREFIX DESTDIR HOST TOOLS
export CC=gcc CXX=g++ PATH=/usr/bin:/bin
cd /usr/src/zlib-1.3.1   # or wherever the affected package's build tree is
make install
```
The phantom directory tree left behind (e.g. `/mnt/vind/` inside the chroot) is inert and can be removed once you've confirmed the real install worked — just double-check you're removing it *from inside the chroot*, where that path is empty junk, not the host's real mount.

**zlib's `./configure` aborts with `Missing or broken C compiler.`, even though `gcc`/`cc` clearly work when run directly.**
zlib's `configure` isn't autotools-based, and doesn't search `PATH` for a compiler the way the autotools scripts elsewhere in this guide do — it needs `$CC` set explicitly. Section 9.3 already exports `CC=gcc` for the whole chroot session, so this shouldn't come up if that step was followed; if it does (e.g. a fresh shell that skipped 9.3), set it directly:
```sh
export CC=gcc
./configure --prefix=/usr
```

**OpenSSL's `./Configure` fails or can't find `perl`, or `make` for `openssl` aborts partway through with a Perl syntax/version error.**
`openssl`'s build system is Perl scripts, not autotools — `perl` (the subsection just above it in 10.1) has to be built and on `PATH` first. Confirm with `perl -v`; if that fails, build `perl` first, then retry `openssl`'s `./Configure`/`make`/`make install` from a clean extraction.

**`git clone https://...` fails inside Vind Linux with `fatal: unable to access '...': Protocol "https" not supported`, even though `git --version` works fine and everything up through `make install` reported success.**
This means `curl` was built with `--without-ssl` (i.e. with no TLS backend compiled in at all) instead of `--with-openssl`. Git's HTTPS support is implemented by the `git-remote-https` helper, which links against `libcurl` and simply hands it the URL — it doesn't speak TLS itself. If the `libcurl` behind it has no TLS backend, the helper is present and `git` looks completely normal, but it never registered a handler for the `https://` scheme at all, so every `https://` clone fails immediately with this exact "Protocol not supported" error. (This is different from the `remote helper 'https' aborted session` error below, which means the helper never got built in the first place.)

Fix by building `perl` and `openssl` (see the `perl`/`openssl` subsections above if skipped), rebuilding `curl` with real TLS support, and then rebuilding `git` against that `curl`:
```sh
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
```sh
git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check
```

**`git`'s `make` fails with `fatal error: zlib.h: No such file or directory` (in `daemon.c` or elsewhere), even though `/usr/include/zlib.h` exists.**
Two possible causes, check both:
1. `zlib` (section 10.1) hasn't actually been built yet. Its tarball should already be in `/usr/src` from section 9.1; build it first:
   ```sh
   cd /usr/src
   tar -xf zlib-1.3.1.tar.gz
   cd zlib-1.3.1
   export CC=gcc
   ./configure --prefix=/usr
   make
   make install
   ```
2. `zlib` is installed, but the shell is missing the `CFLAGS`/`CPPFLAGS`/`LDFLAGS` exports from section 9.3 (e.g. a new terminal that re-entered the chroot without redoing that step) — Git's `Makefile` doesn't always pass an explicit `-I`/`-L` for zlib on its own, and relies on the compiler's default search path already including `/usr/include`/`/usr/lib`, which is normally true but is worth confirming:
   ```sh
   export CC=gcc CXX=g++ PATH=/usr/bin:/bin
   export CFLAGS="-I/usr/include" CPPFLAGS="-I/usr/include" LDFLAGS="-L/usr/lib"
   ```
Then retry `git`'s build from a clean tree (a partial `make` can leave stale `.o` files that skip re-checking headers):
```sh
cd /usr/src/git-2.47.0
make clean
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```

**`git`'s `make` fails with `MSGFMT po/bg.msg` / `make[1]: *** [Makefile:239: po/bg.msg] Error 127`.**
`Error 127` means the shell couldn't find the command at all — here, `msgfmt` (part of GNU `gettext`), which nothing earlier in this guide installs. Git's default `configure` still tries to build translated message catalogs unless told not to. This guide's Git build (section 10.1) already passes `--disable-nls` at configure time and `NO_GETTEXT=1` on the `make`/`make install` lines specifically to skip this; if you hit this error, you're most likely working from a `configure`/`make` invocation that dropped one of those flags. Reconfigure and rebuild with both in place:
```sh
cd /usr/src/git-2.47.0
make clean
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```
If you specifically need `msgfmt` for something else, build `gettext` first (see the "gettext (for msgfmt)" step in 10.1) and drop `--disable-nls`/`NO_GETTEXT=1` instead — but for a minimal bootstrap, skipping Git's translations is the smaller, faster path.

**`curl`'s `configure` fails with `configure: error: libpsl libs and/or directories were not found where specified!`, even though nothing in this guide installs `libpsl` and the log shows `pkg-config... no` right above it.**
Most of curl's optional dependencies (brotli, zstd, LDAP, GSS-API, and others) auto-disable with just a `checking for ... no` when they're missing — but PSL (Public Suffix List) support defaults to *on* in curl's `configure`, and its absence is treated as a hard error rather than a silent skip. This build has no need for PSL support. Reconfigure with it explicitly disabled:
```sh
cd /usr/src/curl-8.11.0
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl
make
make install
```
If `configure` had already failed, there's no `Makefile` yet — the `make: *** No targets specified and no makefile found` and `make: *** No rule to make target 'install'` errors right after are just downstream symptoms of the same failed `configure`, not separate problems; they resolve once `configure` succeeds.

**`curl`'s `configure` fails with `configure: error: perl was not found, needed for docs, manual and CA embed`, even though `perl` was built earlier in section 10.1.**
This means `perl` isn't on `PATH` in the current shell (e.g. a fresh terminal that re-entered the chroot without re-running section 9.3, or `perl`'s own `make install` didn't actually complete). Confirm with `perl -v`; if it's missing, rebuild it from the `perl` subsection above. If docs genuinely aren't wanted regardless, the flags below skip them without needing `perl` at all:
```sh
cd /usr/src/curl-8.11.0
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl --disable-docs --without-ca-embed
make
make install
```
`--disable-docs` covers both the man pages and the built-in `--help` manual (it disables the manual automatically once docs are off); `--without-ca-embed` is unrelated to TLS itself — it only skips baking a copy of the CA bundle into the `curl` binary, which is unnecessary here since `--with-ca-bundle` already points `curl` at `/etc/ssl/cert.pem` on disk.

**`curl -v https://...` shows `CApath: /etc/ssl/certs` (no `CAfile` line at all) and every request fails by default with `SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)`, even though the same request succeeds with `curl --cacert /etc/ssl/cert.pem ...`, and `/etc/ssl/cert.pem` clearly exists with a full set of certificates in it.**
This means the `curl` being run wasn't built with `--with-ca-bundle=/etc/ssl/cert.pem` (section 10.1's flag) — most commonly because it's a *later* rebuild that dropped the flag, e.g. `lambda`'s own `curl` recipe (section 12's `system.json` lists `curl` again, to be reinstalled through `lambda` for a proper manifest) using a generic autotools recipe instead of this guide's explicit one. Without that flag, `curl`'s `configure` falls back to autodetecting a default CA location from a fixed list of common paths, and lands on `/etc/ssl/certs` — which exists only because `openssl`'s own `--openssldir=/etc/ssl` (section 10.1) created it as an empty directory, not because anything in this guide ever populated it with the hashed certificate symlinks (`c_rehash`-style) that CApath-based verification actually needs. An existing-but-empty directory is enough for the autodetection to pick it and stop looking, which is why no `CAfile` ever gets set at all — `/etc/ssl/cert.pem` (the real, populated file from section 9.1/10.1) is simply never found. Confirm which `curl` and flags produced the broken binary:
```sh
curl -V   # note the version — does it match section 10.1's 8.11.0, or something newer?
strings "$(command -v curl)" | grep -E '^/etc/ssl'
```
Fix by rebuilding with the flag explicit, same as section 10.1 — whether that means redoing the hand-built recipe from a clean extraction, or fixing whichever `lambda` recipe produced this one:
```sh
./configure --prefix=/usr --with-openssl --with-ca-bundle=/etc/ssl/cert.pem --without-libpsl
make
make install
curl -v https://dbus.freedesktop.org/ -o /dev/null 2>&1 | grep CAfile   # should now print /etc/ssl/cert.pem
```

**`wget`'s `configure` fails with `configure: error: The pkg-config script could not be found or is too old`, even though `openssl` built fine and `curl` already works with `--with-openssl`.**
Unlike `curl`, `wget`'s `configure.ac` detects OpenSSL by querying it through `pkg-config` (has done so since OpenSSL 1.0.0) instead of falling back to a manual `-lssl -lcrypto` probe — with no `pkg-config` on `PATH` at all, that lookup can't even attempt the fallback and `configure` aborts outright. Build `pkg-config` first (see the `pkg-config` subsection in 10.1, right before `wget`), confirm it's on `PATH` with `pkg-config --version`, then retry:
```sh
cd /usr/src/wget-1.24.5
./configure --prefix=/usr --with-ssl=openssl
make
make install
```

**`git clone https://...` fails with `git: 'remote-https' is not a git command` / `fatal: remote helper 'https' aborted session`, even though `curl` is installed and working.**
Git only compiles its `git-remote-https` helper — the piece that actually implements the `https://` transport — if a usable `curl` was already present *when `git` itself was configured and built*. This is decided once, at Git's own build time, not looked up again later: installing `curl` afterward does not retroactively add HTTPS support to a `git` that was already built without it. This guide's build order (section 10.1: `zlib` → `perl` → `openssl` → `curl` → `pkg-config` → `wget` → `jq` → `gettext` → `git`) is arranged specifically so a TLS-capable `curl` exists before `git`'s build runs — if you built them in a different order (e.g. `git` before `curl`), the fix is to rebuild `git`, not to reinstall `curl`:
```sh
cd /usr/src/git-2.47.0
make clean
make configure
./configure --prefix=/usr --without-tcltk --disable-nls
make NO_GETTEXT=1 NO_TCLTK=1
make NO_GETTEXT=1 NO_TCLTK=1 install
```
Confirm with a real clone afterward, not just `git --version` (which succeeds either way):
```sh
git clone https://github.com/VindLinux/lambda-manager /tmp/lambda-check
```
If the error is instead `Protocol "https" not supported` (helper present, but no scheme handler behind it), that's a different root cause — see the dedicated entry above.

**`curl` to `zlib.net/zlib-<version>.tar.gz` returns `404`.**
`zlib.net` only hosts the current release at that short URL — once a new zlib version ships, the old filename moves to `zlib.net/fossils/zlib-<version>.tar.gz` (or gets replaced by a newer version at the short URL, if this guide's pinned version is now stale). This guide already pins the fossils URL (`https://zlib.net/fossils/zlib-1.3.1.tar.gz`) for exactly this reason. Check [zlib.net](https://zlib.net/) for the current version if this specific pinned version also 404s in the future, and update the version number in sections 9.1 and 10.1 to match:
```sh
curl -fL --retry 3 --retry-delay 2 -o zlib-<newer-version>.tar.gz \
    https://zlib.net/fossils/zlib-<newer-version>.tar.gz
```

### Section 13 — `lambda` recipes installing libraries under `/usr/lib64` (Meson packages)

**Boot panics or hangs early with `dracut-lib.sh`/`ismounted` errors reporting exit code 127 from `findmnt`, even though `type ismounted` confirms the function exists.** Or, later in boot, `udevadm` (or another `eudev`/`kmod`-linked binary) fails with a wall of `Error relocating ...: symbol not found` plus `Error loading shared library libkmod.so.2: No such file or directory`.

Root cause: Meson's `--libdir` auto-detection defaults to `lib64` on x86_64 by convention — a glibc/multilib assumption. musl's dynamic loader doesn't follow that convention; without an explicit search-path override it only looks in `/lib` and `/usr/lib`. Any package built with a bare `meson setup ... --prefix="$PREFIX"` (no `--libdir`) installs its `.so` files where the *binary* can't find them at runtime, even though the binary itself loads and links fine, and even though `<binary> --version` (which touches little of the library's code) can still work. This is why the failure shows up as a relocation/symbol error deep inside a real call (`findmnt /dev`, `udevadm` doing actual work) rather than at load time — it's PLT lazy binding resolving the missing symbol on first real use, not at exec.

`util-linux` (`findmnt`) and `kmod` (`udevadm`'s `libkmod.so.2` dependency) are the two packages in section 13's base set confirmed to hit this. Fix each affected recipe by pinning `--libdir` explicitly instead of letting Meson guess:

```json
"build": [
    "meson setup <pkg>/build <pkg> --prefix=\"$PREFIX\" --libdir=\"$PREFIX/lib\" --buildtype=release --wrap-mode=nodownload",
    "ninja -C <pkg>/build $MAKEOPTS"
]
```

Then rebuild the package through `lambda`, regenerate the initramfs (`dracut --force /boot/initramfs-<version>.img <version>`), and reboot to confirm.

To find every other Meson-based recipe at risk of the same bug before it bites during boot:
```sh
grep -l "meson setup" packages/*.json | xargs grep -L "libdir"
```
Any file in that list installs at least one library to an unpredictable location on this system. Confirm a given package's libraries actually landed in `lib64` (rather than assuming) with:
```sh
find / -xdev -name "lib<name>.so*" 2>/dev/null
```

Note that section 11.2's `/etc/ld-musl-x86_64.path` already lists `/usr/lib64` as a fallback search path, which masks this bug for binaries run *inside the installed system* once that file is in place. It does not help inside a `dracut`-generated initramfs unless that file is both included in the initramfs image and honored by the loader in that minimal environment — in practice, an initramfs built before this fix was applied has no `/etc/ld-musl-x86_64.path` at all. Treat the `ld-musl-x86_64.path` fallback as a safety net, not a substitute for fixing `--libdir` at the recipe level; packages should install to `/usr/lib` in the first place, the same way section 7.1 already does for musl itself via `--syslibdir="$PREFIX/lib"`.

### Section 16.3 — `runsv` fails on every tty with `unable to open supervise/lock: read-only file system`

Boot otherwise completes normally — `dracut: Switching root` succeeds, `runit` enters stage 1, `[Vind] Welcome to Vind Linux.` prints — but stage 2 fails immediately:
```
runsv agetty-tty1: fatal: unable to open supervise/lock: read-only file system
```

Root cause: the root filesystem is mounted read-only by the initramfs (`EXT4-fs (vda3): mounted filesystem ... ro with ordered data mode.` appears earlier in the boot log) and nothing ever remounts it read-write before `runit` reaches stage 2. `runit`'s stage 2 needs to create `supervise/lock` files under `/etc/runit/sv/*`, which requires a writable root.

`vind-runit`'s `runit/1` mounts `proc`, `sysfs`, `devtmpfs`, `devpts`, and `run`, but doesn't remount `/` itself — it assumes root already arrived read-write. Add the remount as the first thing stage 1 does, before any other mount:
```sh
mount -o remount,rw /
```
Rebuild/update the `vind-runit` package (or edit `runit/1` directly on the target rootfs if debugging live) and reboot. This doesn't require regenerating the initramfs — `runit/1` lives on the real root filesystem, not inside `dracut`'s image.
