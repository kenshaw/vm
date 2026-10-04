# macOS 15 (Sequoia) VM

Runs `docker.io/dockurr/macos` under Podman with 8 CPUs, 16 GB of RAM and a 100 GB
disk. You install macOS by hand in the web viewer. Then one script sets up the rest.

| file | purpose |
|---|---|
| `launch-macos.sh` | creates and starts the container |
| `shared/setup-macos.sh` | sets up macOS after you install it |
| `snapshot-macos.sh` | saves and restores snapshots of the VM, to start again from a known state. It runs `../snapshot-vm.sh`, which the Windows VM uses too |
| `snapshots/` | the snapshots (created by `snapshot-macos.sh`) |
| `logs/` | logs kept for reference, such as the first VM run |
| `shared/Xcode_*.xip` | **you add this**: the Xcode download (see step 3) |
| `macos-data/` | the VM disk and the recovery image. It is kept between runs |
| `shared/` | a folder shared with the VM |

| what | host address |
|---|---|
| web viewer | http://localhost:8007 |
| VNC | 127.0.0.1:5900 |
| ssh | 127.0.0.1:2223 |

The `windows11` container uses 8006, 3389 and 2222, so this VM uses different ports. The VM runs
as you, in rootless Podman. To start it at boot as a systemd service, see *Run at boot* below.

## Quick start

1. `./launch-macos.sh`, then open http://localhost:8007.
2. Install macOS in the web viewer (step 2).
3. On your own machine, download **Xcode 26.3** (not the newest: 26.4 and newer
   need macOS 26) from https://developer.apple.com/download/all/ and put the
   `Xcode_*.xip` file in `macos15/shared/` (step 3).
4. In the VM, in Terminal:
   ```
   sudo -S mount_9p shared
   bash /Volumes/shared/setup-macos.sh
   ```
5. Log out and in. Then `./launch-macos.sh --recreate` to move from 8 GB to 16 GB.

To test the setup script again and again, take a snapshot right after the install, before
you run the script: `./snapshot-macos.sh create fresh-install`. See *Starting over*.

## 1. Start the VM

```
./launch-macos.sh
```

**RAM during the install.** dockur/macos says an AMD host must not give the VM more
than 8 GB during the first install. This host is a Ryzen, so the first launch uses
8 GB and says so. After macOS is installed, move to 16 GB. The disk is kept:

```
./launch-macos.sh --recreate
```

The first launch downloads the macOS recovery image (about 1 GB) before anything
shows in the web viewer.

Options: `--dry-run` prints the podman command. These variables in the environment
change the settings: `RAM_SIZE`, `CPU_CORES`, `DISK_SIZE`, `VERSION`, `WEB_PORT`,
`VNC_PORT` and `SSH_PORT`. The launcher needs `/dev/kvm` and a CPU with AVX2, and
checks for both.

## 2. Install macOS by hand

dockur/macos cannot install macOS for you. In the web viewer:

1. Wait for the recovery image to download and start.
2. Open **Disk Utility**. Erase the largest *Apple Inc. VirtIO Block Media* disk as
   **APFS**.
3. Choose **Reinstall macOS**. The install takes a long time (about 2 hours here).
4. Set the region, language and keyboard.
5. Skip Migration Assistant and the Apple ID.
6. Create your user account. It is an administrator account, and the setup script
   needs that.

## 3. Get Xcode

Full Xcode is not in Homebrew, and Apple asks you to sign in to download it. So you
download it by hand, and the script installs it from the shared folder.

1. Open https://developer.apple.com/download/all/ and sign in with your Apple ID.
2. Search for **Xcode** and download the `.xip` file.
3. Put the file in `macos15/shared/` on the host. Leave the name as Apple made it
   (`Xcode_<version>.xip`).

**Which version: Xcode 26.3.** The newest Xcode is not the right one for this VM. It is an
Intel Mac that runs macOS 15, and each Xcode needs a macOS that is new enough:

| Xcode | needs | runs here? |
|---|---|---|
| 16.4 | macOS 15.3 | yes |
| 26.0 to **26.3** | macOS 15.6 | **yes. 26.3 is the newest that does** |
| 26.4 to 26.6 | macOS 26.2 | no, the VM has macOS 15 |
| 27 and newer | macOS 26.4, Apple silicon only | no. Apple's release notes say "Xcode 27 will only install and run on Apple silicon Macs", and macOS 27 does not run on Intel Macs |

So download **Xcode 26.3** (Universal). It is below the newest releases on the download
page: use the search box, or the list of older releases. Check the VM first with
`sw_vers -productVersion`. Xcode 26.3 needs macOS 15.6 or later. If the VM has an
older 15.x, use Xcode 16.4, or update macOS by hand.

- If the page offers a universal download and an Apple silicon download, take the
  universal one.
- The script protects you from a wrong choice. It reads the version out of the file
  name and passes over any file that cannot run here, and says why. If that leaves no
  file, it stops at once and asks for Xcode 26.3. After the expand, it checks again
  with what the app itself says it needs (`LSMinimumSystemVersion`, and the kinds of
  Mac it has code for).
- If there is more than one `.xip` in the folder, the script uses the newest one that
  can run here.

Phase 4 installs Xcode, before Homebrew, so the `.xip` must already be in the folder
when you run the script.

## 4. Run the setup script

Log in. In Terminal:

```
sudo -S mount_9p shared
```

This command is needed in a fresh VM: nothing mounts the share for you. It asks for
your password. The folder then appears at `/Volumes/shared`, and in Finder under
**Go > Computer**. Run the script from there:

```
bash /Volumes/shared/setup-macos.sh
```

It asks for your password once, and does not need to be run with `sudo`. It takes a
long time. If a step fails, the script goes on and lists the failures at the end. Run
it again at any time: it skips what is already done. It exits with a nonzero status if
anything failed.

