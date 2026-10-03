# Windows 11 VM

Runs `docker.io/dockurr/windows` under rootless Podman with 8 CPUs, 16 GB of RAM and a
128 GB disk. Unlike the macOS VM, **Windows installs and sets itself up with no clicks.**

| file | purpose |
|---|---|
| `launch-windows.sh` | creates and starts the container |
| `shared/setup-dev.ps1` | the setup script. It runs by itself at the end of the install |
| `shared/install.bat` | the hook that dockur runs, which runs `setup-dev.ps1` |
| `snapshot-windows.sh` | saves and restores snapshots of the VM, to start again from a known state |
| `windows-data/` | the VM disk. It is kept between runs |
| `snapshots/` | the snapshots (created by `snapshot-windows.sh`) |

| what | host address |
|---|---|
| web viewer | http://localhost:8006 |
| remote desktop (RDP) | 127.0.0.1:3389 |
| ssh | 127.0.0.1:2222 |

The `macos15` VM uses 8007, 5900 and 2223, so both can run at once.

## Quick start

```
./launch-windows.sh
```

Then wait about 20 to 30 minutes and watch http://localhost:8006. Nothing needs clicking.
When the install ends, dockur runs the setup script by itself: it activates Windows, installs
all Windows updates, installs the tools with winget, turns on ssh and sets Firefox as the default
browser. Read how it is doing in `shared/setup-dev.log`, or `C:\OEM\setup-dev.log` in the VM.

To run it at boot as a service instead, see *Run at boot* below.

## The account

The install makes one Windows account, an administrator:

