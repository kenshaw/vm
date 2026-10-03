#!/bin/bash

# snapshot-vm.sh - snapshots of a VM, to start again from a known state
#
# This is the shared tool. Use the one in the VM's folder: macos15/snapshot-macos.sh or
# win11/snapshot-windows.sh. They set what is below and run this.
#
# usage: TOOL create  <name> [--start]
#        TOOL restore <name> [--yes] [--start]
#        TOOL list
#        TOOL delete  <name> [--yes]
#
#   create    stops the VM (a clean shutdown), then saves a copy of its data folder in
#             the snapshots folder. --start starts the VM again afterwards.
#   restore   stops and removes the VM's container, replaces the data folder with the
#             snapshot, and says how to start the VM (or starts it with --start).
#             Everything the VM has done since the snapshot is lost. That is the point.
#   list      shows the snapshots.
#   delete    removes a snapshot.
#
# A snapshot is a copy of the data folder: the disk, the boot disk, the firmware settings
# and the machine identity. On btrfs the copy is a reflink: it takes a moment and uses no
# extra space until the VM changes the disk, and then only for the changed blocks. On
# another file system it is a full copy (tens of GB for an installed VM).
#
# If the VM runs as a systemd user service (see ../install.sh), it is stopped and started
# through the service, and not behind its back.
#
# Set by the wrapper (and by you, to override):
#   CONTAINER  the container, and so the service: <CONTAINER>.service
#   STORAGE    the VM's data folder          SNAPS   where the snapshots go
#   LAUNCH     the launcher script           TOOL    the name to show in messages

set -e

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:?CONTAINER is not set; use the snapshot script in the VM folder}"
STORAGE="${STORAGE:?STORAGE is not set}"
SNAPS="${SNAPS:-$(dirname "$STORAGE")/snapshots}"
LAUNCH="${LAUNCH:?LAUNCH is not set}"
TOOL="${TOOL:-$0}"
UNIT="${UNIT:-$CONTAINER.service}"
WORK="$(dirname "$STORAGE")/.$(basename "$STORAGE").restoring"

usage() {
    awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$HERE/snapshot-vm.sh" | sed "s|TOOL|$TOOL|g"
    exit "${1:-0}"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

command -v podman >/dev/null 2>&1 || die "podman is not installed or not in PATH."

# a name is letters, digits, dots, dashes and underscores, and does not start with a dot
valid_name() {
    case "$1" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

container_exists() { podman container exists "$CONTAINER"; }

container_running() {
    [ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]
}

# the systemd user service that ../install.sh makes, if it is installed
unit_exists() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user cat "$UNIT" >/dev/null 2>&1
}

unit_active() {
    systemctl --user is-active --quiet "$UNIT" 2>/dev/null
}

# stop_vm: a clean shutdown, through the service when there is one
stop_vm() {
    if unit_exists && unit_active; then
        echo "Stopping $UNIT (a clean shutdown, up to 2.5 minutes)..."
        systemctl --user stop "$UNIT"
    fi
    if container_exists && container_running; then
        echo "Stopping $CONTAINER (a clean shutdown, up to 2 minutes)..."
        podman stop --time 120 "$CONTAINER" >/dev/null
    fi
}

# start_vm: through the service when there is one, else the container, else the launcher
start_vm() {
    if unit_exists; then
        echo "Starting $UNIT..."
        systemctl --user start "$UNIT"
    elif container_exists; then
        echo "Starting $CONTAINER..."
        podman start "$CONTAINER" >/dev/null
    else
        "$LAUNCH"
    fi
}

how_to_start() {
    if unit_exists; then
        echo "systemctl --user start $UNIT"
    elif container_exists; then
        echo "podman start $CONTAINER"
    else
        echo "$LAUNCH"
    fi
}

# copy_tree <from> <to>: copies a folder file by file, with a reflink where it can.
#
# A VM disk image has the NOCOW attribute (C), which the container sets on btrfs for
# speed. btrfs clones only between two files that are both NOCOW or both not, so a copy
# made in the usual way fails to clone ("Invalid argument") and falls back to copying
# all of it. So each new file gets the same attribute as its source, set while it is
# still empty, and then the clone works. The clone is safe: when the VM writes to its
# disk afterwards, btrfs keeps the old data for the snapshot.
copy_tree() {
    local from="$1" to="$2" rel flags cloned=0 full=0
    mkdir -p "$to"
    while IFS= read -r rel; do
        mkdir -p "$to/$rel"
    done < <(cd "$from" && find . -mindepth 1 -type d | sed 's#^\./##')

    while IFS= read -r rel; do
        : > "$to/$rel"
        flags="$(lsattr -d "$from/$rel" 2>/dev/null | awk '{ print $1 }')"
        case "$flags" in
            *C*) chattr +C "$to/$rel" 2>/dev/null ;;
        esac
        if cp -p --reflink=always "$from/$rel" "$to/$rel" 2>/dev/null; then
            cloned=$((cloned + 1))
        else
            cp -p --sparse=always "$from/$rel" "$to/$rel"
            full=$((full + 1))
        fi
    done < <(cd "$from" && find . -type f | sed 's#^\./##')

    echo "$cloned files cloned with reflinks (instant, no extra space until the VM changes them)"
    if [ "$full" -gt 0 ]; then
        echo "$full files copied in full (this file system cannot clone them; that takes time and space)"
    fi
}

