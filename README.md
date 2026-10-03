# Virtual machines

Two desktop VMs that run as Podman containers (dockur/windows and dockur/macos).
Each has its own folder, launcher and README.

| | Windows 11 | macOS 15 |
|---|---|---|
| folder | [`win11/`](win11/README.md) | [`macos15/`](macos15/README.md) |
| image | `docker.io/dockurr/windows` | `docker.io/dockurr/macos` |
| container | `windows11` | `macos15` |
| launch | `win11/launch-windows.sh` | `macos15/launch-macos.sh` |
| resources | 8 CPUs, 16 GB RAM, 128 GB disk | 8 CPUs, 16 GB RAM, 100 GB disk |
| web viewer | http://localhost:8006 | http://localhost:8007 |
| other ports | RDP 3389, ssh 2222 | VNC 5900, ssh 2223 |
| shared folder | `win11/shared` (drive `Z:`) | `macos15/shared` (`/Volumes/shared`) |
| after install | `Z:\setup-dev.ps1` (or runs by itself on a fresh install) | `bash /Volumes/shared/setup-macos.sh` |
| packages | winget | Homebrew (casks) and MacPorts (tools) on Intel; Homebrew only on Apple silicon |

The ports differ on purpose, so both VMs can run at once. Both need `/dev/kvm`.
Together they use 32 GB of RAM when both are at full size.

How the two differ:

- **Windows** runs `install.bat` by itself at the end of a fresh unattended install
  (dockur's `/oem` hook), and installs itself. The shared folder is mounted for you.
- **macOS** cannot be installed by the container. You install it by hand in the web
  viewer, mount the shared folder with `sudo -S mount_9p shared`, and run the script.
  Xcode is downloaded by hand from https://developer.apple.com/download/all/. Take
  **Xcode 26.3**, which is the newest that runs on macOS 15. Xcode 26.4 and newer need
  macOS 26, and Xcode 27 runs on Apple silicon only.
- On an AMD host, the macOS VM gets 8 GB during its first install, and moves to
  16 GB with `./launch-macos.sh --recreate`.
- The macOS setup script works on Apple silicon too, for example a Tart VM. There it
  uses Homebrew alone. On Intel (this dockur VM) Homebrew has no bottles and no
  installer, so it uses MacPorts for the command line tools. See `macos15/README.md`.

The macOS VM has snapshots too: `macos15/snapshot-macos.sh create|restore|list|delete`. They use
btrfs reflinks, so a snapshot of the installed VM takes a moment and costs almost no space, which
makes it cheap to test the setup script again from a fresh install.

Both launchers keep the VM disk in a `*-data/` folder, so `--recreate` (macOS) or
`podman rm -f <name>` (Windows) followed by the launcher does not lose the disk.
