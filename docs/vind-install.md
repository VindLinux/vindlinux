# Vind Linux — Install Guide

This is the quick version: partition, install the base system, configure it, make it bootable. If you want the *why* behind any step, [building.md](building.md) (the from-scratch build guide) goes into a lot more detail — this one's meant to be followed, not studied.

## 1. Partition and mount the disk

Boot the Vind Linux live ISO and drop to a shell. From here you need to: partition the disk, put filesystems on those partitions, and mount them under `/mnt/vind` before the install can start.

### 1.1 Pick a partitioner

Any of these work — use whichever you're comfortable with, they all ship on the live ISO:

- **`cfdisk`** — the easiest one if you just want a menu-driven experience. Good default if you're not picky.
- **`fdisk`** — the classic, fully keyboard-driven, works on both MBR and GPT.
- **`gdisk`** — same idea as `fdisk` but GPT-only, with a couple of GPT-specific niceties (partition typecodes, etc).
- **`parted`** — scriptable, good if you want to partition non-interactively.

This guide assumes **GPT**, not MBR — needed for UEFI boot regardless of which bootloader you end up picking later. A minimal layout:

```
/dev/vda1   512M–1G   EFI System Partition (type: EFI System)
/dev/vda2   RAM size  swap (type: Linux swap)
/dev/vda3   rest      root (type: Linux filesystem)
```

Example with `cfdisk`:

```sh
cfdisk /dev/vda
# create a GPT label, then the three partitions above with the right types
```

Check your work:

```sh
lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
vda    253:0    0   50G  0 disk
├─vda1 253:1    0    1G  0 part
├─vda2 253:2    0    4G  0 part
└─vda3 253:3    0   45G  0 part
```

### 1.2 Filesystems