**The log.** Everything the script prints is also written to `~/setup-macos.log` in the
VM. Each run adds to the end of the log. The shared folder is owned by root in the VM, so
your user cannot write a copy there, and the log does not appear on the host by itself. To
read it from the host while the script runs:

```
ssh -p 2223 user@127.0.0.1 'cat ~/setup-macos.log'
```

To put a copy in the shared folder, run `sudo cp ~/setup-macos.log /Volumes/shared/` in the VM.

| phase | what it does |
|---|---|
| 1 | asks for your password **once** and keeps sudo alive (below) |
| 2 | **VM tuning** (below), including automatic login as you |
| 3 | Xcode Command Line Tools |
| 4 | **Xcode**, from the `.xip` in the shared folder (below) |
| 5 | **Homebrew**: the official installer on Apple silicon, set up by hand on Intel (below) |
| 6 | **command line tools**: the list from `notes/macos.md`, plus what the darwin part of `.bashrc` expects, plus git, gh, jq, node, python and rustup. With Homebrew, or with MacPorts on Intel (below). Then it makes the bash it installed your **login shell** and writes a plain **`~/.bashrc`** for it (below) |
| 7 | casks: iterm2, google-chrome, firefox and desktoppr. Then it clears the quarantine flag on the apps, makes **Firefox the default browser** and turns off the **first-run screens** of Firefox and Chrome's welcome screen (below) |
| 8 | **default wallpaper** (below) |
| 9 | **Dock**: System Settings, Firefox, Chrome, iTerm and the App Store, plus Applications and Downloads folders shown as a grid |
| 10 | Remote Login (ssh) on, and the `id_ed25519` key authorized |
| 11 | **Go**, from `go-setup.sh` in `kenshaw/shell-config`, run last (below) |

### Options

```
--packages=auto|homebrew|hybrid
--skip-tuning  --skip-formulae  --skip-casks  --skip-wallpaper
--skip-dock    --skip-ssh       --skip-xcode    --skip-shell    --skip-bashrc
--skip-go      --update-go     --skip-autologin   --skip-keyboard
--skip-browsers  --no-shutdown
```

When **every step succeeded**, the VM **shuts down by itself** 15 seconds after the summary.
Ctrl-C in those 15 seconds cancels it. It does not shut down when a step failed, so you can read the
summary. Start the VM again from the host: `podman start macos15`, or
`systemctl --user start macos15.service` with the systemd unit. That start is the restart that the
key repeat, the scroll direction and reduce motion need, and automatic login is tried then.
`--no-shutdown` (the old name `--no-reboot` works too) never shuts down, and
`SHUTDOWN_DELAY=<seconds>` changes the wait.

**Why a shutdown and not a restart:** twice (at the end of the macOS install, and after this
script) a restart from inside the guest hung this VM: all 8 CPUs busy, a frozen screen, no ssh,
until the container was restarted from the host. A shutdown has worked every time. The script runs
`sudo shutdown -h now`; if that halts the guest without powering off the VM (the container stays
up with no CPU use), stop it with `podman stop macos15`, and `SHUTDOWN_COMMAND` in the environment
replaces the command. Not yet seen end to end: this exact command has not run in the VM.

`--update-go` runs `go-setup.sh` again when Go is already installed. Without it, an existing
Go is left alone.

`--skip-formulae` skips the command line tools in either package mode.

| variable | effect |
|---|---|
| `PACKAGES` | the same as `--packages` |
| `KEY_REPEAT`, `INITIAL_KEY_REPEAT` | how often a held key repeats (default 2) and how long it waits first (default 15), in units of 15 ms |
| `KEYBOARD_TYPE` | `ansi` (the default), `iso` or `jis`: the keyboard layout to save (see Keyboard layout) |
| `AUTOLOGIN_USER` | the account that logs in by itself, in place of the one that runs the script |
| `DEFAULT_SHELL` | the bash to make the login shell, in place of the one Homebrew or MacPorts installed |
| `GO_SETUP_SCRIPT` | a `go-setup.sh` to run, in place of the downloaded one |
| `GO_SETUP_URL` | where to download `go-setup.sh` (default: `scripts/go-setup.sh` in `github.com/kenshaw/shell-config`) |
| `PUBLIC_KEY` | the ssh key to authorize, in place of `id_ed25519` |
| `WALLPAPER_FILE` | a PNG, JPEG or HEIC to use as the wallpaper |
| `XCODE_SOURCE` | the `.xip` (or an `Xcode.app`) to install, in place of the one it finds |
| `APPLICATIONS_DIR` | where apps live (default `/Applications`) |

`bash setup-macos.sh --help` prints the same list.

## Starting over: snapshots

To test the setup script more than once, start each test from the same fresh install. The
install takes about two hours; a snapshot takes a moment.

```
./snapshot-macos.sh create fresh-install     # after macOS is installed and you have logged in
./snapshot-macos.sh list
./snapshot-macos.sh restore fresh-install --start
./snapshot-macos.sh delete fresh-install
```

**When to take it.** After the install is finished and you have logged in, but **before** you
run `setup-macos.sh`. Without options, `create` asks the VM to shut down and waits up to two
minutes; **macOS in this setup ignores that request**, so the VM is powered off, like a power cut.
APFS recovers from that and the snapshot almost certainly works, but it is not clean. The tool says
`forced` when it happens, and `list` shows it in the SHUTDOWN column.

For a snapshot that is certain to be clean, use `--wait`:

```bash
./snapshot-macos.sh create fresh-install --wait --start
```

