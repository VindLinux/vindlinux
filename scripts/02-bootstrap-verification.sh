#!/bin/sh

set -u

. ./vind-config.sh
. ./vind-utils.sh

errors=0

check_binary() {
    if [ ! -e "$1" ]; then
        error "$2: not found"
        errors=$((errors + 1))
        return
    fi

    case "$(file "$1")" in
        *"ld-musl-"*|*"statically linked"*)
            info "$2"
            ;;
        *)
            error "$2: not a musl/static binary"
            errors=$((errors + 1))
            ;;
    esac
}

info "Verifying VIND bootstrap..."

# musl
if [ -f "$VIND/usr/lib/ld-musl-x86_64.so.1" ]; then
    info "musl loader"
else
    error "musl loader not found"
    errors=$((errors + 1))
fi

# binaries
check_binary "$VIND/usr/bin/busybox" "busybox"
check_binary "$VIND/bin/dash" "dash"
check_binary "$VIND/usr/bin/flex" "flex"
check_binary "$VIND/usr/bin/make" "make"
check_binary "$VIND/usr/bin/as" "as"
check_binary "$VIND/usr/bin/ld" "ld"
check_binary "$VIND/usr/bin/gcc" "gcc"

# headers
if [ -f "$VIND/usr/include/linux/mman.h" ]; then
    info "linux/mman.h"
else
    error "linux/mman.h not found"
    errors=$((errors + 1))
fi

if [ "$errors" -eq 0 ]; then
    info "Bootstrap verification passed"
    exit 0
fi

error "Bootstrap verification failed ($errors errors)"
exit 1
