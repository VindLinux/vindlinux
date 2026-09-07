# Build Environment

Before starting the build, make sure you have:

* A partitioned disk or filesystem for VIND.
* The target filesystem mounted at `/mnt/vind`.
* Git installed.
* A working internet connection.

Export the VIND directories:

```sh
export VIND=/mnt/vind
export BUILD_VIND="$VIND/building"
export SOURCES="$BUILD_VIND/sources"
```

NOTE: if you change any export you must edit vind-config.sh too.

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

Enter the build directory:

```sh
cd "$BUILD_VIND"
```

## Fetch Sources

Before starting the build, download all required source packages:

```sh
./01-fetch-sources.sh
```

The source-fetching script automatically skips packages that have already been downloaded, so it is safe to run it multiple times.

After all sources have been downloaded successfully, proceed with the next build stage.

## Bootstrap

```sh
./02-bootstrap.sh
```

After bootstrap verify:

```sh
./02-bootstrap-verify.sh
```

If everything succeeds you can continue

## Chroot

```
mount --bind /dev "$VIND/dev"
mount -t proc proc "$VIND/proc"
mount -t sysfs sys "$VIND/sys"
mount -t tmpfs tmpfs "$VIND/run"

chroot "$VIND" /bin/dash
```

/bin/ash works here too. Either shell is fine for everything in this guide; use whichever you prefer.

## Chroot system

```
cd building/
```

## Build lambda requisites

```
./03-lambda-requisites
```
