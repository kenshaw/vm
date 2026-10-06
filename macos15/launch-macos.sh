#!/bin/bash

# launch-macos.sh - Launches a macOS 15 (Sequoia) container using Podman
# with 8 CPUs, 16GB of RAM and a 100GB disk.
#
# usage: launch-macos.sh [--recreate] [--dry-run]
#
#   --recreate  remove the container and create it again. The disk is kept.
#               Use it to change the RAM, CPUs, disk size or ports.
#   --dry-run   print the podman command and exit.
#
# RAM_SIZE, CPU_CORES, DISK_SIZE, VERSION, WEB_PORT, VNC_PORT and SSH_PORT can
# be set in the environment to override the values below. So can DISK_FMT, which is
# the format of the VM disk: raw (the image's default) or qcow2. It only matters
# before the install: changing it later does not convert an installed disk.
#
# QEMU_ARGUMENTS holds extra options for QEMU, which the image reads as ARGUMENTS. The
# default is "-machine i8042=off", which removes the virtual PS/2 keyboard. See "No PS/2
# keyboard" in README.md. Set it to an empty string to keep that keyboard. A change needs
# --recreate: a container keeps the hardware it was made with.

set -e

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="macos15"
IMAGE="docker.io/dockurr/macos:latest"
# the VM disk, the snapshots and the downloads (Xcode) are not in this repository: they
# are in $VM_DATA (default ~/.local/share/vm/). STORAGE_DIR overrides the folder of the
# disk, and DOWNLOADS_DIR the folder of the Xcode .xip. The VM sees DOWNLOADS_DIR as
# /Volumes/shared/downloads.
VM_DATA="${VM_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/vm}"
STORAGE_DIR="${STORAGE_DIR:-$VM_DATA/macos15/data}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$VM_DATA/downloads}"
SHARED_DIR="$HERE/shared"

VERSION="${VERSION:-15}"
DISK_SIZE="${DISK_SIZE:-100G}"
RAM_SIZE="${RAM_SIZE:-16G}"
CPU_CORES="${CPU_CORES:-8}"
DISK_FMT="${DISK_FMT:-}"
# Without "-" before the "-machine", an empty value could not turn this off.
QEMU_ARGUMENTS="${QEMU_ARGUMENTS--machine i8042=off}"

# the windows11 container holds 8006 and 2222, so these differ from the
# image defaults
WEB_PORT="${WEB_PORT:-8007}"
VNC_PORT="${VNC_PORT:-5900}"
SSH_PORT="${SSH_PORT:-2223}"

# dockur/macos documents that an AMD host must not exceed 8GB of RAM during
# the first install
INSTALL_RAM_SIZE="8G"

RECREATE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# 3. Check for AVX2 (macOS 12 and newer will not boot without it)
if ! grep -qw avx2 /proc/cpuinfo; then
    echo "Error: this CPU has no AVX2. macOS needs Intel Haswell or AMD Zen or newer."
    exit 1
fi

# 4. Use less RAM for the first install on an AMD host
# The VM's data disk is <data folder>/<version>/data.img (or data.qcow2), and it is
# created the first time the VM starts. So this is true only for the first launch.
# The script cannot tell an install that is still going from one that has finished, so
# run --recreate (which moves to the full RAM) only after macOS is installed.
if grep -q AuthenticAMD /proc/cpuinfo \
    && [ -z "$(find "$STORAGE_DIR" -type f -name 'data.*' 2>/dev/null | head -n 1)" ]; then
    echo "AMD CPU and no installed disk yet: using $INSTALL_RAM_SIZE of RAM for the install, not $RAM_SIZE."
    echo "After macOS is installed, run '$0 --recreate' to move to $RAM_SIZE."
    RAM_SIZE="$INSTALL_RAM_SIZE"
fi

RUN_ARGS=(
    --name "$CONTAINER_NAME"
    -p "127.0.0.1:$WEB_PORT:8006"
    -p "127.0.0.1:$VNC_PORT:5900/tcp"
    -p "127.0.0.1:$VNC_PORT:5900/udp"
    -p "127.0.0.1:$SSH_PORT:22/tcp"
    -e VERSION="$VERSION"
    -e DISK_SIZE="$DISK_SIZE"
    -e RAM_SIZE="$RAM_SIZE"
    -e CPU_CORES="$CPU_CORES"
    --device=/dev/kvm
    --device=/dev/net/tun
    --cap-add NET_ADMIN
    --group-add keep-groups
    -v "$STORAGE_DIR:/storage"
    -v "$DOWNLOADS_DIR:/shared/downloads:ro"
    -v "$SHARED_DIR:/shared"
    --stop-timeout 120
    --restart on-failure
)
if [ -n "$DISK_FMT" ]; then
    RUN_ARGS+=(-e DISK_FMT="$DISK_FMT")
fi
if [ -n "$QEMU_ARGUMENTS" ]; then
    RUN_ARGS+=(-e ARGUMENTS="$QEMU_ARGUMENTS")
fi

if [ "$DRY_RUN" = 1 ]; then
    printf 'podman run -d'
    printf ' %q' "${RUN_ARGS[@]}" "$IMAGE"
    echo
    exit 0
fi

# 5. Create the storage and shared directories if they don't exist
mkdir -p "$STORAGE_DIR" "$SHARED_DIR" "$DOWNLOADS_DIR"
echo "Storage directory: $STORAGE_DIR"
echo "Shared directory:  $SHARED_DIR  (run 'sudo -S mount_9p shared' in macOS)"

# 6. Check if the container already exists
if podman container exists "$CONTAINER_NAME"; then
    if [ "$RECREATE" = 1 ]; then
        echo "Removing container '${CONTAINER_NAME}' (the disk in $STORAGE_DIR is kept)..."
        podman rm --force --time 120 "$CONTAINER_NAME" > /dev/null
    else
        have_ram="$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" | sed -n 's/^RAM_SIZE=//p')"
        echo "Container '${CONTAINER_NAME}' already exists. Starting it instead..."
        podman start "$CONTAINER_NAME" > /dev/null
        echo "Container started. Access the web viewer at http://localhost:$WEB_PORT"
        if [ -n "$have_ram" ] && [ "$have_ram" != "$RAM_SIZE" ]; then
            echo "Note: the container has RAM_SIZE=$have_ram but $RAM_SIZE is wanted."
            echo "Once the macOS install has finished, run '$0 --recreate'."
        fi
        exit 0
    fi
fi

# 7. Launch the new container
echo "Launching macOS $VERSION container: $CPU_CORES CPUs, $RAM_SIZE RAM, $DISK_SIZE disk..."
podman run -d "${RUN_ARGS[@]}" "$IMAGE" > /dev/null

echo "Container launched successfully."
echo "Access the web viewer at http://localhost:$WEB_PORT"
echo "VNC is on 127.0.0.1:$VNC_PORT. Once Remote Login is on in macOS: ssh -p $SSH_PORT <user>@127.0.0.1"
echo "The first launch downloads the recovery image, then you install macOS by hand."
echo "See README.md for the steps."