| | default | set with |
|---|---|---|
| name | `user` | `WIN_USERNAME` |
| password | `admin` (the image's own default) | `WIN_PASSWORD` |

ssh in with `ssh -p 2222 user@127.0.0.1` once the setup script has turned ssh on, using your
`id_ed25519` key.

**The account is made when Windows is installed.** Setting `WIN_USERNAME` or `WIN_PASSWORD`
later changes nothing for a Windows that is already installed, and the launcher says so. The
Windows VM that was installed before this change has the image's old default account, `Docker`.
To get `user`, wipe the VM and install again (see *Wipe and reinstall*). The setup script copes
with either name: it finds the one normal local account, or you can pass `-User <name>`.

The password sits in the clear in the container's environment, as the image requires. The VM is
only reachable from this computer (every port is bound to 127.0.0.1), but pick a password you
do not use elsewhere. The launcher never prints it.

## How the automation works

1. `launch-windows.sh` mounts `shared/` twice: as `/shared` (drive **Z:** in Windows) and as
   `/oem`.
2. At the end of a **fresh** install, dockur copies `/oem` to `C:\OEM` and runs `install.bat` as
   SYSTEM.
3. `install.bat` runs `setup-dev.ps1 -SkipWinget`. That does the machine-level work: activation,
   Windows Update, the ssh server and the browser. It skips winget, because winget is a per-user
   package and does not exist for SYSTEM.
4. `install.bat` then queues the winget half in `RunOnce`, so it runs at the first logon.

dockur runs `install.bat` only for a fresh install. It does not run it again on a later start.

## What the setup script does

The order is fixed, and activation is always first and cannot be skipped.

| phase | what it does |
|---|---|
| 1 | **Windows activation**: the procedure from `notes/windows-activate.md`. It leaves a machine that is already licensed alone. |
| 2 | **Windows Update**: opts into Microsoft Update, then searches, downloads and installs everything, up to `-UpdatePasses` rounds, stopping when a reboot is needed |
| 3 | **winget**: pwsh, windows terminal, neovim, git, gh, rustup, node lts, python, vc++ redist, 7zip, jq, vault, gcloud sdk, claude desktop, claude code, firefox |
| 4 | **OpenSSH server**: capability, sshd and ssh-agent automatic, firewall port 22, `DefaultShell`, and your key in `administrators_authorized_keys` (and in the profile of `user`, once it exists) |
| 5 | **Firefox as the default browser**, through a policy file, which applies at the next sign-in |

Options (for a run by hand, as `powershell -ExecutionPolicy Bypass -File Z:\setup-dev.ps1 ...`):

```
-User <name>       the Windows account (default: the one normal local account, else "user")
-PublicKey '...'   authorize a different key (default: ken@ken-desktop)
-DefaultShell bash sshd hands sessions to Git bash instead of pwsh
-RebootIfNeeded    reboot when Windows Update asks for it
-UpdatePasses <n>  update rounds to run (default 3)
-KmsHost <host>    KMS host for activation (default kms8.msguides.com)
-BuildTools        also install the VS 2022 C++ build tools (about 5 GB)
-SkipUpdates -SkipWinget -SkipSsh -SkipBrowser
```

Nothing aborts the run: a failure is recorded and listed at the end. winget ids drift, so if one
fails, find the new id with `winget search <name>`.

**A reboot may be needed.** Windows Update often asks for one. By default the script then stops
and says so, and the winget half runs at the next logon. If you want it to keep going by itself,
reboot the VM and run the script again from the shared drive (it skips what is done).

### The log

Everything the script prints is written to a transcript, `C:\OEM\setup-dev.log`, and copied to
the shared folder as `win11/shared/setup-dev.log` when the script ends or is about to reboot, if
the share can be reached then. Each run adds to the same log.

### Default browser

Windows 11 does not let a script write the per-user `UserChoice` hash. The script writes an
association file to `C:\ProgramData\setup-dev\default-associations.xml` and points the
`DefaultAssociationsConfiguration` policy at it. That applies at the **next sign-in**, and while it
is set the defaults cannot be changed by hand. To release them, delete the
`DefaultAssociationsConfiguration` value under `HKLM\SOFTWARE\Policies\Microsoft\Windows\System`.

## Starting over: snapshots

```
./snapshot-windows.sh create clean
./snapshot-windows.sh list
./snapshot-windows.sh restore clean --yes --start
./snapshot-windows.sh delete clean
```

It works exactly like the macOS one (`../macos15/README.md` explains it, and `../snapshot-vm.sh` is
the shared tool): a btrfs reflink copy of `windows-data/`, which takes a moment and uses almost no
space until the VM changes the disk. `create` asks Windows to shut down first (Windows normally does; `create` says if it had to cut power, and `create --wait` waits for you to shut down from inside). If the VM runs as a
systemd service, it is stopped and started through the service.

**To test the setup script again and again** you need a Windows that is installed but not set up,
and the automatic hook would set it up during the install. So install with `--no-oem`:

1. `./launch-windows.sh --no-oem`. Windows installs, and nothing runs by itself.
2. Take a snapshot: `./snapshot-windows.sh create installed`.
3. In Windows, run `powershell -ExecutionPolicy Bypass -File Z:\setup-dev.ps1`.
4. To try again: `./snapshot-windows.sh restore installed --yes --start`.

`--no-oem` only matters when the container is created.

### Wipe and reinstall

To throw the VM away and install again, for example to get a different account:

1. `podman rm --force windows11` (or `systemctl --user stop windows11.service`)
2. Delete the contents of `windows-data/`. Keep `shared/`.
3. `./launch-windows.sh`, with `WIN_USERNAME` and `WIN_PASSWORD` set if you want other values.

The VM has a new ssh host key after a reinstall, so run `ssh-keygen -R "[127.0.0.1]:2222"`.

## Run at boot (systemd)

`../install.sh win11` installs a systemd **user** service, `windows11.service`, with the same
settings as the launcher, and turns on lingering so it starts when the computer starts, with
nobody logged in. It runs as you, in rootless Podman. See `../README.md`. Use
`systemctl --user start|stop|status windows11.service` from then on, not the launcher.

The service takes `WIN_USERNAME` and `WIN_PASSWORD` too: `WIN_USERNAME=bill ../install.sh win11`.
They only matter for a fresh install.

## Status

The scripts for this VM were tested in pieces: the launcher and the service unit against Podman's
own tools, the snapshots in a sandbox, and the PowerShell for syntax and for the parts that run on
Linux. **The setup script has not yet run on a real Windows 11 VM**, so expect to fix small things
on the first run. Windows-specific behaviour (activation, Windows Update, winget, the OpenSSH
capability, the `RunOnce` hand-over) is exactly what that run will test.
