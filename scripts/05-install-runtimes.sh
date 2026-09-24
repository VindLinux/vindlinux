#!/bin/sh

# 05-install-runtimes.sh.
#
# Patches some recipes and config files to install libc++, libc++abi, ninja and cmake

. ./vind-config.sh
. ./vind-utils.sh

export MARKERS="/building/markers"

mkdir -p "$MARKERS" || {
    error "Failed to create markers directory"
    exit 1
}

# lambda configuration

if [ ! -f "$MARKERS/.runtime_lambda_config_done" ]; then

    sed -i -e 's/^export CC="gcc"$/export CC="clang"/' -e 's/^export CXX="g++"$/export CXX="clang++"/' /etc/lambda/make.conf || {
        error "Failed to switch compiler to clang"
        exit 1
    }

    touch "$MARKERS/.runtime_lambda_config_done" || {
        error "Failed to create lambda configuration marker"
        exit 1
    }
fi

# install libc++ runtime

if [ ! -f "$MARKERS/.runtime_libcxx_done" ]; then
    lambda mutate append libc++ libc++abi || {
        error "Failed to append libc++ and libc++abi"
        exit 1
    }

    lambda reconcile || {
        error "Failed to reconcile libc++ and libc++abi"
        exit 1
    }

    touch "$MARKERS/.runtime_libcxx_done" || {
        error "Failed to create libc++ marker"
        exit 1
    }
fi

# remove bootstrap tools

if [ ! -f "$MARKERS/.runtime_bootstrap_remove_done" ]; then
    lambda force-remove ninja cmake || {
        error "Failed to remove ninja and cmake"
        exit 1
		}

    touch "$MARKERS/.runtime_bootstrap_remove_done" || {
        error "Failed to create bootstrap purge marker"
        exit 1
    }
fi


# install build tools

if [ ! -f "$MARKERS/.runtime_tools_done" ]; then
    lambda mutate append cmake ninja || {
        error "Failed to append cmake and ninja"
        exit 1
    }

    lambda reconcile || {
        error "Failed to reconcile cmake and ninja"
        exit 1
    }

    touch "$MARKERS/.runtime_tools_done" || {
        error "Failed to create runtime tools marker"
        exit 1
    }
fi

info "install runtimes finished."
