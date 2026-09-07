#!/bin/sh

error() {
  printf '[ERROR]' "$*"
}

warn() {
  printf '[WARNING]' "$*"
}

info() {
  printf '[INFO]' "$*"
}
