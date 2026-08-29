# How Vind Linux Was Made

Vind Linux did not start as a ready-made distribution, nor was it built by strictly following a guide such as Linux From Scratch.

It started with basically nothing.

The project went through several names during development. It was originally called **NullOS**, later became **GroveOS**, and is now known as **Vind Linux**. Although the name changed, the core idea remained the same: build a Linux system from individual components and understand how each layer works.

## 1. The Beginning

To start development, I used a Gentoo ISO as a temporary build environment. Gentoo is **not** part of the final Vind Linux system, it was only used as the environment from which the system was built.

I created a separate target filesystem and started building the system inside it.

The idea was simple: install and configure everything that was necessary until that directory stopped being just a root filesystem and became a Linux system capable of booting on its own.

This is where the idea of building Vind Linux as a **LFN (Linux From Nothing)** came from.

## 2. Building the System

Instead of installing an entire existing distribution into the target filesystem, the required components were added individually.

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

Each component is selected because it serves a specific purpose in the final system.

## 3. musl

Vind Linux uses **musl** as its C library.

The choice of musl is part of the project's philosophy of keeping the system small, simple, and lightweight.

Using musl also means that several components have to be built specifically for the musl environment.

The project therefore does not rely on the assumptions commonly made by systems built around glibc.

## 4. LLVM/Clang

The default compiler toolchain in Vind Linux is **LLVM/Clang**.

Unlike traditional Linux distributions where GCC commonly fills this role, Vind Linux uses Clang as its primary compiler.

The goal is to keep the final system independent of GCC wherever practical.

LLVM also provides several other important components of the toolchain, including the linker and compiler runtime.

## 5. BusyBox and Basic Utilities

BusyBox provides many of the basic utilities used by the system.

Other utilities are installed separately when BusyBox does not provide the required functionality or when a dedicated implementation is more appropriate, for example `gawk` and `ln`.

The goal is to avoid carrying unnecessary software simply because it is traditionally included in a Linux distribution.

Vind Linux is built around the idea that every component should have a reason to exist.

## 6. The Init System

Vind Linux uses **runit** as its init system.

The runit initialization structure was configured manually, including its stages and the services required to bring the system up.

The system includes components such as:

* `runit`
* `agetty`
* `sshd`

Services are managed through `/etc/service`.

The shutdown process is also configured to stop services, synchronize data, disable swap, and unmount filesystems before shutting down or rebooting.

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
Vind Linux
```

After the kernel is loaded, runit takes over the system initialization process.

## 8. Package Management

Vind Linux has its own package management infrastructure.

The package system is based on package recipes that contain the information required to obtain, build, and install each package.

The package manager, **[Lambda](https://github.com/VindLinux/lambda-manager)**, is responsible for handling package installation and management.

Recipes are maintained separately from the base system and are used to make package builds reproducible and manageable.

The goal is for Vind Linux to have its own package management infrastructure instead of depending on another distribution's package manager.

The Gentoo environment used during development therefore has nothing to do with package management on the final Vind Linux system.

## 9. The Final System

After installing the required components into the target filesystem, configuring the kernel, bootloader, init system, and services, the system became capable of booting independently.

The environment used to build the system can then be discarded.

In other words:

```text
Gentoo Live ISO
      │
      │ temporary build environment
      ▼
 Target Filesystem
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
  Vind Linux
```

Gentoo was only the tool used to build the system. The resulting system is Vind Linux.

## 10. Current State

Vind Linux has a functional base capable of booting and providing a usable environment.

The system currently includes components such as:

* UEFI + GRUB boot
* Linux kernel
* musl
* LLVM/Clang
* BusyBox
* runit
* agetty
* OpenSSH
* service management
* package management
* various system libraries and utilities

There is currently **no official Vind Linux ISO**.

For now, the system is built directly into the target filesystem. However, if you want to try Vind Linux, you can build your own system by following the instructions in the [Building Guide](building.md).

The building process allows you to create a Vind Linux installation directly from its individual components instead of relying on a prebuilt ISO.

Creating a reproducible build process capable of generating an official bootable image/ISO is one of the next major steps of the project.

## 11. Why Build It This Way?

The goal of Vind Linux is not simply to create another Linux distribution.

The project is an experiment in understanding and controlling every layer of the system, from the boot process to package management.

It also explores how small and independent a Linux system can be when its components are deliberately selected, built, and configured instead of being inherited from a traditional distribution.

Vind Linux is being built from the bottom up, one component at a time.

The project has changed names along the way — from **NullOS**, to **GroveOS**, and finally to **Vind Linux** — but the philosophy behind it has remained the same.

And yes, sometimes that means spending hours figuring out why some random fucking library refuses to compile.

