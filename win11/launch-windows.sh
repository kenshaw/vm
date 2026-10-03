#!/bin/bash

# launch-podman-windows.sh - Launches a Windows 11 container using Podman with a 128GB disk

set -e

CONTAINER_NAME="windows11"
STORAGE_DIR="$(pwd)/windows-data"
SHARED_DIR="$(pwd)/shared"

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

# 3. Create the storage directory if it doesn't exist
mkdir -p "$STORAGE_DIR" "$SHARED_DIR"
echo "Storage directory: $STORAGE_DIR"
echo "Shared directory:  $SHARED_DIR  (drive Z: inside Windows, and C:\\OEM on a fresh install)"

# 4. Check if the container already exists
if podman container exists "$CONTAINER_NAME"; then
    echo "Container '${CONTAINER_NAME}' already exists. Starting it instead..."
    podman start "$CONTAINER_NAME"
    echo "Container started. Access the web viewer at http://localhost:8006"
    exit 0
fi

# 5. Launch the new container
echo "Launching Windows 11 container with 128G disk using Podman..."
podman run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1:8006:8006 \
  -p 127.0.0.1:3389:3389/tcp \
  -p 127.0.0.1:3389:3389/udp \
  -p 127.0.0.1:2222:22/tcp \
  -e VERSION="11" \
  -e DISK_SIZE="128G" \
  -e RAM_SIZE="16G" \
  -e CPU_CORES="8" \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  --group-add keep-groups \
  -v "$STORAGE_DIR:/storage" \
  -v "$SHARED_DIR:/shared" \
  -v "$SHARED_DIR:/oem" \
  --stop-timeout 120 \
  --restart unless-stopped \
  docker.io/dockurr/windows

echo "Container launched successfully."
echo "Access the web viewer at http://localhost:8006"
echo "The first-time installation will take 20-30 minutes."
echo "Shared files appear in Windows on drive Z:"
echo "On a FRESH install, C:\\OEM\\install.bat runs automatically at the end of setup."
echo "Once sshd is running inside the VM: ssh -p 2222 <user>@127.0.0.1"