For `/` (and `/home` if you're splitting it out), pick one:

- **ext4** — the boring, safe default. Mature, simple, no moving parts to think about. Go with this if you don't have a specific reason to want the stuff btrfs offers.
- **btrfs** — copy-on-write, with built-in snapshots, subvolumes, transparent compression, and (if you care) multi-device RAID. Worth it if you actually want snapshots (e.g. "roll back before a bad `lambda reconcile`") — otherwise it's more moving parts for no benefit.

**ext4, single root:**

```sh
mkfs.vfat -F32 /dev/vda1
mkswap /dev/vda2 && swapon /dev/vda2
mkfs.ext4 /dev/vda3

mkdir -p /mnt/vind
mount /dev/vda3 /mnt/vind
mkdir -p /mnt/vind/boot/efi
mount /dev/vda1 /mnt/vind/boot/efi
```

**btrfs, with `/` and `/home` as separate subvolumes on the same partition:**

```sh
mkfs.vfat -F32 /dev/vda1
mkswap /dev/vda2 && swapon /dev/vda2
mkfs.btrfs /dev/vda3

# create the subvolumes
mount /dev/vda3 /mnt/vind
btrfs subvolume create /mnt/vind/@
btrfs subvolume create /mnt/vind/@home
umount /mnt/vind

# mount them where they actually belong
mount -o subvol=@ /dev/vda3 /mnt/vind
mkdir -p /mnt/vind/home /mnt/vind/boot/efi
mount -o subvol=@home /dev/vda3 /mnt/vind/home
mount /dev/vda1 /mnt/vind/boot/efi
```

(If you'd rather keep `/home` on its own physical partition instead of a subvolume, that's fine too — just add a fourth partition in 1.1 and `mkfs`/mount it at `/mnt/vind/home` the normal way, same as `/boot/efi`.)

Whichever path you took, confirm the layout before moving on:

```sh
lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
vda    253:0    0   50G  0 disk
├─vda1 253:1    0    1G  0 part /mnt/vind/boot/efi
├─vda2 253:2    0    4G  0 part [SWAP]
└─vda3 253:3    0   45G  0 part /mnt/vind
```

## 2. Download and extract the base system

```sh
cd /mnt/vind
wget https://github.com/VindLinux/vindlinux/releases/download/0.3/vind-base-0.3-x86_64.tar.xz
tar -xf vind-base-0.3-x86_64.tar.xz
rm vind-base-0.3-x86_64.tar.xz
```

## 3. Mount the pseudo filesystems and chroot in

```sh
mount --bind /dev  /mnt/vind/dev
mount -t proc proc /mnt/vind/proc
mount -t sysfs sys  /mnt/vind/sys
mount -t tmpfs tmpfs /mnt/vind/run

chroot /mnt/vind /bin/dash
```

(`/bin/ash` works too — it's got a few more built-in features, so that's my personal pick.)

## 4. Update Lambda and sync the recipes

Before touching anything else:

```sh
lambda update
lambda sync
```

## 5. Set up the toolchain symlinks

Vind ships Clang/LLVM as the toolchain, so point the usual GNU names at it:

```sh
# compilers
ln -sf /usr/bin/clang   /usr/bin/cc
ln -sf /usr/bin/clang   /usr/bin/gcc
ln -sf /usr/bin/clang++ /usr/bin/c++
ln -sf /usr/bin/clang++ /usr/bin/g++

# llvm-utils
ln -sf /usr/bin/llvm-ar      /usr/bin/ar
ln -sf /usr/bin/llvm-ranlib  /usr/bin/ranlib
ln -sf /usr/bin/llvm-nm      /usr/bin/nm
ln -sf /usr/bin/llvm-objcopy /usr/bin/objcopy
ln -sf /usr/bin/llvm-objdump /usr/bin/objdump
ln -sf /usr/bin/llvm-readobj /usr/bin/readelf
ln -sf /usr/bin/llvm-strip   /usr/bin/strip
ln -sf /usr/bin/llvm-strings /usr/bin/strings
ln -sf /usr/bin/llvm-size    /usr/bin/size
ln -sf /usr/bin/ld.lld       /usr/bin/ld
```

## 6. Install the base package set

```sh
lambda mutate append busybox ln realpath diffutils libnl pkgconf dhcpcd iproute2 kmod \
  openssh sqlite3 zstd popt dosfstools libelf musl-fts \
  shadow make argp-standalone kbd dracut ncurses dash iwd eudev parted readline \
  gawk e2fsprogs ca-certificates dbus util-linux tzdata

lambda reconcile
```

Feel free to tweak this list — add or drop packages as you need before reconciling.

## 7. Basic system configuration

### 7.1 Root user + user database

Without this, stuff like `whoami` can't even resolve UID 0.

```sh
mkdir -p /etc /etc/pam.d /root
chmod 700 /root

cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/sh
EOF

cat > /etc/group << "EOF"
root:x:0:
EOF

cat > /etc/shadow << "EOF"
root:!:19000:0:99999:7:::
EOF
chmod 600 /etc/shadow
chown root:root /etc/shadow

cat > /etc/gshadow << "EOF"
root:!::
EOF
chmod 600 /etc/gshadow

cat > /etc/pam.d/other << "EOF"
auth     required pam_unix.so
account  required pam_unix.so
password required pam_unix.so
session  required pam_unix.so
EOF
cp /etc/pam.d/other /etc/pam.d/passwd

passwd
```

### 7.2 Your own user (optional)

```sh
useradd -m -G wheel -s /bin/sh <username>
passwd <username>
```

Busybox doesn't ship `sudo` or a working `su`, so privilege escalation is up to you to set up later (`sudo`, `doas`, whatever you prefer) — not covered here.

### 7.3 Hostname

```sh
echo "my-vind" > /etc/hostname
```

### 7.4 /etc/profile

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

. /etc/profile
```

`C.UTF-8` is used instead of something like `en_US.UTF-8` because musl doesn't ship a real locale database — anything it doesn't recognize just silently falls back to `C`/`POSIX` anyway, so `C.UTF-8` is the one that actually gets you UTF-8-aware tools without pretending to be a locale that isn't really there.

### 7.5 Timezone

```sh
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
```

Swap in whatever zone you need — `ls /usr/share/zoneinfo` shows what's available. No separate `/etc/timezone` file needed; the symlink is the whole mechanism.

If the hardware clock isn't set to UTC (once you have a kernel and `/dev/rtc`):

```sh
hwclock --show
hwclock --systohc --utc
```

### 7.6 Available shells

```sh
cat > /etc/shells << 'EOF'
/bin/sh
/bin/ash
/bin/dash
EOF
```

### 7.7 /etc/os-release

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

### 7.8 GRUB defaults

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

Only relevant if you go with GRUB in 9.4 — `grub-mkconfig`. If you end up picking Limine instead you can skip this step.

## 8. Networking

### 8.1 DNS

```sh
cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

### 8.2 Wired networking with dhcpcd

```sh
ip link   # find your interface name, e.g. enp0s3 or eth0

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

# test it by hand once:
dhcpcd <interface-name>
ip addr show <interface-name>
```

If an address shows up and `/etc/resolv.conf` gets overwritten with DHCP-provided servers, it worked. `dhcpcd -k <interface-name>` tears it back down if you want to retest.

### 8.3 Wireless with iwd (optional)

Skip on a VM — only relevant for real wireless hardware.

```sh
iwctl
[iwd]# device list
[iwd]# station <device> scan
[iwd]# station <device> get-networks
[iwd]# station <device> connect <SSID>
[iwd]# exit
```

`iwd` only handles the link/auth — you still need `dhcpcd` against the interface afterward to get an IP.

### 8.4 Time sync

```sh
busybox ntpd -n -q -p pool.ntp.org
```

One-shot correction, not continuous drift discipline. Matters because a wrong clock breaks TLS handshakes (`curl`, `git`, `lambda reconcile`, etc). This gets wired into boot in section 9.3.

### 8.5 Firewall

Not covered here — nothing in the package list above provides `nftables`/`iptables`. Install one (`lambda mutate append nftables`) and write rules that actually match your setup once you know what the machine's going to do.

## 9. Preparing for boot

### 9.1 /etc/fstab

```sh
cat > /etc/fstab <<'EOF'
# <file system>   <mount point>  <type>  <options>        <dump> <pass>
/dev/vda3         /              ext4    defaults         0      1
/dev/vda1         /boot/efi      vfat    umask=0077       0      2
/dev/vda2         swap           swap    defaults         0      0
EOF
```

**Do yourself a favor and use `UUID=...` (from `blkid`) instead of raw `/dev/vdaX` paths** — the above works but is fragile against device renumbering on real hardware.

### 9.2 Kernel

Not in the Lambda repo — build it yourself from the [Vind-Kernel](https://github.com/VindLinux/vind-kernel) tree:

```sh
git clone --depth 1 --single-branch --branch vind https://github.com/VindLinux/vind-kernel.git
```

Check [VIND.md](https://github.com/VindLinux/vind-kernel/blob/vind/VIND.md) for build instructions and defconfigs. Hardware-specific drivers are on you (`make menuconfig`/`nconfig`).

If everything needed at boot is built into the kernel (not as modules), you don't need an initramfs — skip to 9.3. If any of it's a `.ko` module, set one up:

```sh
# depmod must come from kmod, not busybox
rm -f /usr/bin/depmod
ln -s /usr/bin/kmod /usr/bin/depmod
depmod <kernel-version>

# disable i18n unless you need keymap/locale support in the initramfs
echo 'omit_dracutmodules+=" i18n "' > /etc/dracut.conf.d/no-i18n.conf

dracut --force /boot/initramfs-<kernel-version>.img <kernel-version>
```

You can delete the `vind-kernel` checkout once the kernel's installed — just wait until you've confirmed it actually boots, in case you need to recompile.

On real hardware (skip on a VM), you'll also want CPU microcode updates (Intel/AMD) picked up by dracut's early-microcode mechanism — not packaged by Lambda yet, so that's on you for now.

### 9.3 Init system (runit)

Vind defaults to runit but doesn't force it — swap it for whatever you prefer, just know you're on your own for setup.

```sh
lambda mutate append vind-runit
lambda reconcile
```

If `runsv` fails immediately with `unable to open supervise/lock: read-only file system`, see `building-troubleshooting.md`.

**Wire up dhcpcd and time sync as services:**

```sh
# dhcpcd needs its privsep user to exist first
groupadd -r dhcpcd
useradd -r -g dhcpcd -d /var/lib/dhcpcd -s /sbin/nologin -c 'dhcpcd PrivSep' dhcpcd
mkdir -p /var/lib/dhcpcd /var/run/dhcpcd
chown dhcpcd:dhcpcd /var/lib/dhcpcd /var/run/dhcpcd

mkdir -p /etc/sv/dhcpcd/log/main
cat > /etc/sv/dhcpcd/run << 'EOF'
#!/bin/sh
exec dhcpcd --nobackground
EOF
chmod +x /etc/sv/dhcpcd/run

cat > /etc/sv/dhcpcd/log/run << 'EOF'
#!/bin/sh
exec svlogd -tt ./main
EOF
chmod +x /etc/sv/dhcpcd/log/run

ln -sf /etc/sv/dhcpcd /etc/service/dhcpcd

# ntp is one-shot, so the run script does the sync then just sleeps
mkdir -p /etc/sv/ntpsync
cat > /etc/sv/ntpsync/run << 'EOF'
#!/bin/sh
busybox ntpd -n -q -p pool.ntp.org
exec sleep 999999
EOF
chmod +x /etc/sv/ntpsync/run

ln -sf /etc/sv/ntpsync /etc/service/ntpsync
```

A couple of things worth knowing if you're curious why it's written this way: `--nobackground` is required because `runsv` respawns anything that exits, so a daemon that forks itself into the background looks like a crash. Same idea with the `sleep` in `ntpsync` — a one-shot script that just exits looks like a crashing service and gets respawned in a loop. And the `log/run` script isn't optional once a `log/` directory exists — `runsv` expects one and treats a missing one as fatal. Full explanation is in `building.md` §16.3.1 if you want the details.

### 9.4 Bootloader — GRUB or Limine

Pick one. Neither is installed by default (section 6 deliberately leaves both out) — grab whichever you want here, then reconcile.

**Option A — GRUB.** The familiar choice, config-file driven, generates its menu from whatever kernels it finds in `/boot`.

```sh
lambda mutate append grub efibootmgr
lambda reconcile

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=VindLinux --removable
grub-mkconfig -o /boot/grub/grub.cfg
```

`--removable` also installs a fallback path (`EFI/BOOT/BOOTX64.EFI`) — good to keep on a VM/disk image, drop it on real hardware where a normal NVRAM entry is preferred. Re-run `grub-mkconfig` any time the kernel changes. (`/etc/default/grub` from 7.7 is what `grub-mkconfig` reads.)

**Option B — Limine.** Lighter, faster, config is a plain text file you write by hand instead of one `grub-mkconfig` generates for you.

```sh
lambda mutate append limine
lambda reconcile

mkdir -p /boot/efi/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI

cat > /boot/limine.cfg << EOF
TIMEOUT=5

:Vind Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-<kernel-version>
    CMDLINE=root=/dev/vda3 rw
EOF
```

Replace `<kernel-version>` with whatever 9.2 actually built, and add an `INITRD_PATH=` line under the entry if you set up an initramfs. Limine doesn't scan for kernels the way `grub-mkconfig` does — you edit `/boot/limine.cfg` by hand whenever the kernel changes. If you want it registered as a proper NVRAM boot entry instead of relying on the fallback path, `efibootmgr` (from Option A, or installed standalone) still works fine here too.

### 9.5 Leave the chroot and boot

```sh
exit
umount -R /mnt/vind/dev /mnt/vind/proc /mnt/vind/sys /mnt/vind/run
swapoff /dev/vda2
umount -R /mnt/vind
reboot
```

Pull the install media before it restarts so the firmware boots from `/dev/vda`.

### 9.6 Post-boot smoke test

Quick checklist to run once it's up — each line pokes at a different piece, so if something fails you know roughly where to look:

```sh
whoami                        # user database is sane (root resolves)
uname -a                      # confirms the kernel that's actually running
mount | grep vda3             # root is mounted from the right partition
ip addr show                  # dhcpcd brought an interface up
cat /etc/resolv.conf          # DNS config is in place
date                          # clock is sane, not 1970 or decades off
ping -c 1 1.1.1.1              # network reaches the outside world
curl -sI https://github.com   # TLS trust chain works end to end
gcc --version 2>&1 | head -1  # should fail — gcc isn't a real binary here
clang --version               # Clang is the live compiler
lambda --help                 # package manager is intact post-reboot
sv status dhcpcd ntpsync      # both services are up under runit
```

If all of that checks out, you're good — toolchain, package manager, networking, time, and TLS trust are all actually working together, not just sitting on disk.