It does not stop the VM. It waits (10 minutes, or `WAIT_TIMEOUT=<seconds>`) while **you shut macOS
down from inside: Apple menu > Shut Down**. As soon as the VM has stopped, it makes the snapshot,
and `--start` starts the VM again. (The container restarts only after a crash, so a shutdown
from inside stays off. If an older container still has `--restart unless-stopped`, the tool switches
that off while it waits and puts it back afterwards, also after Ctrl-C. Change it for good with
`podman update --restart=on-failure macos15`.) If the VM is already stopped, `create` copies at once. `restore` removes the
container, puts the snapshot back and, with `--start`, launches the VM. It asks first, because everything the VM has
done since the snapshot is lost. `--yes` skips the question.

**How it works.** A snapshot is a copy of `macos-data/`: the disk, the OpenCore boot disk, the
recovery image and the machine identity. On btrfs (this host) the copy is a *reflink*: it takes
a moment and uses no extra space until the VM changes the disk, and then only for the changed
blocks. So you can keep several snapshots. On another file system it makes a full copy, about
30 GB for an installed macOS.

**The NOCOW detail.** On btrfs the container gives the VM disk (`data.img`) the NOCOW attribute,
`C`, for speed. btrfs only clones between two files that are both NOCOW or both not, so a plain
`cp --reflink` of that file fails with "Invalid argument" and falls back to a full 30 GB copy.
The script copies file by file and gives each new file the same attribute as its source,
before it clones. Measured on this host with a NOCOW test disk: a snapshot and a restore each
took about 0.1 seconds, all the data was shared at first, and after the "VM" wrote 20 MB only
those 20 MB were separate. The snapshot stayed identical to the disk as it was. After a restore, the launcher gives the VM the full 16 GB, because
the data disk already exists.

**Why not `qemu-img`?** `qemu-img` can snapshot, but only a **qcow2** disk, and it does not do
it by itself: you run `qemu-img snapshot -c <name> <disk>` with the VM stopped, and `-a <name>`
to go back. This VM's disk is a **raw** file (`data.img`), and a raw file cannot hold snapshots.
The image can use qcow2 if you ask for it: its startup script (`/run/disk.sh`) reads a `DISK_FMT`
setting, "raw" (the default) or "qcow2". That only works before the install, because an
installed raw disk is not converted. These are the trade-offs:

| | reflink copy (what `snapshot-macos.sh` does) | qcow2 and `qemu-img snapshot` |
|---|---|---|
| disk format | raw, the default, so nothing to change | must be qcow2 **before** the install |
| speed | instant on btrfs | instant, but qcow2 is a little slower to run |
| the NVRAM and boot disk | included, so a restore is consistent | **not** included: they are separate files, and a restored disk with a newer NVRAM can boot differently, so you would copy them too |
| the machine identity | included | not included |
| works on other file systems | yes, as a full copy | yes |
| several snapshots | one folder each | all inside one file |

If you want qcow2 anyway, start the VM with `DISK_FMT=qcow2 ./launch-macos.sh` for the first
launch. `snapshot-macos.sh` still works with it, because it copies the whole of `macos-data/`.

### Run at boot (systemd)

`../install.sh macos15` makes a systemd **user** service, `macos15.service`, with the same settings
as the launcher, and turns on lingering so the VM starts when the computer starts, with nobody
logged in. `../README.md` explains how it works. Run it **after** macOS is installed, so that the
service gets the full 16 GB (an AMD host gets 8 GB until a data disk exists).

- From then on use `systemctl --user start|stop|status macos15.service`, not the launcher. Stopping
  asks macOS to shut down and takes up to 2.5 minutes (macOS may ignore the request, and then power is cut). Do not run both: they use the same disk.
- `install.sh` offers to remove the container the launcher made, and keeps the disk.
- If you shut macOS down from inside, the service does not restart it. A crash does restart it.
- `snapshot-macos.sh` sees the service, and stops and starts the VM through it.
- To change RAM or CPUs: `RAM_SIZE=12G ../install.sh macos15`, then restart the service.

### Wipe and reinstall

To throw the VM away and install again, with no snapshot:

1. `podman rm --force macos15`
2. Delete the contents of `macos-data/`. Keep `shared/`, which holds the script and the Xcode `.xip`.
3. `./launch-macos.sh`. It gives the install 8 GB again, because there is no data disk.
4. Install macOS by hand (steps above).

Run `./launch-macos.sh --recreate` only after the install is finished: the launcher cannot tell an
install that is still going from one that is done, and an AMD host must not give the install
more than 8 GB.

After a reinstall the VM has a new ssh host key, so remove the old one on the host:
`ssh-keygen -R "[127.0.0.1]:2223"`.

## What each part does

### Package managers: Homebrew, or MacPorts on Intel (phases 5 and 6)

The script picks how to install the command line tools from the kind of Mac. You can
override it with `--packages=` (or `PACKAGES`).

| mode | default on | Homebrew is used for | the command line tools come from |
|---|---|---|---|
| `homebrew` | Apple silicon (a Tart VM, or a real Mac) | everything | Homebrew formulae |
| `hybrid` | Intel (this dockur VM) | the casks only | MacPorts |

**Why Intel is different.** Homebrew 7.0 (13 September 2026) moved Intel Macs to Tier 3:

- Its installer refuses an Intel Mac: "Homebrew on macOS is only supported on Apple
  Silicon processors!". The installer has no switch to allow one. I read the whole
  script: its only options are `--path` and `--help`.
- It no longer builds bottles (ready-made binaries) for Intel. For macOS 15, 40 of
  the 42 formulae in this script's list have no Intel bottle, so they compile from
  source with all their dependencies. `neovim` alone builds 29 dependencies, including
  cmake and python. In an 8 CPU VM that takes hours.
- `brew` itself still runs on Intel until **2027-09-01**, and casks still work. I
  checked this on this VM: a hand-made Homebrew resolved Firefox, Chrome,
  gcloud and desktoppr.

So on Intel the script does this:

1. **Homebrew by hand (phase 5).** It does what the installer does for a standard
   install: it creates the folders in `/usr/local` (owned by you), clones
   `Homebrew/brew` on its latest release, and links `brew` into `/usr/local/bin`.
