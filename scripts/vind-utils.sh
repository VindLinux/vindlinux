#!/bin/sh

# vind-utils
#
# Simple display functions

error() {
  echo '[ERROR]' "$*" >&2
}

warn() {
  echo '[WARNING]' "$*" >&2
}

info() {
  echo '[INFO]' "$*"
}
