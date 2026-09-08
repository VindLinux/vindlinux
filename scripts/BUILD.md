# Building Vind Linux (Scripted Build)

> Hit an error partway through a step? Check [building-troubleshooting.md](building-troubleshooting.md) before assuming something's wrong with your host — it's indexed by section number and covers the failures people actually run into at each step.

This guide walks through building Vind Linux using the numbered scripts shipped in the `vindlinux` repository, instead of running each build step by hand. The scripts wrap the same stages [building.md](building.md) documents manually — Phase 1 bootstrap, `chroot`, and Phase 2's native build up through `lambda` — so if a script fails partway through, the corresponding section of [building.md](building.md) is the place to look for what it's actually doing under the hood and why.

The build is split the same way as the manual guide:

- **Fetch** — download every source package the rest of the build needs, up front, so nothing later stalls mid-build waiting on the network.
- **Bootstrap** — cross-build just enough of a base system to get a working `chroot`.
- **Chroot** — hand off from the host to the target system.
- **Lambda** — build and install `lambda`, Vind Linux's package manager, then use it to pull in everything else — starting with LLVM/Clang, which is the long pole in the whole build.

---

## Build Environment

Before starting the build, make sure you have:

- A partitioned disk or filesystem for VIND.
- The target filesystem mounted at `/mnt/vind`.
- Git installed.
- A working internet connection.

Export the VIND directories:

```sh
export VIND=/mnt/vind
export BUILD_VIND="$VIND/building"
export SOURCES="$BUILD_VIND/sources"
```

> **NOTE:** if you change any export you must edit `vind-config.sh` too. The numbered scripts below source `vind-config.sh` for these same three paths rather than re-deriving them, so an export changed here and not mirrored there will leave the scripts building against a different `$SOURCES`/`$BUILD_VIND` than the one you're looking at — usually surfacing as a script insisting a package needs re-downloading when it's actually already sitting on disk, just under the path you forgot to update.

Create the build directory:

```sh
mkdir -pv "$BUILD_VIND"
```

Clone the VIND repository:

```sh
cd "$VIND"

git clone https://github.com/VindLinux/vindlinux
```

Copy the build scripts:

```sh
cp -av vindlinux/scripts/. "$BUILD_VIND/"
```

This copies the scripts into `$BUILD_VIND` rather than running them out of the clone directly, so `$VIND/vindlinux` can be deleted later without taking the in-progress build's scripts and state with it.

Enter the build directory:

```sh
cd "$BUILD_VIND"
```

## Fetch Sources

Before starting the build, download all required source packages:

```sh
./01-fetch-sources.sh
```

This is the scripted equivalent of the individual `curl`/`wget` calls in [building.md](building.md) sections 6–10 — every tarball the rest of the build needs, fetched once and cached under `$SOURCES`, instead of pulled on demand mid-build. The source-fetching script automatically skips packages that have already been downloaded, so it is safe to run it multiple times: if it fails partway through on a flaky mirror, re-running it picks up only what's missing rather than starting over.

After all sources have been downloaded successfully, proceed with the next build stage.

## Bootstrap

```sh
./02-bootstrap.sh
```

This runs Phase 1 of [building.md](building.md) end to end: building the Pass 1 cross-toolchain, then cross-building musl, Busybox, dash, and the rest of the minimal target system into `$VIND`. It's the longest-running step before you ever reach a `chroot`, and also the one most sensitive to host quirks (DNS resolution, IPv6 fetch failures, parallel-build races) — see [building-troubleshooting.md](building-troubleshooting.md) if it stops partway through rather than assuming the script itself is broken.

After bootstrap verify:

```sh
./02-bootstrap-verify.sh
```

This checks the things [building.md](building.md) has you verify by hand at each step of Phase 1 — that musl's dynamic loader landed under `$VIND/usr/lib`, that the cross-built binaries actually link against musl and not the host's glibc, and so on — in one pass instead of one `file`/`find` command per package. If everything succeeds you can continue.

## Chroot

```sh
mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"

chroot "$VIND" /bin/dash
```

These four mounts give the chroot a working `/dev`, `/proc`, `/sys`, and `/run` — without them, most of what gets built in Phase 2 either can't see real devices, can't read process/kernel state, or has nowhere to put runtime sockets and PID files, and fails in ways that look unrelated to the actual missing mount. They're bind/virtual mounts of the host's own `/dev`, `/proc`, `/sys`, and a fresh `tmpfs` for `/run` — not persisted anywhere on `$VIND`'s disk — so they need to be re-done every time you re-enter the chroot after a reboot, and unmounted (in reverse order) before you leave it for good.

`/bin/ash` works here too. Either shell is fine for everything in this guide; use whichever you prefer — both are provided by the Busybox build from the Fetch/Bootstrap stages above.

## Chroot System

```sh
cd building/
```

This is the same `$BUILD_VIND` directory from the host side, just seen from inside the chroot at its path relative to `$VIND`'s new root (`/`) — the scripts you copied in before `chroot`ing are already sitting here waiting, no need to re-fetch or re-copy anything.

## Build Lambda Requisites

```sh
./03-lambda-requisites.sh
```

This installs whatever `lambda` itself needs to build and run natively inside the chroot — this is Phase 2's native build, so unlike the Bootstrap stage there's no `--host`/cross flags involved, just a plain build against the musl toolchain that's now the system's own compiler.

## Verify

```sh
./03-lambda-verification.sh
```

Checks that the requisites installed cleanly before you spend time building `lambda` itself on top of a broken prerequisite. If everything succeeds you can continue.

## Lambda Packaging

```sh
./04-install-lambda.sh
```

Builds and installs `lambda` proper. Once this finishes, package management inside the chroot goes through `lambda` instead of by-hand `./configure && make install` — this is the same handoff [building.md](building.md) describes: packages built manually up to this point get reinstalled through `lambda` once it exists, so the system ends up with a proper manifest rather than files dropped in by hand.

After that:

```sh
lambda reconcile
```

This going take a loooooong time, llvm + dependencies. `lambda reconcile` is what actually pulls in and builds everything `lambda`'s manifest currently declares — starting with LLVM/Clang, which Vind Linux uses to bootstrap off GCC entirely once it's confirmed working. There's no useful way to shortcut this: LLVM is a large C++ codebase and this is the point in the build where that cost gets paid. Let it run; if it stops with an error rather than just running long, check [building-troubleshooting.md](building-troubleshooting.md) before restarting `reconcile` from scratch.