2. **MacPorts for the tools (phase 6).** It installs MacPorts from the official
   signed installer for your macOS, and installs the tools as ports. It uses
   binary-only mode (`port -b`), so a port with no ready-made binary fails at once and
   does not start a long build. Every port in the list has a macOS 15 Intel binary.
3. **Homebrew for the casks (phase 7)**, as on any Mac.

With MacPorts, the GNU tools have a `g` prefix in `/opt/local/bin` (`gls`, `gsed`). For
the plain names, put `/opt/local/libexec/gnubin` first on your PATH. These Homebrew
tools are left out in hybrid mode: `gnu-getopt` (no port), `git` (Apple's comes with
Xcode), `gh` and `iproute2mac` (no binary) and `bash-completion` (your `.bashrc` looks
for the Homebrew copy).

**Missing binaries in MacPorts, too.** MacPorts' Intel build for macOS 15 has gaps. When this
script was first run, `openssl3` and `bzip2` had no macOS 15 Intel binary at all, and
`tree-sitter` had only an older one than the ports tree wanted. Every port that needs one
of them fails in binary-only mode with `Failed to archivefetch <name>`. That took down 7
of the ports (`bat`, `grep`, `wget`, `neovim`, `python313`, `rustup`, and the PostgreSQL one that has since been removed),
even though each of them has its own binary. So the script now heals this: when a port
fails for that reason, it builds **only that one dependency** from source, and tries the
port again. These three build in a few minutes. A dependency that matches the slow list
(compilers, Rust, Go, Node, Java, Qt, and the like) is not built: the port fails
with a message that names it.

**Python is the exception.** `wget` needs `glib2`, which needs `python314`, and the explicit
`python313` is on the list too. MacPorts has no ready-made binary of either for macOS 15 Intel
(the first run failed on both). A build with the default `+lto +optimizations` variants takes most
of an hour, so the script builds them with `-lto -optimizations`, which takes a few minutes and runs
a little slower. The build is only tried when the binary is missing.

**Some settings cannot be written from a script.** macOS 15 refuses a write to
`com.apple.universalaccess` (Reduce motion, Reduce transparency) unless Terminal has Full Disk
Access, so the script no longer tries, and the summary tells you to switch them on in System
Settings > Accessibility > Display. `tmutil disable` also needs Full Disk Access; a new VM has no
backup disk, so the script skips it when `tmutil destinationinfo` says "No destinations configured".

**Casks that depend on a formula build it from source on Intel.** The casks in this
script (iTerm2, Chrome, Firefox, desktoppr) are plain downloads. `gcloud-cli` was removed for
this reason: its cask depends on the `python@3.14` formula, and with no bottles Homebrew
compiled Python and everything it needs (`openssl@3`, `sqlite`, `readline`, `xz`, `zstd`,
`lz4`, `cmake`, `pkgconf`) from source, which took tens of minutes. Check a cask with
`brew deps --cask <name>` before you add it on an Intel Mac.

You can force `--packages=homebrew` on an Intel Mac. It sets Homebrew up by hand and
installs every formula, and warns that this builds from source for hours.

**Tart and other Apple silicon VMs.** On Apple silicon, `auto` chooses `homebrew`: the
official installer and ordinary Homebrew formulae, which have bottles. Nothing else in
the script depends on the VM type, and the VM tuning and the white-background fix are
harmless on a Tart VM. The script has not been run on a Tart VM yet. Run it from the
folder that holds the Xcode `.xip`, and use an Xcode that your macOS can run (the script
checks). Xcode 27 is fine on Apple silicon if the macOS is 26.4 or later.

### The login shell (end of phase 6)

macOS uses zsh. The script makes the **modern bash that it just installed** your login
shell:

| mode | the bash |
|---|---|
| `homebrew` | `<brew prefix>/bin/bash` (`/opt/homebrew/bin/bash` on Apple silicon) |
| `hybrid` | `/opt/local/bin/bash` (MacPorts) |

- It checks that the bash runs and is version 4 or newer. Apple's own bash is 3.2, so
  that one is never chosen. If the check fails, the login shell is left as it was.
- It adds the bash to `/etc/shells`, which ssh and login need.
- It sets the shell with `sudo dscl . -create /Users/<you> UserShell <bash>`, not
  `chsh`, because `chsh` asks for your password and the script runs without a prompt.
- It does nothing if the login shell is already that bash, so a re-run is safe.
- `--skip-shell` leaves the shell alone, and `DEFAULT_SHELL=/path/to/bash` picks a
  different one.

It applies to **new** Terminal windows and ssh logins. The window you ran the script in
stays on zsh.

If the shell breaks, for example the bash is removed, a new Terminal window or an ssh
login can fail. From a window that still works, or from an admin account, run
`sudo dscl . -create /Users/<you> UserShell /bin/zsh`.

### The bash config (end of phase 6)

The script writes a plain `~/.bash_profile` and `~/.bashrc` for the user who runs it. They
are generic, so anyone can use them: nothing in them is personal.

- **`~/.bash_profile`** only hands over to `~/.bashrc`. Terminal and ssh start *login*
  shells, which read `~/.bash_profile` and not `~/.bashrc`.
- **`~/.bashrc`** sets the **PATH** first, for every bash, so `ssh vm some-command` finds
  the tools too. It looks for Homebrew (`/opt/homebrew` or `/usr/local`) and MacPorts
  (`/opt/local`) each time a shell starts, so one file is right for either mode. It puts the
  **GNU tools under their plain names** (`ls`, `sed`, `tar`, `grep`, ...) ahead of the BSD ones
  from macOS. Delete that part to get the macOS tools back.
- For **interactive** shells it also sets: history (no duplicates, shared between shells),
  `nvim` as the editor when it is installed (otherwise `vim`), color for `ls` and `grep`,
  the `ll` and `la` aliases, Homebrew's bash completion when it is installed, and a
  `user@host:directory$` prompt.
