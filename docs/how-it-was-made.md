# How NullOS Was Made

NullOS did not start as a ready-made distribution, nor was it built by strictly following a guide such as Linux From Scratch.

It started with basically nothing.

## 1. The Beginning

To start development, I used a Gentoo ISO as a temporary build environment. Gentoo is **not** part of the final NullOS system — it was only used as the environment from which the system was built.

I created:

```text
/mnt/nullos
```

and started building the system inside it.

The idea was simple: install and configure everything that was necessary until that directory stopped being just a root filesystem and became a Linux system capable of booting on its own.

This is where the idea of building NullOS as a **LFN (Linux From Nothing)** came from.

## 2. Building the System

Instead of installing an entire existing distribution into `/mnt/nullos`, the required components were added individually.

Some of the main components include:

* Linux
* musl
* BusyBox
* LLVM/Clang
* dash
* runit
* eudev
* kmod
* util-linux
* ncurses
* OpenSSL
* OpenSSH
* GRUB
* and other components required to form the system

The goal was not simply to copy an existing Linux installation, but to build a small and controlled system from individual components.

## 3. musl

NullOS uses **musl** as its C library.

The choice of musl is part of the project's philosophy of keeping the system small, simple, and lightweight.

This also means that several components have to be built specifically for the musl environment.

## 4. LLVM/Clang

The default compiler in NullOS is **LLVM/Clang**.

Unlike traditional Linux distributions where GCC commonly fills this role, NullOS uses Clang as its primary toolchain.

The goal is to keep the final system independent of GCC.

## 5. BusyBox and Basic Utilities

BusyBox provides many of the basic utilities used by the system.

Other utilities are installed separately when BusyBox does not provide the required functionality or when a dedicated implementation is more appropriate (for exemple gawk and ln).

The goal is to avoid carrying unnecessary software simply because it is traditionally included in a Linux distribution.

## 6. The Init System

NullOS uses **runit** as its init system.

The runit initialization structure was configured manually, including its stages and the services required to bring the system up.

The current system includes, among others:

* `runit`
* `agetty`
* `sshd`

Services are managed through `/etc/service`.

The shutdown process was also configured to stop services, synchronize data, disable swap, and unmount filesystems before shutting down or rebooting.

## 7. Boot

The current bootloader is **GRUB**, running in a **UEFI** environment.

The basic boot process looks like this:

```text
UEFI
 │
 ▼
GRUB
 │
 ▼
Linux Kernel
 │
 ▼
runit
 │
 ├── agetty
 ├── sshd
 └── other services
 │
 ▼
NullOS
```

After the kernel is loaded, runit takes over the system initialization process.

## 8. npkg

NullOS has its own package manager: **npkg**.

npkg is written in C and is responsible for installing packages on the final system.

Package recipes are maintained separately and contain the information required to obtain, build, and install each package.

The goal is for the final system to have its own package management infrastructure instead of depending on another distribution's package manager.

The Gentoo environment used during development therefore has nothing to do with package management on the final NullOS system.

## 9. The Final System

After installing the required components into `/mnt/nullos`, configuring the kernel, bootloader, init system, and services, the system became capable of booting independently.

The environment used to build the system can then be discarded.

In other words:

```text
Gentoo Live ISO
      │
      │ temporary build environment
      ▼
 /mnt/nullos
      │
      ├── musl
      ├── LLVM/Clang
      ├── BusyBox
      ├── runit
      ├── kernel
      ├── GRUB
      ├── services
      └── other components
      │
      ▼
   NullOS
```

Gentoo was only the tool used to build the system. The resulting system is NullOS.

## 10. Current State

NullOS already has a functional base capable of booting and providing a usable environment.

Currently, the system includes:

* UEFI + GRUB boot
* Linux kernel
* musl
* LLVM/Clang
* BusyBox
* runit
* agetty
* OpenSSH
* service management
* npkg
* various system libraries and utilities

There is currently **no official NullOS ISO**.

For now, the system is built directly into the target filesystem. Creating a reproducible build process capable of generating a bootable image/ISO is one of the next major steps of the project.

## 11. Why Build It This Way?

The goal of NullOS is not simply to create another Linux distribution.

The project is an experiment in understanding and controlling every layer of the system, from the boot process to package management.

It also explores how small and independent a Linux system can be when its components are deliberately selected, built, and configured instead of being inherited from a traditional distribution.

NullOS is being built from the bottom up, one component at a time.

And yes, sometimes that means spending hours figuring out why some random fucking library refuses to compile.
