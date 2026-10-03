#!/bin/bash

# launch-windows.sh - Launches a Windows 11 container using Podman
# with 8 CPUs, 16GB of RAM and a 128GB disk.
#
# usage: launch-windows.sh [--recreate] [--no-oem] [--dry-run]
#
#   --recreate  remove the container and create it again. The disk is kept.
#               Use it to change the RAM, CPUs, disk size, ports or account.
#   --no-oem    do not mount shared/ as /oem, so a fresh install does NOT run
#               setup-dev.ps1 by itself. Use it to get a Windows that is installed but
#               not set up: take a snapshot of it, then run Z:\setup-dev.ps1 by hand,
#               and restore the snapshot to try the script again.
#   --dry-run   print the podman command and exit.
#
# Windows installs by itself: nothing is clicked. At the end of the install, dockur
# runs shared/install.bat, which runs shared/setup-dev.ps1 (see README.md).
#
# The Windows account is created by that install, with the name WIN_USERNAME
# (default: user) and the password WIN_PASSWORD (default: the image's own, which is
# "admin"). Changing either later does not change an installed Windows: to get a
# different account, wipe windows-data/ and install again.
#
# RAM_SIZE, CPU_CORES, DISK_SIZE, VERSION, WEB_PORT, RDP_PORT, SSH_PORT, WIN_USERNAME
# and WIN_PASSWORD can be set in the environment to override the values below. So can
# DISK_FMT, which is the format of the VM disk: raw (the image's default) or qcow2. It
# only matters before the install. (They are WIN_USERNAME and WIN_PASSWORD, not USERNAME
# and PASSWORD, because many shells export USERNAME as your own login name.)

set -e

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="windows11"
IMAGE="docker.io/dockurr/windows"
STORAGE_DIR="$HERE/windows-data"
SHARED_DIR="$HERE/shared"

VERSION="${VERSION:-11}"
DISK_SIZE="${DISK_SIZE:-128G}"
RAM_SIZE="${RAM_SIZE:-16G}"
CPU_CORES="${CPU_CORES:-8}"
DISK_FMT="${DISK_FMT:-}"

WEB_PORT="${WEB_PORT:-8006}"
RDP_PORT="${RDP_PORT:-3389}"
SSH_PORT="${SSH_PORT:-2222}"

WIN_USERNAME="${WIN_USERNAME:-user}"
WIN_PASSWORD="${WIN_PASSWORD:-}"

RECREATE=0
DRY_RUN=0
OEM=1
for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        --no-oem)   OEM=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "Error: unknown argument '$arg' (try --help)"; exit 1 ;;
    esac
done

# 1. Check if Podman is installed
if ! command -v podman &> /dev/null; then
    echo "Error: Podman is not installed or not in PATH."
    exit 1
fi

# 2. Check if /dev/kvm exists (needed for hardware acceleration)
if [ ! -e /dev/kvm ]; then
    echo "Error: /dev/kvm not found. KVM acceleration is required."
    echo "Ensure your system supports virtualization and it is enabled."
    exit 1
fi

RUN_ARGS=(
    --name "$CONTAINER_NAME"
    -p "127.0.0.1:$WEB_PORT:8006"
    -p "127.0.0.1:$RDP_PORT:3389/tcp"
    -p "127.0.0.1:$RDP_PORT:3389/udp"
    -p "127.0.0.1:$SSH_PORT:22/tcp"
    -e VERSION="$VERSION"
    -e DISK_SIZE="$DISK_SIZE"
    -e RAM_SIZE="$RAM_SIZE"
    -e CPU_CORES="$CPU_CORES"
    -e USERNAME="$WIN_USERNAME"
    --device=/dev/kvm
    --device=/dev/net/tun
    --cap-add NET_ADMIN
    --group-add keep-groups
    -v "$STORAGE_DIR:/storage"
    -v "$SHARED_DIR:/shared"
    --stop-timeout 120
    --restart on-failure
)
# dockur copies /oem to C:\OEM and runs its install.bat at the end of a fresh install
if [ "$OEM" = 1 ]; then
    RUN_ARGS+=(-v "$SHARED_DIR:/oem")
fi
if [ -n "$WIN_PASSWORD" ]; then
    RUN_ARGS+=(-e PASSWORD="$WIN_PASSWORD")
fi
if [ -n "$DISK_FMT" ]; then
    RUN_ARGS+=(-e DISK_FMT="$DISK_FMT")
fi

if [ "$DRY_RUN" = 1 ]; then
    # the password is not printed
    printf 'podman run -d'
    for a in "${RUN_ARGS[@]}"; do
        case "$a" in
            PASSWORD=*) printf ' %q' 'PASSWORD=********' ;;
            *) printf ' %q' "$a" ;;
        esac
    done
    printf ' %q\n' "$IMAGE"
    exit 0
fi

# 3. Create the storage and shared directories if they don't exist
mkdir -p "$STORAGE_DIR" "$SHARED_DIR"
echo "Storage directory: $STORAGE_DIR"
echo "Shared directory:  $SHARED_DIR  (drive Z: inside Windows, and C:\\OEM on a fresh install)"

# 4. Check if the container already exists
if podman container exists "$CONTAINER_NAME"; then
    if [ "$RECREATE" = 1 ]; then
        echo "Removing container '${CONTAINER_NAME}' (the disk in $STORAGE_DIR is kept)..."
        podman rm --force --time 120 "$CONTAINER_NAME" > /dev/null
    else
        have_user="$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" | sed -n 's/^USERNAME=//p')"
        echo "Container '${CONTAINER_NAME}' already exists. Starting it instead..."
        podman start "$CONTAINER_NAME" > /dev/null
        echo "Container started. Access the web viewer at http://localhost:$WEB_PORT"
        if [ "$have_user" != "$WIN_USERNAME" ]; then
            echo "Note: this container was made with USERNAME=${have_user:-<none, so Docker>}, and '$WIN_USERNAME' is wanted."
            echo "The account is created when Windows is installed. To get '$WIN_USERNAME', wipe"
            echo "$STORAGE_DIR and run this script again (see README.md)."
        fi
        exit 0
    fi
fi

# 5. Launch the new container
echo "Launching Windows $VERSION container: $CPU_CORES CPUs, $RAM_SIZE RAM, $DISK_SIZE disk, account '$WIN_USERNAME'..."
podman run -d "${RUN_ARGS[@]}" "$IMAGE" > /dev/null

echo "Container launched successfully."
echo "Access the web viewer at http://localhost:$WEB_PORT"
echo "The first-time installation takes 20-30 minutes, and needs no clicks."
echo "Shared files appear in Windows on drive Z:"
if [ "$OEM" = 1 ]; then
    echo "On a FRESH install, C:\\OEM\\install.bat runs by itself at the end of setup."
else
    echo "--no-oem: nothing runs by itself. Run Z:\\setup-dev.ps1 yourself when Windows is up."
fi
echo "Once sshd is running inside the VM: ssh -p $SSH_PORT $WIN_USERNAME@127.0.0.1"
