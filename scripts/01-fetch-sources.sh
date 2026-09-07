#!/bin/sh

# 01-fetch-sources.sh
#
# Download ALL necessary packages.
# Existing packages are skipped.
# Interrupted downloads are resumed.

set -u

mkdir sources/ && cd sources/

wget -nc \
    https://mirrors.edge.kernel.org/gnu/gcc/gcc-13.3.0/gcc-13.3.0.tar.xz \
    https://mirrors.edge.kernel.org/gnu/binutils/binutils-2.44.tar.gz \
    https://mirrors.edge.kernel.org/gnu/mpfr/mpfr-4.2.2.tar.xz \
    https://mirrors.edge.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz \
    https://mirrors.edge.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz
