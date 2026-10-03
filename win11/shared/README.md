# Windows 11 provisioning

This directory is mounted into the container twice — as `/shared` (drive **Z:**
inside Windows) and as `/oem` (copied to `C:\OEM` on a fresh install).

| file | purpose |
|---|---|
| `setup-dev.ps1` | the provisioning script |
| `install.bat` | dockur/windows runs this automatically at the end of an unattended install |

## Running it on the current install

The VM is already installed, so `/oem` will not fire — run the script by hand.
The container predates the mounts, so recreate it once (the disk in
`windows-data/` is untouched):

```bash
podman rm -f windows11 && ./launch-windows.sh
```

Then in the VM (web viewer at http://localhost:8006), from PowerShell:

```
powershell -ExecutionPolicy Bypass -File Z:\setup-dev.ps1
```

The script relaunches itself elevated via UAC — accept the prompt.

## Running it automatically on a fresh install

dockur/windows copies whatever is mounted at `/oem` to `C:\OEM` and executes
`install.bat` "during the final step of the automatic installation". That is
already wired up in `launch-windows.sh`, so a wipe-and-reinstall provisions
itself with no interaction.

One wrinkle: that stage runs as SYSTEM, and **winget does not exist for
SYSTEM** — it is a per-user MSIX package. So `install.bat` runs the script with
`-SkipWinget` at OEM time and registers a `RunOnce` entry that runs the winget
phase at the first interactive logon.

For a single command rather than a script, dockur/windows also honours the
`COMMAND` environment variable.

## Phases

Order is fixed. Activation is always first and is not skippable.

| phase | contents |
|---|---|
| 1 | **Windows activation** — the procedure from `notes/windows-activate.md`: `/upk`, `/cpky`, `/ckms`, `changepk`, Pro GVLK via `/ipk`, `/skms`, `/ato`. Detects an already-licensed machine and leaves it alone rather than re-keying. |
| 2 | **Windows Update** — opts into Microsoft Update, then searches/downloads/installs everything, up to `-UpdatePasses` rounds, stopping when a reboot is required |
| 3 | **winget** — pwsh, windows terminal, neovim, git, gh, rustup, node lts, python, vc++ redist, 7zip, jq, vault, gcloud sdk, claude desktop, claude code, firefox |
| 4 | **OpenSSH server** — capability, sshd + ssh-agent automatic, firewall tcp/22, `DefaultShell`, and the ed25519 key into both `~\.ssh\authorized_keys` and `administrators_authorized_keys` with the ACL sshd demands |
| 5 | **Firefox as default browser** |

No MSYS2, no shell-config, no environment variables — the script does not touch
the Windows user environment.

## Switches

```
-BuildTools         also install the VS 2022 C++ build tools (~5GB)
-RebootIfNeeded     reboot automatically when Windows Update asks for it
-UpdatePasses <n>   update rounds to run (default 3)
-KmsHost <host>     KMS host for activation (default kms8.msguides.com)
-DefaultShell bash  sshd hands sessions to Git bash instead of pwsh
-PublicKey '...'    authorize a different key (default: ken@ken-desktop)
-SkipUpdates -SkipWinget -SkipSsh -SkipBrowser
```

Nothing aborts the run: failures collect and print as a list at the end. winget
ids drift, so if one fails, find the current id with `winget search <name>` and
re-run with the other phases skipped.

## Default browser

Windows 11 does not let a script write the per-user `UserChoice` hash — that is
deliberately tamper-proofed. The script uses the supported machine-wide route:
an association XML at `C:\ProgramData\setup-dev\default-associations.xml` with
the `DefaultAssociationsConfiguration` policy pointed at it. **This applies at
the next sign-in**, and while the policy is set the defaults cannot be changed
by hand. To release them, delete the `DefaultAssociationsConfiguration` value
under `HKLM\SOFTWARE\Policies\Microsoft\Windows\System`.

## SSH

`launch-windows.sh` publishes `127.0.0.1:2222` to the VM's port 22:

```bash
ssh -p 2222 <user>@127.0.0.1
```

Note that Windows Update's installer can refuse to run over a non-console
session (`0x80240044`), so drive phase 2 from the web viewer rather than ssh.
