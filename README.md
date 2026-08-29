# Vind Linux

**A minimal Linux distribution built from scratch with musl, LLVM/Clang, BusyBox and runit.**

> **Vind Linux is an experimental Linux distribution built from nothing, one component at a time.**

## About

Vind Linux is a minimalist Linux distribution focused on simplicity, control, and understanding how a Linux system works from the ground up.

It is built manually rather than being based on an existing distribution. A Gentoo environment is currently used only as a temporary build environment; Gentoo is **not** part of the final system.

The project originally started as **NullOS**, was later renamed to **GroveOS**, and is now known as **Vind Linux**.

The current system uses:

* **musl** — C library
* **LLVM/Clang** — default compiler and toolchain
* **BusyBox** — core system utilities
* **runit** — init and service supervision
* **GRUB** — bootloader
* **UEFI** — boot environment
* **Lambda** — package manager

## Current Status

Vind Linux is currently **experimental and under active development**.

The system can already:

* Boot through UEFI and GRUB
* Start the Linux kernel
* Initialize through runit
* Provide agetty terminals
* Run system services
* Provide SSH access
* Install packages using Lambda

An official ISO is **not available yet**.

The system is currently built directly into a target filesystem. If you want to try Vind Linux, you can build your own system by following the [Building Guide](docs/building.md).

A reproducible build system and an official bootable ISO are planned for the future.

## How It Was Made

Vind Linux follows a **Linux From Nothing (LFN)** approach.

Development started from a Gentoo ISO used only as a temporary build environment. The system was gradually assembled from individual components until the resulting filesystem became a standalone, bootable Linux system.

For a more detailed explanation of the project's development, see:

**[How Vind Linux Was Made](docs/how-it-was-made.md)**

To build your own Vind Linux system:

**[Building Guide](docs/building.md)**

## Philosophy

Vind Linux is built around a few simple ideas:

* Keep the system small.
* Understand what is running.
* Avoid unnecessary dependencies.
* Build components instead of inheriting an entire distribution.
* Give the user control over the system.
* Prefer simple, focused tools.

Vind Linux is not trying to be everything for everyone.

It is an experiment in building a Linux system from the ground up.

## Repository Structure

```text
.
├── configs/     # System and kernel configuration
├── docs/        # Documentation
├── LICENSE      # Project license
└── README.md
```

## Related Projects

* **[lambda-manager](https://github.com/VindLinux/lambda-manager)** — Vind Linux package manager
* **[packages](https://github.com/VindLinux/packages)** — Vind Linux package recipes

## Contributing

Vind Linux is currently a personal experimental project, but contributions, ideas, bug reports, and discussions are welcome.

If you find something broken, feel free to open an issue.

## License

This project is licensed under the [MIT License](LICENSE).
