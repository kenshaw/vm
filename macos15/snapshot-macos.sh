#!/bin/bash

# snapshot-macos.sh - snapshots of the macOS VM, to start again from a known state
#
# usage: snapshot-macos.sh create  <name> [--start]
#        snapshot-macos.sh restore <name> [--yes] [--start]
#        snapshot-macos.sh list
#        snapshot-macos.sh delete  <name> [--yes]
#
#   create    stops the VM (a clean shutdown), then saves a copy of macos-data/ as
#             snapshots/<name>/. --start starts the VM again afterwards.
#   restore   removes the container, replaces macos-data/ with the snapshot, and says
#             how to start the VM (or starts it with --start). Everything the VM has
#             done since the snapshot is lost. That is the point of it.
#   list      shows the snapshots.
#   delete    removes a snapshot.
#
# A snapshot is a copy of macos-data/: the disk, the boot disk, the recovery image and
# the machine identity. On btrfs the copy is a reflink: it takes a moment and uses no
# extra space until the VM changes the disk, and then only for the changed blocks. On
# another file system it is a full copy (about 30 GB for an installed macOS).
#
# Take a snapshot only after the VM has been shut down cleanly. This script does that.

set -e

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:-macos15}"
STORAGE="${STORAGE:-$HERE/macos-data}"
SNAPS="${SNAPS:-$HERE/snapshots}"
LAUNCH="${LAUNCH:-$HERE/launch-macos.sh}"

usage() {
    awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
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

# copy_tree <from> <to>: copies a folder file by file, with a reflink where it can.
#
# The VM's disk image has the NOCOW attribute (C), which the container sets on btrfs for
# speed. btrfs clones only between two files that are both NOCOW or both not, so a copy
# made in the usual way fails to clone ("Invalid argument") and falls back to copying
# all 30 GB. So each new file gets the same attribute as its source, set while it is
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
        valid_name "$NAME" || die "give a snapshot name, such as: $0 create fresh-install"
        [ -d "$STORAGE" ] && [ -n "$(ls -A "$STORAGE" 2>/dev/null)" ] || die "$STORAGE is empty: there is no VM to snapshot"
        [ -e "$SNAPS/$NAME" ] && die "a snapshot named '$NAME' already exists (delete it first)"

        if container_exists && container_running; then
            echo "Stopping $CONTAINER for a clean shutdown (up to 2 minutes)..."
            podman stop --time 120 "$CONTAINER" >/dev/null
        fi
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
            echo "Starting $CONTAINER again..."
            if container_exists; then podman start "$CONTAINER" >/dev/null; else "$LAUNCH"; fi
        else
            echo "$CONTAINER is stopped. Start it with: podman start $CONTAINER"
        fi
        ;;

    restore)
        valid_name "$NAME" || die "give the name of a snapshot to restore (see: $0 list)"
        [ -d "$SNAPS/$NAME" ] || die "no snapshot named '$NAME' (see: $0 list)"
        echo "This replaces the current VM in $STORAGE with snapshot '$NAME'."
        echo "Everything the VM has done since that snapshot is lost."
        confirm "Restore snapshot '$NAME'?" || exit 1

        if container_exists; then
            echo "Removing the container $CONTAINER (a clean shutdown first, up to 2 minutes)..."
            podman rm --force --time 120 "$CONTAINER" >/dev/null
        fi

        TMP="$HERE/.macos-data.restoring"
        rm -rf "${TMP:?}"
        copy_tree "$SNAPS/$NAME" "$TMP"
        rm -rf "${STORAGE:?}"
        mv "$TMP" "$STORAGE"
        echo "Restored snapshot '$NAME' to $STORAGE"

        if [ "$START" = 1 ]; then
            "$LAUNCH"
        else
            echo "Start the VM with: $LAUNCH"
        fi
        ;;

    list)
        if [ ! -d "$SNAPS" ] || [ -z "$(ls -A "$SNAPS" 2>/dev/null | grep -v '\.info$')" ]; then
            echo "no snapshots (create one with: $0 create <name>)"
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
        valid_name "$NAME" || die "give the name of a snapshot to delete (see: $0 list)"
        [ -d "$SNAPS/$NAME" ] || die "no snapshot named '$NAME' (see: $0 list)"
        confirm "Delete snapshot '$NAME'?" || exit 1
        rm -rf "${SNAPS:?}/${NAME:?}"
        rm -f "${SNAPS:?}/${NAME:?}.info"
        echo "Deleted snapshot '$NAME'"
        ;;

    ''|-h|--help|help) usage ;;
    *) die "unknown command '$ACTION' (try --help)" ;;
esac
