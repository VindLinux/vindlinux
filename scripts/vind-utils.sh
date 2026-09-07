#!/bin/sh

error() {
  echo '[ERROR]' "$*" >&2
}

warn() {
  echo '[WARNING]' "$*" >&2
}

info() {
  echo '[INFO]' "$*"
}
