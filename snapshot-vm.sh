#!/bin/bash

# snapshot-vm.sh - snapshots of a VM, to start again from a known state
#
# This is the shared tool. Use the one in the VM's folder: macos15/snapshot-macos.sh or
# win11/snapshot-windows.sh. They set what is below and run this.
#
# usage: TOOL create  <name> [--wait] [--start]
#        TOOL restore <name> [--yes] [--start]
#        TOOL list
#        TOOL delete  <name> [--yes]
#
#   create    stops the VM, then saves a copy of its data folder in the snapshots folder.
#             --start starts the VM again afterwards.
#             --wait does not stop the VM: it waits for you to shut the system down from
#             inside (macOS: Apple menu > Shut Down), and snapshots when it has stopped
#             by itself. Use this for a snapshot that is certain to be clean.
#             Without --wait the VM is asked to shut down (ACPI power button) and is
#             powered off after 2 minutes if it does not. Windows normally shuts down
#             when asked. macOS in this setup did not: it was powered off, and the
#             snapshot is then like the disk after a power cut. APFS and NTFS recover
#             from that, but it is not clean. The tool says which one it got, and
#             records it (see list).
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
# WAIT_TIMEOUT is how many seconds --wait waits (default 600).
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

# SHUTDOWN says how the VM last stopped under this tool:
#   clean    the guest shut itself down (--wait), or the stop did not need to cut power
#   forced   the guest did not react to the shutdown request and QEMU was killed
#   unknown  the VM was not running, or the logs could not say
SHUTDOWN=unknown

# was_forced <since>: did QEMU have to be killed? Its log says so when it gets the signal.
# The text is in the container log, or, for a service (which removes its container when
# it stops), in the journal.
was_forced() {
    local since="$1" text=""
    text="$(podman logs --since "$since" "$CONTAINER" 2>&1 || true)"
    if unit_exists; then
        text="$text
$(journalctl --user -u "$UNIT" --since "@$(date -d "$since" +%s 2>/dev/null || echo 0)" --no-pager -o cat 2>/dev/null || true)"
    fi
    case "$text" in
        *"terminating on signal"*) return 0 ;;
    esac
    return 1
}

# stop_vm: asks the guest to shut down, through the service when there is one. QEMU is
# killed after 2 minutes if the guest ignores the request. Sets SHUTDOWN.
stop_vm() {
    local since stopped=0
    since="$(date -u '+%FT%TZ')"
    if unit_exists && unit_active; then
        echo "Stopping $UNIT (asks the guest to shut down; power is cut after 2 minutes if it does not)..."
        systemctl --user stop "$UNIT"
        stopped=1
    fi
    if container_exists && container_running; then
        echo "Stopping $CONTAINER (asks the guest to shut down; power is cut after 2 minutes if it does not)..."
        podman stop --time 120 "$CONTAINER" >/dev/null
        stopped=1
    fi
    [ "$stopped" = 1 ] || return 0
    if was_forced "$since"; then
        SHUTDOWN=forced
        echo "Note: the guest did not shut down when asked, so power was cut. The disk is as"
        echo "      after a power cut. That is usually fine, but it is not a clean shutdown."
        echo "      For a clean one, use --wait and shut the guest down from inside."
    else
        SHUTDOWN=clean
    fi
}

# wait_vm: waits for the guest to shut itself down, and leaves SHUTDOWN=clean when it did.
#
# A container with a restart policy would start the VM again as soon as the guest quits,
# so the policy is switched off for the wait and put back afterwards (also on Ctrl-C).
# A service stays as it is: it only restarts after a failure, and a shutdown from inside
# is a normal exit.
wait_vm() {
    local limit="${WAIT_TIMEOUT:-600}" waited=0 policy="" running=0
    if unit_exists && unit_active; then
        running=1
    elif container_exists && container_running; then
        running=1
        policy="$(podman inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null || true)"
        case "$policy" in
            ''|no) policy="" ;;
            *)
                podman update --restart=no "$CONTAINER" >/dev/null ||
                    die "could not switch off the restart policy of $CONTAINER, so it would start again by itself"
                trap 'restore_policy' EXIT
                trap 'restore_policy; exit 130' INT TERM
                RESTORE_POLICY="$policy"
                ;;
        esac
    fi
    if [ "$running" = 0 ]; then
        echo "$CONTAINER is not running."
        return 0
    fi

    echo "Now shut the VM down from inside it (macOS: Apple menu > Shut Down)."
    if [ "$limit" -ge 120 ]; then
        echo "Waiting up to $((limit / 60)) minutes for it to stop; the snapshot is made when it has."
    else
        echo "Waiting up to $limit seconds for it to stop; the snapshot is made when it has."
    fi
    while { unit_exists && unit_active; } || { container_exists && container_running; }; do
        if [ "$waited" -ge "$limit" ]; then
            restore_policy
            die "the VM is still running after $limit seconds; shut it down and run this again"
        fi
        sleep 3
        waited=$((waited + 3))
    done
    restore_policy
    SHUTDOWN=clean
    echo "The VM shut down by itself."
}

RESTORE_POLICY=""
restore_policy() {
    [ -n "$RESTORE_POLICY" ] || return 0
    if container_exists; then
        podman update --restart="$RESTORE_POLICY" "$CONTAINER" >/dev/null 2>&1 ||
            echo "Warning: could not put the restart policy of $CONTAINER back to '$RESTORE_POLICY'." >&2
    fi
    RESTORE_POLICY=""
    trap - EXIT INT TERM
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
WAIT=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --start) START=1 ;;
        --wait) WAIT=1 ;;
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

        if [ "$WAIT" = 1 ]; then
            wait_vm
        fi
        stop_vm
        container_running && die "$CONTAINER is still running; stop it and try again"

        mkdir -p "$SNAPS"
        echo "Saving $STORAGE as snapshot '$NAME'..."
        TMP="$SNAPS/.$NAME.partial"
        rm -rf "${TMP:?}"
        copy_tree "$STORAGE" "$TMP"
        mv "$TMP" "$SNAPS/$NAME"
        printf 'name: %s\ncreated: %s\nshutdown: %s\n' "$NAME" "$(date '+%F %T')" "$SHUTDOWN" > "$SNAPS/$NAME.info"
        echo "Snapshot '$NAME' saved in $SNAPS/$NAME (shutdown: $SHUTDOWN)"

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
        printf '%-28s %-20s %-9s %s\n' NAME CREATED SHUTDOWN SIZE
        for d in "$SNAPS"/*/; do
            n="$(basename "$d")"
            created="$(sed -n 's/^created: //p' "$SNAPS/$n.info" 2>/dev/null)"
            how="$(sed -n 's/^shutdown: //p' "$SNAPS/$n.info" 2>/dev/null)"
            printf '%-28s %-20s %-9s %s\n' "$n" "${created:-unknown}" "${how:-unknown}" "$(human_size "$d")"
        done
        echo
        echo "SHUTDOWN: clean = the guest shut itself down; forced = power was cut; unknown ="
        echo "it is not known (the snapshot was made while the VM was already stopped)."
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
