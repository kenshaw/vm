#!/bin/bash

# snapshot-macos.sh - snapshots of the macOS 15 VM, to start again from a known state
#
# usage: snapshot-macos.sh create  <name> [--wait] [--start]
#        snapshot-macos.sh restore <name> [--yes] [--start]
#        snapshot-macos.sh list
#        snapshot-macos.sh delete  <name> [--yes]
#
# This only says which VM it is. The work is done by ../snapshot-vm.sh, which explains
# how a snapshot is made (btrfs reflinks) and how it works with the systemd service.
# CONTAINER, STORAGE, SNAPS and LAUNCH can be set in the environment to override the
# values below.

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CONTAINER="${CONTAINER:-macos15}"
VM_DATA="${VM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/vm}"
export STORAGE="${STORAGE:-$VM_DATA/macos15/data}"
export SNAPS="${SNAPS:-$VM_DATA/macos15/snapshots}"
export LAUNCH="${LAUNCH:-$HERE/launch-macos.sh}"
export TOOL="${TOOL:-$0}"

exec "$HERE/../snapshot-vm.sh" "$@"