- It does not add its folders again when you start a shell inside a shell, or source the
  file twice.
- It works with bash 3.2 as well as a modern bash.

**Your own settings go in `~/.bashrc.local`.** `~/.bashrc` reads it at the end, and the
script never touches it. Anything you edit in `~/.bashrc` itself can be replaced when you
run the script again.

**When the script will not write a file.** It writes `~/.bash_profile` and `~/.bashrc` only
when the file does not exist, or when the file is one that it wrote (it has the line
`MANAGED-BY-SETUP-MACOS`). Then a re-run updates it if the text changed. If you already
have your own file, it is left as it is, and the script's version is written next to it as
`<file>.setup-macos`, so you can copy from it. To take over a file, delete that
`MANAGED-BY-SETUP-MACOS` line.

This replaces the earlier behaviour of leaving the shell config alone. If you keep your own
config in a repository, use a separate user account for it, or run with `--skip-bashrc`.

### VM tuning (phase 2)

It runs second, so the VM does not sleep or lock during the long installs.

- **Sleep, hibernation, display sleep, screen saver and screen lock** are off. A
  sleeping VM does not wake over VNC.
- **Animations, transparency and motion** are off. The VM has no GPU. The window
  and Dock settings from `notes/macos/osx-disable-animations.sh` still work on
  macOS 15, so they stay. The Mail ones are gone, because there is no Mail account.
- **Natural scrolling** is off, so the mouse wheel scrolls the usual way. It is one
  setting for the mouse and the trackpad.
- **Spotlight indexing and Time Machine** are off. They use CPU and disk for nothing.
- **Keys repeat fast.** macOS repeats a held key every 90 ms after 375 ms, which is slow, most of
  all through the web viewer. The script sets 30 ms after 225 ms (the fastest that System Settings
  offers) and turns off the accent menu on a held key. See below.
- **The keyboard layout is saved**, so the Keyboard Setup Assistant stops asking at every start.
  See below.
- **Automatic login** is on: the VM goes straight to the desktop of the account that ran the
  script, after a restart or a crash, with nobody to type a password. See below.
- **Dialogs nobody can answer** are off: the Bluetooth keyboard pairing window, the
  crash report dialog, and the iCloud, Siri and privacy prompts.

Reduce Motion, Reduce Transparency and the scroll direction show only after you log
out and in. macOS refuses some settings. The script lists them at the end. For
Reduce Motion and Reduce Transparency, set them in **System Settings >
Accessibility > Display**.

### Terminal: iTerm2, not Ghostty

The terminal is **iTerm2**, pinned in the Dock. **Ghostty is not installed: it needs a GPU and does
not start in this VM.** It draws with Metal on macOS and has no software renderer or setting to turn
the GPU off (the Ghostty project has discussed a CPU renderer but has none). To add it on a Mac or a
Tart VM that has a GPU, add `ghostty` to `CASKS` and `"Ghostty"` to `CASK_APPS` in
`shared/setup-macos.sh`, and `"$APPLICATIONS_DIR/Ghostty.app"` to the Dock list. A VM that
already has Ghostty keeps it: the script only stops pinning it.

### Browsers: default browser and first run

- **Firefox is the default browser.** The script writes the handlers for `http`, `https` and HTML
  files into `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`
  and restarts `lsd`. This is what System Settings writes, and macOS asks nothing. The usual way for
  a program to do it, `LSSetDefaultHandlerForURLScheme`, makes macOS ask "Do you want to change your
  default web browser?", which a script cannot answer. Checked on this VM: after the change,
  LaunchServices reports `org.mozilla.firefox` for `http` and `https`.
