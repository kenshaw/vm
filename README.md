# Virtual machines

Two desktop VMs that run as Podman containers (dockur/windows and dockur/macos), as your own
user, in rootless Podman. Each has its own folder, launcher and README.

| | Windows 11 | macOS 15 |
|---|---|---|
| folder | [`win11/`](win11/README.md) | [`macos15/`](macos15/README.md) |
| image | `docker.io/dockurr/windows` | `docker.io/dockurr/macos` |
| container and service | `windows11` | `macos15` |
| launch | `win11/launch-windows.sh` | `macos15/launch-macos.sh` |
| snapshots | `win11/snapshot-windows.sh` | `macos15/snapshot-macos.sh` |
| resources | 8 CPUs, 16 GB RAM, 128 GB disk | 8 CPUs, 16 GB RAM, 100 GB disk |
| web viewer | http://localhost:8006 | http://localhost:8007 |
| other ports | RDP 3389, ssh 2222 | VNC 5900, ssh 2223 |
| account | `user` (password `admin` unless you set one) | `user`, which you create |
| shared folder | `win11/shared` (drive `Z:`) | `macos15/shared` (`/Volumes/shared`) |
| install | **by itself**, no clicks | **by hand** in the web viewer |
| after install | runs by itself (`setup-dev.ps1`) | `bash /Volumes/shared/setup-macos.sh` |
| packages | winget | Homebrew (casks) and MacPorts (tools) on Intel; Homebrew only on Apple silicon |

The ports differ on purpose, so both VMs can run at once. Both need `/dev/kvm`. Together they use
32 GB of RAM when both are at full size.

## How the two differ

- **Windows** installs itself. dockur copies `shared/` to `C:\OEM` and runs `install.bat` at the end
  of a fresh install, which runs the setup script. The account is made by that install: it is
  `user` (set with `WIN_USERNAME`), with the image's default password `admin` (`WIN_PASSWORD`). An
  already installed Windows keeps the account it has.
- **macOS** cannot be installed by the container. You install it by hand in the web viewer, mount
  the shared folder with `sudo -S mount_9p shared`, and run the script. Xcode is downloaded by hand
  from https://developer.apple.com/download/all/. Take **Xcode 26.3**, which is the newest that runs
  on macOS 15: Xcode 26.4 and newer need macOS 26, and Xcode 27 runs on Apple silicon only.
- On an AMD host, the macOS VM gets 8 GB during its first install, and moves to 16 GB with
  `./launch-macos.sh --recreate`.
- The macOS setup script works on Apple silicon too, for example a Tart VM. There it uses Homebrew
  alone. On Intel (this dockur VM) Homebrew has no bottles and no installer, so it uses MacPorts for
  the command line tools. See `macos15/README.md`.

## Run at boot: `install.sh`

```
./install.sh macos15            # or win11, or both: ./install.sh macos15 win11
./install.sh macos15 --start    # and start it now
./install.sh macos15 --dry-run  # show the unit, change nothing
./install.sh macos15 --uninstall
```

This turns each VM into a **systemd user service** (`macos15.service`, `windows11.service`) that
starts when the computer starts, whether or not anyone is logged in, and runs as you.

- The services are **Podman Quadlet** units. `systemd/*.container.in` are the templates. `install.sh`
  fills them in, checks the result with Podman's own Quadlet generator (a dry run that changes
  nothing), and installs them in `~/.config/containers/systemd/`. Quadlet turns each into a service.
- They have the same settings as the launchers: same ports, devices, volumes and 120 second stop
  time, so the service asks the guest to shut down and waits up to two minutes before it cuts power. Windows normally shuts down when asked; macOS here did not.
- It turns on **lingering** (`loginctl enable-linger`), which is what lets a user's services start at
  boot. If your system does not let a user do that, it tells you to run `sudo loginctl enable-linger
  $USER`.
- A container that a launcher made has the same name and uses the same VM disk. `install.sh` offers
  to remove it (it is stopped first; the disk is kept), so only one of them runs.
- The service restarts only if the VM crashes. If you shut the guest down from inside, it stays
  off. Stopping the service asks the guest to shut down and takes up to 2.5 minutes.
- Settings (`RAM_SIZE`, `CPU_CORES`, `DISK_SIZE`, `VERSION`, ports, `DISK_FMT`, `WIN_USERNAME`,
  `WIN_PASSWORD`) come from the environment, for one VM at a time: `RAM_SIZE=12G ./install.sh macos15`.
  Run it again to change them, then `systemctl --user restart macos15.service`.
- On an AMD host, a macOS that is not installed yet gets 8 GB, the same rule as the launcher. Run
  `./install.sh macos15` again after the install to move to 16 GB.
- A `WIN_PASSWORD` is written into the unit file, which is then readable only by you. `%` and `$` in
  it are escaped for systemd, so it reaches the container as typed.

From then on, use systemd to run them, not the launchers:

```
systemctl --user start macos15.service
systemctl --user stop macos15.service       # asks the guest to shut down, up to 2.5 minutes
systemctl --user status macos15.service
journalctl --user -u macos15.service -f
```

`snapshot-macos.sh` and `snapshot-windows.sh` see the service and stop and start the VM through it.

`--uninstall` stops the service and removes the unit. The VM disks are not touched, and lingering is
left on.

## Snapshots

`macos15/snapshot-macos.sh` and `win11/snapshot-windows.sh` (both run `snapshot-vm.sh`):

```
create <name> [--wait] [--start]    restore <name> [--yes] [--start]    list    delete <name>
```

A snapshot is a btrfs reflink copy of the VM's data folder, which takes a moment and costs almost no
space until the VM changes its disk, so it is cheap to start again from a fresh install. See
`macos15/README.md` for how it works, including the NOCOW detail that makes a plain copy slow.

## Git

The repository tracks the scripts, templates and docs. The VM disks (hundreds of GB) and the
snapshots are **not in the repository**: they are in a data folder, `~/.local/share/vm/` by default
(`$XDG_DATA_HOME/vm`, or the folder that `VM_DATA` names):

```
~/.local/share/vm/macos15/data/        the macOS disk, boot disk and machine identity
~/.local/share/vm/macos15/snapshots/   its snapshots
~/.local/share/vm/win11/data/          the Windows disk
~/.local/share/vm/win11/snapshots/     its snapshots
```

The launchers, `install.sh` and the snapshot tools all use it, so set `VM_DATA` the same way for
all of them (or `STORAGE_DIR` for one VM's disk). It must be on a btrfs file system for snapshots
to be instant, and all of one VM's folders must be on the same file system. `.gitignore` keeps out
the logs and Xcode (`*.xip`).