confirm() {
    local prompt="$1" answer
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$prompt [y/N] " answer
    case "$answer" in
        [Yy]*) return 0 ;;
        *) echo "cancelled"; return 1 ;;
    esac
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

ACTION="${1:-}"
[ -n "$ACTION" ] && shift
NAME=""
START=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --start) START=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage ;;
        -*) die "unknown option '$arg' (try --help)" ;;
        *) [ -z "$NAME" ] && NAME="$arg" || die "more than one name given" ;;
    esac
done

case "$ACTION" in
    create)
        valid_name "$NAME" || die "give a snapshot name, such as: $TOOL create fresh-install"
        [ -d "$STORAGE" ] && [ -n "$(ls -A "$STORAGE" 2>/dev/null)" ] || die "$STORAGE is empty: there is no VM to snapshot"
        [ -e "$SNAPS/$NAME" ] && die "a snapshot named '$NAME' already exists (delete it first)"

        stop_vm
        container_running && die "$CONTAINER is still running; stop it and try again"

        mkdir -p "$SNAPS"
        echo "Saving $STORAGE as snapshot '$NAME'..."
        TMP="$SNAPS/.$NAME.partial"
        rm -rf "${TMP:?}"
        copy_tree "$STORAGE" "$TMP"
        mv "$TMP" "$SNAPS/$NAME"
        printf 'name: %s\ncreated: %s\n' "$NAME" "$(date '+%F %T')" > "$SNAPS/$NAME.info"
        echo "Snapshot '$NAME' saved in $SNAPS/$NAME"

        if [ "$START" = 1 ]; then
            start_vm
        else
            echo "The VM is stopped. Start it with: $(how_to_start)"
        fi
        ;;

    restore)
        valid_name "$NAME" || die "give the name of a snapshot to restore (see: $TOOL list)"
        [ -d "$SNAPS/$NAME" ] || die "no snapshot named '$NAME' (see: $TOOL list)"
        echo "This replaces the current VM in $STORAGE with snapshot '$NAME'."
        echo "Everything the VM has done since that snapshot is lost."
        confirm "Restore snapshot '$NAME'?" || exit 1

        stop_vm
        if container_exists; then
            echo "Removing the container $CONTAINER..."
            podman rm --force --time 120 "$CONTAINER" >/dev/null
        fi

        rm -rf "${WORK:?}"
        copy_tree "$SNAPS/$NAME" "$WORK"
        rm -rf "${STORAGE:?}"
        mv "$WORK" "$STORAGE"
        echo "Restored snapshot '$NAME' to $STORAGE"

        if [ "$START" = 1 ]; then
            start_vm
        else
            echo "Start the VM with: $(how_to_start)"
        fi
        ;;

    list)
        if [ ! -d "$SNAPS" ] || [ -z "$(ls -A "$SNAPS" 2>/dev/null | grep -v '\.info$')" ]; then
            echo "no snapshots (create one with: $TOOL create <name>)"
            exit 0
        fi
        printf '%-28s %-20s %s\n' NAME CREATED SIZE
        for d in "$SNAPS"/*/; do
            n="$(basename "$d")"
            created="$(sed -n 's/^created: //p' "$SNAPS/$n.info" 2>/dev/null)"
            printf '%-28s %-20s %s\n' "$n" "${created:-unknown}" "$(human_size "$d")"
        done
        echo
        echo "SIZE is what the snapshot would take as a separate copy. On btrfs it shares its"
        echo "data with the VM and with other snapshots, so it uses far less."
        ;;

    delete)
        valid_name "$NAME" || die "give the name of a snapshot to delete (see: $TOOL list)"
        [ -d "$SNAPS/$NAME" ] || die "no snapshot named '$NAME' (see: $TOOL list)"
        confirm "Delete snapshot '$NAME'?" || exit 1
        rm -rf "${SNAPS:?}/${NAME:?}"
        rm -f "${SNAPS:?}/${NAME:?}.info"
        echo "Deleted snapshot '$NAME'"
        ;;

    ''|-h|--help|help) usage ;;
    *) die "unknown command '$ACTION' (try --help)" ;;
esac