- **Firefox's welcome page and prompts** are off through `Firefox.app/Contents/Resources/distribution/
  policies.json`: no first-run page, no onboarding, no "what's new" page, no "make Firefox the
  default" bar and no telemetry notice. Firefox then says "managed by your organization" in its
  menu. An update that replaces the app removes the file: run the script again.
- **Chrome's welcome screen** is off by a `First Run` file in
  `~/Library/Application Support/Google/Chrome/`. That is all. **Chrome policies are not set, on
  purpose.** They would have to be in `/Library/Managed Preferences/com.google.Chrome.plist`, and
  macOS erases that folder at every start (checked on this VM: the file written by the script was
  gone after the next boot). So Chrome may still ask its other first-run questions once: the
  default-browser bar, sign-in and the macOS keychain question ("Chrome wants to use your confidential
  information stored in Chrome Safe Storage"). Answer them by hand. A profile that was started under
  the old policy file stopped opening windows after a restart; a new profile works (move
  `~/Library/Application Support/Google/Chrome` aside to get one).
- **Not tested:** nobody has opened Firefox in a restored VM to see that no first-run screen comes up
  there; Firefox did open fine after the setup run.
- `--skip-browsers` leaves all of this out.

### Key repeat

macOS starts with `KeyRepeat` 6 and `InitialKeyRepeat` 25, in units of 15 ms: 90 ms between
repeats, after 375 ms. Through noVNC that feels slow. The tuning phase sets 2 and 15 (30 ms after
225 ms), the end of the sliders in System Settings > Keyboard, and sets `ApplePressAndHoldEnabled`
to false, so that holding a key repeats it and does not open the accent menu, which gets in the
way in a terminal and in vim. `KEY_REPEAT=3 INITIAL_KEY_REPEAT=20 ./setup-macos.sh` picks other
values, and `--skip-keyboard` skips this and the layout. The change shows after the next log out
and in. noVNC sends a held key once, so the repeating is done by macOS in the VM, and these
settings are the ones that count. By hand: `defaults write -g KeyRepeat -int 2`, and
`defaults write -g InitialKeyRepeat -int 15`.

### Keyboard layout

The VM's keyboard is a virtual USB keyboard from QEMU. It does not say whether it is ANSI, ISO or
JIS, so macOS runs the **Keyboard Setup Assistant** to ask, and it asks again at a start if it has
no saved answer. macOS keeps the answer in `/Library/Preferences/com.apple.keyboardtype.plist`, under
the name `<vendor id>-<product id>-<country code>`, as a number: 40 is ANSI, 41 is ISO, 42 is JIS.

The tuning phase writes that answer for every keyboard macOS can see (found with `ioreg`), and for
QEMU's keyboard (`1575-1-0`) in case it is not connected yet, and then closes an Assistant that is
open. It skips what is saved already. `KEYBOARD_TYPE=iso` or `jis` picks another layout, and
`--skip-keyboard` skips the step.

By hand, in the VM: `sudo defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype
-dict-add 1575-1-0 -int 40` (take the numbers from `ioreg -r -c IOHIDDevice -l | grep -E
'VendorID|ProductID|CountryCode'`). Or answer the Assistant to the end: press Z when it asks for the
key right of the left Shift, then / for the key left of the right Shift.

**Not tested in a real VM yet:** the step was tested with fake `ioreg` and `defaults` output. If the
Assistant still comes up after a restart, run the commands above and look at what
`sudo defaults read /Library/Preferences/com.apple.keyboardtype` shows.

### One password prompt

Phase 1 asks for the password of the account that runs the script, **once**, and checks it with
`sudo`. The script then uses it for three things, without asking again:

- **sudo.** The sudo ticket is kept fresh in the background. If a program that has no terminal of
  its own (or a ticket that has run out) needs sudo anyway, `SUDO_ASKPASS` answers it.
- **Automatic login.** `sysadminctl -autologin ... -password -` asks for the password itself, so the
  script answers it with `expect` (part of macOS, `/usr/bin/expect`). If that does not work, or
  `expect` is missing, `sysadminctl` asks you on the terminal as before.
- **Anything else** in the run that asks, such as a cask installer, gets the password through
  `SUDO_ASKPASS`.

The password is held in the script's memory and environment (`SETUP_PW`) and nowhere else: it is
not on a command line (so `ps` does not show it), not written to a file and not in the log. The
helper that `SUDO_ASKPASS` names holds no password: it reads `SETUP_PW`. It is in a private
folder under `/tmp` that the script removes when it ends. A run with no terminal (a pipe) cannot
ask: it needs `sudo` to work without a password.

### Automatic login

To log in by itself, macOS has to keep the account's password, so the script has to ask for it.
Early in phase 2 it runs `sudo sysadminctl -autologin set -userName <you> -password -`, and the
`-` makes **macOS itself prompt** for the password at the terminal. Type it (nothing is shown).
The script never sees the password, never writes it to the log and never puts it on a command
line. It is skipped when:

- it is already set up for that account, so a re-run does not ask again;
- **FileVault** is on, because the disk is locked until the password is typed, so macOS cannot log
  in by itself then;
- there is no terminal to type in (for example a run over a pipe). The script prints the command to
  run yourself later.

**The trade-off:** macOS keeps the password in `/etc/kcpassword`, which is only *lightly
obfuscated*: anyone who can read the VM disk can recover it. For a local test VM that is usually
fine; it is also why macOS leaves this off by default. If the password was wrong, auto-login does
not work at the next start: run the command above again. To turn it off: `sudo sysadminctl
-autologin off`. `--skip-autologin` skips the step, and `AUTOLOGIN_USER=<name>` sets it up for
another account. The step is part of the tuning phase, so `--skip-tuning` skips it too.

### Updates

The script turns on the five Automatic Updates toggles (check, download, install
macOS updates, security responses, system data files). macOS then installs point
releases such as 15.5, and security updates, by itself, and **restarts the VM** to
finish them. App Store app updates stay off, because there is no Apple ID.

macOS never installs a major upgrade by itself, so no setting is needed to stop
one. The script cannot hide the "macOS 26 is available" prompt, though.
`softwareupdate --ignore` stopped working for major releases in 2020 unless the Mac
is in MDM, and a profile can defer a major release for 90 days at most, also only
with MDM. Do not click **Upgrade Now**.

### The white background (phase 8)

Since macOS 14, the aerial wallpapers (Landscape, Cityscape, Underwater, Earth, and
Shuffle Aerials) need Metal 3D acceleration. They are video files (`.mov`). The VM
has no GPU, so they draw as a white or black screen. A still image, such as a
`.heic`, `.png` or `.jpg`, always draws.

Phase 8 sets the **default wallpaper of the macOS release** on every display. That
is a still image ("Sequoia Sunrise" on macOS 15). Apple keeps a symlink to it at
`/System/Library/CoreServices/DefaultDesktop.heic`. The script follows the link at
run time, so no file name is fixed in the script and it still works on the next
release.

- It refuses anything that is not a `.heic`, `.jpg` or `.png`, so it can never pick
  an aerial by mistake.
- It sets the image with `desktoppr`. That tool does not raise the "wants to control
  System Events" prompt that `osascript` raises. If `desktoppr` fails, the script
  falls back to `osascript` and gives it 30 seconds before it gives up.
- It restarts `WallpaperAgent`, because the wallpaper has had its own daemon since
  macOS 14, and that daemon keeps the old choice.
- It deletes the aerial videos in
  `/Library/Application Support/com.apple.idleassetsd/Customer`, if any. macOS
  downloads them in the background, each 600 MB to 1.5 GB. They are a cache.

If the link is missing, the script says so, and you set a wallpaper by hand in
**System Settings > Wallpaper > Pictures**. Do not pick an aerial there.

### Opening the cask apps without a prompt (phase 7)

Homebrew downloads each cask, so macOS marks the app as quarantined. The first
launch then asks "are you sure you want to open it". The script clears that flag on
Firefox, Chrome and iTerm with `xattr -dr com.apple.quarantine`, and checks that
it is gone. It only touches those three apps. It does not turn Gatekeeper off.

Homebrew no longer has `--no-quarantine`, and it dropped the `HOMEBREW_CASK_OPTS`
variable too, so the script cannot ask Homebrew to skip the flag. For a cask you
install later, clear the flag by hand:

```
xattr -dr com.apple.quarantine "/Applications/<App>.app"
```

### The Dock (phase 9)

The script writes the Dock preferences, so everything else (Launchpad, Safari,
Mail, and so on) goes. Finder and the Trash cannot be removed, and a running app
shows in the Dock until it quits. The Applications and Downloads folders are set to
**View content as: Grid** and **Display as: Folder**. If an app is not installed,
for instance after a failed cask, the script says so and leaves it out.

It writes the preferences itself and does not use `dockutil`, because Homebrew has
no Intel bottle of `dockutil` for macOS 15, so it would build from source.

### Xcode (phase 4)

1. It does nothing if an `Xcode*.app` is already in `/Applications`, except step 5.
2. It finds the `.xip` in the folder of the script, then in `/Volumes/shared`. A file
   whose name shows that it cannot run here (Xcode 26.4 or newer on macOS 15, Xcode 27,
   or an Apple silicon download) is passed over. It needs about 35 GB of free disk and
   stops if there is less.
3. It expands the `.xip` on the local disk, in `~/xcode-install`, and not on the
   share. The share is slow. This takes about 15 to 40 minutes and prints nothing
   until it ends.
4. It checks the app: the macOS version it needs, and that it has code for this
   kind of Mac. If the check fails, the app stays in `~/xcode-install` (about 15 GB).
   Delete that folder when you do not need it. Otherwise the app moves to
   `/Applications`.
5. It points the developer tools at Xcode (`xcode-select -s`), accepts the licence
   and runs the first launch tasks, so `xcodebuild` works at once.

Simulators are not installed. Add one with `xcodebuild -downloadPlatform iOS`. It is
several GB.

Your `.xip` is not deleted. You can delete it from `shared/` after the install.

### ssh (phase 10)

Remote Login is turned on, and your `id_ed25519` key is authorized. From the host:

```
ssh -p 2223 <user>@127.0.0.1
```

### Go (phase 11)

The last phase installs Go with **your** `go-setup.sh`, from `scripts/go-setup.sh` in
`github.com/kenshaw/shell-config`. It is last because that script builds Go from source: it
downloads the newest release as a bootstrap compiler, clones `go.googlesource.com/go` into
`/usr/local/go`, checks out the newest release tag and runs `make.bash`. That takes several
minutes and needs the network.

The script runs it as `sudo env PATH=... <bash> go-setup.sh -u -f`:

- **`-u -f`** are the flags you asked for. `-u` is the update flag, without which the script does
  nothing, and `-f` skips its "not root" check, because `sudo` sets `USER` to root.
- **The new bash.** It runs under the modern bash that the script installed (Homebrew's, or
  MacPorts' on Intel), not Apple's 3.2.
- **GNU tools first on the PATH.** `go-setup.sh` reads the Go download page with `sed -E` patterns
  that use `.+?`. The BSD `sed` on macOS cannot parse those, and your script's own header says
  to install `curl gawk gnu-sed`. So GNU `sed` and `awk` are linked under the plain names into a
  folder of their own, which goes first on the PATH, followed by the GNU coreutils folders. That
  does not depend on how Homebrew or MacPorts name their tools. The folder is removed afterwards.
- **`env PATH=...`**, because `sudo` does not keep your PATH.
- **No change to `go-setup.sh` was needed.** I read it against this setup and it works as it is.

**Where the script comes from.** In this order: `GO_SETUP_SCRIPT=/path`, a `go-setup.sh` in the
same folder as `setup-macos.sh`, or the download from GitHub. Because it runs as root, a
download is only run if it is a bash script that parses, and its checksum is written to the
log. A web page or an error from a proxy is refused.

**Re-runs.** If `/usr/local/go/bin/go` already works, the phase is skipped. `--update-go` runs it
again, and `go-setup.sh` then rebuilds Go. If a run died half way, there is no working `go`, so
the next run does it again.

**The PATH.** The `~/.bashrc` that the script writes puts `/usr/local/go/bin` and `~/go/bin` on
the PATH (the second is where `go install` puts programs). They are added only when the folders
exist, so the same file is right before and after Go is installed. Open a new terminal after the
install.

## What it does not do

- It does not change environment variables, other than through the `~/.bash_profile` and
  `~/.bashrc` it writes (above). The MacPorts installer also adds `/opt/local/bin` to
  `~/.zprofile` itself, which only zsh reads. The script tells you when that happens.
- It does not install your personal dotfiles or `shell-config`.
- It does not run a macOS update itself.
- It does not set the default browser: macOS asks for a click to confirm that.
- It does not sign in to the App Store or iCloud.

Two things from the VM guides were left out on purpose:

- `nvram boot-args="serverperfmode=1"`. OpenCore sets the boot arguments for this
  VM, and a write can replace them and stop it booting.
- Turning off telemetry and Siri daemons with `launchctl disable`. That needs SIP
  off, and the VM does not need it.

## Troubleshooting

| problem | what to do |
|---|---|
| `/Volumes/shared` is missing | Run `sudo -S mount_9p shared`. If that fails, run `mount \| grep 9p` and `ls /Volumes`. The container must be created by `launch-macos.sh`, which adds the share. |
| the script says no `.xip` was found | Put `Xcode_*.xip` in `macos15/shared/` and run the script again. |
| the script says no Xcode here can run on this Mac, or that an Xcode needs a newer macOS or is for Apple silicon only | The Xcode is too new for macOS 15 (26.4 and newer) or is Xcode 27. Download **Xcode 26.3** from https://developer.apple.com/download/all/ and run the script again. If the message came after an expand, delete `~/xcode-install` first to free about 15 GB. |
| Remote Login fails | The terminal needs Full Disk Access. Turn on **System Settings > General > Sharing > Remote Login** by hand. |
| a cask or formula failed | The name may have moved. Run `brew search <name>`, then run the script again. |
| Homebrew says "only supported on Apple Silicon processors" | You ran Homebrew's own installer on an Intel Mac. The script does not do that: on Intel it sets Homebrew up by hand. See *Package managers*. |
| a port failed in hybrid mode | It has no ready-made binary for this macOS. The script installs ports in binary-only mode so it never compiles for hours. Install it by hand with `sudo port install <name>` if you accept the build. |
| I need to see what failed | Read `~/setup-macos.log` in the VM (from the host: `ssh -p 2223 user@127.0.0.1 'cat ~/setup-macos.log'`). The failures are listed at the end of the last run, and `grep FAILED` finds them. |
| a port failed with "Failed to archivefetch" | A port that the port needs has no ready-made binary for macOS 15 Intel. The script builds small ones from source and tries again; a big one (a compiler, Rust, Go, Node, Python) is refused so it never builds for hours. See *Package managers*. |
| the background is still white | Check `ls -l /System/Library/CoreServices/DefaultDesktop.heic`. Then set a picture by hand in **System Settings > Wallpaper > Pictures**. |
| settings did not take effect | Log out and in. Reduce Motion, Reduce Transparency and the scroll direction need it. |
| the VM is slow after the install | Run `./launch-macos.sh --recreate` to move from 8 GB to 16 GB. |

## Status

The script was tested against fake macOS commands on Linux. That covers the logic of
every phase, including the failure paths. It has not yet run on a real macOS 15 VM,
so expect to fix small things on the first real run.

## Sources

Where the facts in this document came from:

- **Xcode 27 is Apple silicon only, and needs macOS 26.4 or later:** the release
  notes quoted in the Apple Developer Forums thread
  [Xcode 27 for Intel Macs](https://developer.apple.com/forums/thread/829619).
  Other reports say macOS 27 also drops Intel Macs.
- **Xcode 26.0 to 26.3 need macOS 15.6, and 26.4 to 26.6 need macOS 26.2, so 26.3 is
  the newest that runs on macOS 15:** [Xcode version history](https://mungomash.com/software/xcode/versions/)
  and [Xcode and macOS version compatibility](https://tech.amikelive.com/node-1776/xcode-and-macos-version-compatibility/).
  The script checks the file name, and then the app's own `LSMinimumSystemVersion`, so a
  wrong table cannot install an Xcode that does not run.
- **Aerial wallpapers need Metal, so they draw white without a GPU:**
  [a VMware Fusion thread](https://community.broadcom.com/vmware-cloud-foundation/communities/community-home/digestviewer/viewthread?GroupId=7165&MessageKey=9fd14b7e-0df4-45de-9ac2-0bd5994222b6&CommunityKey=0c3a2021-5113-4ad1-af9e-018f5da40bc0).
- **The default wallpaper link:** [where macOS stores wallpapers](https://filepathgeek.com/posts/macos-wallpaper-location/) and [DefaultDesktop.heic](https://www.tech-otaku.com/mac/setting-desktop-image-macos-mojave-from-command-line/).
- **Setting the wallpaper:** [desktoppr](https://github.com/scriptingosx/desktoppr) and
  [setting it from the command line](https://techearl.com/set-mac-wallpaper-command-line).
- **Aerial video downloads:** [idleassetsd](https://deepclean.app/blog/mds-stores-idleassetsd-disk-space-mac).
- **VM tuning:** [osx-optimizer](https://github.com/sickcodes/osx-optimizer),
  [macOS on Linux](https://behnamlal.xyz/blog/macos-on-linux/) and
  [Reduce Transparency on Sequoia](https://derflounder.wordpress.com/2025/06/18/setting-reduced-transparency-on-macos-sequoia/).
- **Updates:** [automatic updates only install point releases](https://www.macworld.com/article/1387948/macos-automatic-updates.html),
  and [`softwareupdate --ignore` and MDM](https://mrmacintosh.com/10-15-5-2020-003-updates-changes-to-softwareupdate-ignore/).
- **Homebrew 7.0.0 moves Intel to Tier 3, and the installer needs Apple silicon:**
  [the 7.0.0 release](https://brew.sh/2026/09/13/homebrew-7.0.0/) and
  [Support Tiers](https://docs.brew.sh/Support-Tiers). The installer's own text is at
  [Homebrew/install](https://github.com/Homebrew/install/blob/HEAD/install.sh).
- **Which formulae have an Intel bottle:** Homebrew's public API
  (`https://formulae.brew.sh/api/formula/<name>.json`), checked for every formula in
  the list.
- **MacPorts has Intel binaries for macOS 15:** the [MacPorts releases](https://github.com/macports/macports-base/releases)
  (a `-15-Sequoia.pkg` installer) and the [package server](https://packages.macports.org/).
- **`--no-quarantine` removed from Homebrew:** [Homebrew issue 20755](https://github.com/Homebrew/brew/issues/20755).
- **The Dock keys:** [a gist of Dock defaults](https://gist.github.com/kamui545/c810eccf6281b33a53e094484247f5e8).
- **The disk format setting (`DISK_FMT`):** read from the image itself: `/run/disk.sh` in the
  `dockurr/macos` container. The dockur readmes do not document it.
- **go-setup.sh:** [scripts/go-setup.sh in kenshaw/shell-config](https://github.com/kenshaw/shell-config/blob/HEAD/scripts/go-setup.sh).
  Its header says it needs `curl`, `gawk` and `gnu-sed` on macOS.
- **dockur/macos** (the image, ports, `mount_9p`): [its readme](https://github.com/dockur/macos).
