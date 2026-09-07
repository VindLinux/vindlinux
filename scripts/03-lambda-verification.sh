#!/bin/sh

# 03-lambda-verification.sh
#
# Verify that everything done by the lambda-requisites completed successfully.

set -u

source ./vind-config.sh
source ./vind-utils.sh

errors=0

check_file() {
    if [ -e "$1" ]; then
        info "$2"
    else
        error "$2: not found"
        errors=$((errors + 1))
    fi
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        info "$1"
    else
        error "$1: not found"
        errors=$((errors + 1))
    fi
}

info "Verifying VIND lambda..."

# zlib
check_file "/usr/include/zlib.h" "zlib.h"
check_file "/usr/lib/libz.so.1.3.1" "libz.so.1.3.1"

# Perl
check_command "perl"

# OpenSSL
check_command "openssl"

# curl
check_command "curl"

# pkg-config
check_command "pkg-config"

# wget
if command -v wget >/dev/null 2>&1; then
    if wget --version 2>/dev/null | grep -q '+https'; then
        info "wget (+https)"
    else
        error "wget: HTTPS support not found"
        errors=$((errors + 1))
    fi
else
    error "wget: not found"
    errors=$((errors + 1))
fi

# jq
check_command "jq"

# m4
check_command "m4"

# autoconf
check_command "autoconf"

# git
check_command "git"

if [ "$errors" -eq 0 ]; then
    info "Lambda verification passed"
    exit 0
fi

error "Lambda verification failed ($errors errors)"
exit 1
