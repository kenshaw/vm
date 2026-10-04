#!/bin/bash

# snapshot-windows.sh - snapshots of the Windows 11 VM, to start again from a known state
#
# usage: snapshot-windows.sh create  <name> [--wait] [--start]
#        snapshot-windows.sh restore <name> [--yes] [--start]
#        snapshot-windows.sh list
#        snapshot-windows.sh delete  <name> [--yes]
#
# This only says which VM it is. The work is done by ../snapshot-vm.sh, which explains
# how a snapshot is made (btrfs reflinks) and how it works with the systemd service.
# CONTAINER, STORAGE, SNAPS and LAUNCH can be set in the environment to override the
# values below.

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CONTAINER="${CONTAINER:-windows11}"
VM_DATA="${VM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/vm}"
export STORAGE="${STORAGE:-$VM_DATA/win11/data}"
export SNAPS="${SNAPS:-$VM_DATA/win11/snapshots}"
export LAUNCH="${LAUNCH:-$HERE/launch-windows.sh}"
export TOOL="${TOOL:-$0}"

exec "$HERE/../snapshot-vm.sh" "$@"
