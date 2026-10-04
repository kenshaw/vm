<#
.SYNOPSIS
    Provisions a fresh Windows 11 install: activation, updates, dev tooling, ssh.

.DESCRIPTION
    Runs in a fixed order:

      1. activate Windows (procedure from notes/windows-activate.md)
      2. install every available Windows update
      3. install the development toolchain via winget
      4. enable the native Windows OpenSSH server and authorize a public key
      5. make Firefox the default browser

    Activation always runs first and cannot be skipped; it detects an already
    licensed machine and leaves it alone rather than re-keying it.

    Every step is tolerant: a failure is recorded and reported in the summary
    instead of aborting the run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-dev.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-dev.ps1 -SkipBuildTools -RebootIfNeeded
#>

[CmdletBinding()]
param(
    # ssh public key authorized for inbound ssh (default: ken@ken-desktop)
    [string]$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG0VpXyS7XSOtkyobD0p97mqbDIst0bBz74f+aDzafV+ ken@ken-desktop',

    # the Windows account that the install made (dockur's USERNAME; see ../launch-windows.sh).
    # It gets the ssh key in its profile, and it is the account to log in as. Without it, the
    # script uses the one normal local account that the install makes, or 'user' if it cannot tell
    [string]$User = '',

    # shell sshd hands to inbound connections
    [ValidateSet('pwsh', 'powershell', 'bash', 'cmd')]
    [string]$DefaultShell = 'pwsh',

    # KMS host used by the activation step
    [string]$KmsHost = 'kms8.msguides.com',

    # how many search/download/install rounds of Windows Update to run
    [int]$UpdatePasses = 3,

    # reboot automatically when Windows Update asks for it
    [switch]$RebootIfNeeded,

    # leave out the Visual Studio 2022 C++ build tools, which are installed by default
    # (large, ~5GB, and slow)
    [switch]$SkipBuildTools,

    # accepted and ignored: the build tools are the default now (use -SkipBuildTools)
    [switch]$BuildTools,

    # skip individual phases (activation is never skipped)
    [switch]$SkipUpdates,
    [switch]$SkipWinget,
    [switch]$SkipSsh,
    [switch]$SkipBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----[ elevate ]---------------------------------------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host '>>> not elevated, relaunching as administrator ...' -ForegroundColor Yellow
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argv += "-$($kv.Key)" }
        } else {
            $argv += @("-$($kv.Key)", "`"$($kv.Value)`"")
        }
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argv
    exit
}

# ----[ log ]-------------------------------------------------------------------

# Everything this script prints is also written to a transcript. It starts in C:\OEM (which
# dockur makes from the shared folder) and is copied to the shared folder, where the host
# can read it, when the script ends or is about to reboot. Each run adds to the same log.
$script:LogFile = Join-Path $(if (Test-Path "$env:SystemDrive\OEM") { "$env:SystemDrive\OEM" } else { $env:ProgramData }) 'setup-dev.log'
try { Start-Transcript -Path $script:LogFile -Append | Out-Null }
catch { Write-Host "no log: $($_.Exception.Message)" -ForegroundColor Yellow }

# Save-Log: flush the transcript and copy it to the shared folder. Drive Z: belongs to a
# logged-in user, so the first run (as SYSTEM) may only find the network name.
function Save-Log {
    try { Stop-Transcript | Out-Null } catch { }
    foreach ($share in @('Z:\', '\\host.lan\Data\')) {
        if (Test-Path -LiteralPath $share) {
            try {
                Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $share 'setup-dev.log') -Force
                break
            } catch { }
        }
    }
}

# ----[ output helpers ]--------------------------------------------------------

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Notes    = New-Object System.Collections.Generic.List[string]
$script:Started  = Get-Date

function Write-Head($msg) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Write-Step($msg) { Write-Host ">>> $msg" -ForegroundColor White }
function Write-Ok($msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    skip: $msg" -ForegroundColor DarkGray }
function Write-Dim($msg)  { Write-Host "      $msg" -ForegroundColor DarkGray }
function Write-Fail($msg) {
    Write-Host "    FAILED: $msg" -ForegroundColor Red
    $script:Failures.Add($msg)
}
function Add-Note($msg) { $script:Notes.Add($msg) }

# ----[ the account ]-----------------------------------------------------------

# A normal local account has a SID that ends in a number of 1000 or more. The built-in ones
# (Administrator, Guest, DefaultAccount, WDAGUtilityAccount) are below that.
if (-not $User) {
    $normal = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
        $_.Enabled -and $_.SID.Value -match '-(\d+)$' -and [int]$Matches[1] -ge 1000 })
    $User = if ($normal.Count -eq 1) { $normal[0].Name } else { 'user' }
}
Write-Step "account: $User"

# ==============================================================================
#  phase 1: windows activation
#  transcribed from ~/src/shell-config/notes/windows-activate.md
# ==============================================================================

Write-Head 'phase 1: windows activation'

$slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'

function Invoke-Slmgr {
    param([Parameter(Mandatory)][string[]]$SlmgrArgs, [string]$Label)
    if (-not $Label) { $Label = ($SlmgrArgs -join ' ') }
    Write-Step "slmgr $Label"
    & cscript.exe //nologo $slmgr @SlmgrArgs 2>&1 | ForEach-Object { Write-Dim $_ }
    if ($LASTEXITCODE -eq 0) { Write-Ok "slmgr $Label" }
    else { Write-Fail "slmgr $Label (exit $LASTEXITCODE)" }
}

function Test-Activated {
    try {
        $p = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
            Where-Object { $_.PartialProductKey -and $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } |
            Select-Object -First 1
        if ($p) { return ($p.LicenseStatus -eq 1) }
    } catch { }
    return $false
}

if (Test-Activated) {
    Write-Skip 'windows already licensed, leaving activation alone'
    Invoke-Slmgr -SlmgrArgs @('/xpr') -Label '/xpr (expiry)'
} else {
    Write-Host '    not licensed; applying GVLK + KMS host from the notes' -ForegroundColor Yellow

    Invoke-Slmgr -SlmgrArgs @('/dlv')  -Label '/dlv  (state before)'
    Invoke-Slmgr -SlmgrArgs @('/upk')  -Label '/upk  (uninstall product key)'
    Invoke-Slmgr -SlmgrArgs @('/cpky') -Label '/cpky (clear key from registry)'
    Invoke-Slmgr -SlmgrArgs @('/ckms') -Label '/ckms (clear KMS host)'

    Write-Step 'DISM /online /Get-TargetEditions'
    & dism.exe /online /Get-TargetEditions 2>&1 | ForEach-Object { Write-Dim $_ }

    # licensing and update services must be running for activation to take
    Write-Step 'starting LicenseManager and wuauserv'
    foreach ($svc in @('LicenseManager', 'wuauserv')) {
        try {
            Set-Service -Name $svc -StartupType Automatic
            if ((Get-Service $svc).Status -ne 'Running') { Start-Service $svc }
            Write-Ok "$svc running"
        } catch {
            Write-Fail "service $svc : $($_.Exception.Message)"
        }
    }

    # set the edition to Pro, then install the Pro GVLK
    Write-Step 'changepk /productkey (Pro retail upgrade key)'
    & changepk.exe /productkey 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' 2>&1 | ForEach-Object { Write-Dim $_ }

    Invoke-Slmgr -SlmgrArgs @('/ipk', 'W269N-WFGWX-YVC9B-4J6C9-T83GX') -Label '/ipk (Pro GVLK)'
    Invoke-Slmgr -SlmgrArgs @('/skms', $KmsHost)                       -Label "/skms $KmsHost"
    Invoke-Slmgr -SlmgrArgs @('/ato')                                  -Label '/ato (activate)'
    Invoke-Slmgr -SlmgrArgs @('/xpr')                                  -Label '/xpr (expiry)'

    if (Test-Activated) { Write-Ok 'windows is activated' }
    else { Write-Fail 'windows still not activated (see slmgr output above)' }
}

# ==============================================================================
#  phase 2: windows update
# ==============================================================================

if (-not $SkipUpdates) {
    Write-Head 'phase 2: windows update'

    Write-Step 'ensuring wuauserv is running'
    try {
        Set-Service -Name wuauserv -StartupType Automatic
        if ((Get-Service wuauserv).Status -ne 'Running') { Start-Service wuauserv }
        Write-Ok 'wuauserv running'
    } catch {
        Write-Fail "wuauserv: $($_.Exception.Message)"
    }

    # opt into Microsoft Update, so drivers and non-OS Microsoft products are
    # offered too, not just Windows itself
    Write-Step 'opting into Microsoft Update'
    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $sm.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '') | Out-Null
        Write-Ok 'Microsoft Update service registered'
    } catch {
        Write-Skip "Microsoft Update opt-in unavailable ($($_.Exception.Message))"
    }

    $rebootNeeded = $false

    for ($pass = 1; $pass -le $UpdatePasses; $pass++) {
        Write-Step "update pass $pass of $UpdatePasses : searching"

        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $found    = $searcher.Search('IsInstalled=0 and IsHidden=0')
        } catch {
            Write-Fail "update search: $($_.Exception.Message)"
            break
        }

        if ($found.Updates.Count -eq 0) {
            Write-Ok 'no further updates available'
            break
        }

        Write-Host "    $($found.Updates.Count) update(s) available" -ForegroundColor Cyan

        $wanted = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found.Updates) {
            if (-not $u.EulaAccepted) {
                try { $u.AcceptEula() } catch { }
            }
            Write-Dim $u.Title
            [void]$wanted.Add($u)
        }

        Write-Step "pass $pass : downloading"
        try {
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $wanted
            $dlr = $dl.Download()
            # 2 = succeeded, 3 = succeeded with errors
            if ($dlr.ResultCode -in @(2, 3)) { Write-Ok "downloaded (result $($dlr.ResultCode))" }
            else { Write-Fail "download result code $($dlr.ResultCode)" }
        } catch {
            Write-Fail "update download: $($_.Exception.Message)"
            break
        }

        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $wanted) {
            if ($u.IsDownloaded) { [void]$ready.Add($u) }
        }
        if ($ready.Count -eq 0) {
            Write-Fail 'nothing downloaded successfully, stopping update phase'
            break
        }

        Write-Step "pass $pass : installing $($ready.Count) update(s)"
        try {
            $inst = $session.CreateUpdateInstaller()
            $inst.Updates = $ready
            $ir = $inst.Install()
            if ($ir.ResultCode -in @(2, 3)) { Write-Ok "installed (result $($ir.ResultCode))" }
            else { Write-Fail "install result code $($ir.ResultCode)" }
            if ($ir.RebootRequired) {
                $rebootNeeded = $true
                Write-Host '    a reboot is required to finish these updates' -ForegroundColor Yellow
                break
            }
        } catch {
            # 0x80240044 comes up when the install is not allowed from this
            # session type (e.g. driven over ssh rather than at the console)
            Write-Fail "update install: $($_.Exception.Message)"
            break
        }
    }

    if ($rebootNeeded) {
        if ($RebootIfNeeded) {
            Add-Note 'rebooting for Windows Update; re-run this script afterwards to finish'
            Write-Host ''
            Write-Host '>>> rebooting in 30s (Ctrl-C to cancel) ...' -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            Save-Log
            Restart-Computer -Force
            exit
        }
        Add-Note 'Windows Update needs a reboot; reboot and re-run to pick up the rest'
    }
}

# ==============================================================================
#  phase 3: winget packages
# ==============================================================================

function Test-WinGet {
    $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Initialize-WinGet {
    if (Test-WinGet) { return $true }

    Write-Step 'winget not found, bootstrapping App Installer'
    try {
        # registers the already-provisioned appx for this user (common on fresh images)
        Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
            ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register `
                    "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
            }
    } catch { }

    if (Test-WinGet) { Write-Ok 'winget registered'; return $true }

    try {
        $tmp = Join-Path $env:TEMP 'wingetboot'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $urls = @{
            'vclibs.appx' = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
            'winget.msix' = 'https://aka.ms/getwinget'
        }
        foreach ($kv in $urls.GetEnumerator()) {
            $dst = Join-Path $tmp $kv.Key
            Write-Step "downloading $($kv.Key)"
            Invoke-WebRequest -Uri $kv.Value -OutFile $dst -UseBasicParsing
            Add-AppxPackage -Path $dst -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Fail "winget bootstrap: $($_.Exception.Message)"
        return $false
    }

    # appx installs land in WindowsApps, which may not be on PATH yet
    $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (Test-Path $wa) { $env:PATH = "$wa;$env:PATH" }

    if (Test-WinGet) { Write-Ok 'winget installed'; return $true }
    Write-Fail 'winget unavailable (install "App Installer" from the Store, then re-run)'
    return $false
}

# winget exit codes that mean "nothing to do", not "broken"
$script:WinGetOkCodes = @(
    0,
    -1978335189,  # 0x8A15002B no applicable upgrade
    -1978335135,  # 0x8A150061 package already installed
    -1978335212,  # 0x8A150014 already installed (older cli)
    -1978334967   # 0x8A1500F9 no newer version
)

function Install-Pkg {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Label = '',
        [string[]]$Extra = @()
    )
    if (-not $Label) { $Label = $Id }

    # already there?
    & winget list --id $Id -e --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Skip "$Label (already installed)"; return }

    Write-Step "installing $Label"
    $argv = @(
        'install', '--id', $Id, '-e',
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--silent'
    ) + $Extra

    & winget @argv 2>&1 | ForEach-Object { Write-Dim $_ }
    if ($script:WinGetOkCodes -contains $LASTEXITCODE) {
        Write-Ok $Label
    } else {
        Write-Fail "winget $Label (exit 0x$('{0:X8}' -f $LASTEXITCODE))"
    }
}

if (-not $SkipWinget) {
    Write-Head 'phase 3: winget packages'

    if (-not (Initialize-WinGet)) {
        Write-Fail 'skipping the winget phase'
    } else {
        Write-Step 'updating winget sources'
        & winget source update 2>&1 | Out-Null

        # --- shells, terminals, editors ---
        # 'powershell' (5.1, powershell.exe) ships in the box and cannot be
        # replaced by winget; this is pwsh 7.x, the current release
        Install-Pkg 'Microsoft.PowerShell'          'pwsh (latest)'
        Install-Pkg 'Microsoft.WindowsTerminal'     'windows terminal'
        Install-Pkg 'Neovim.Neovim'                 'neovim'

        # --- vcs ---
        Install-Pkg 'Git.Git'                       'git' -Extra @('--custom','/o:PathOption=CmdTools /o:SSHOption=ExternalOpenSSH /o:CRLFOption=CRLFCommitAsIs')
        Install-Pkg 'GitHub.cli'                    'gh'

        # --- languages / toolchains ---
        Install-Pkg 'Rustlang.Rustup'               'rustup'
        Install-Pkg 'OpenJS.NodeJS.LTS'             'node lts'
        Install-Pkg 'Python.Python.3.13'            'python 3.13'
        Install-Pkg 'Microsoft.VCRedist.2015+.x64'  'vc++ redist'
        if (-not $SkipBuildTools) {
            Install-Pkg 'Microsoft.VisualStudio.2022.BuildTools' 'vs 2022 build tools' `
                -Extra @('--override','--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
        }

        # --- cli utilities ---
        Install-Pkg '7zip.7zip'                     '7zip'
        Install-Pkg 'jqlang.jq'                     'jq'
        Install-Pkg 'Hashicorp.Vault'               'vault'

        # --- cloud / infra ---
        Install-Pkg 'Google.CloudSDK'               'gcloud sdk'

        # --- anthropic ---
        Install-Pkg 'Anthropic.Claude'              'claude desktop'
        Install-Pkg 'Anthropic.ClaudeCode'          'claude code'

        # --- browser ---
        Install-Pkg 'Mozilla.Firefox'               'firefox'
    }
}

# ==============================================================================
#  phase 4: openssh server + authorized key
# ==============================================================================

if (-not $SkipSsh) {
    Write-Head 'phase 4: openssh server'

    Write-Step 'installing the OpenSSH.Server capability'
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
            Write-Ok "installed $($cap.Name)"
        } elseif ($cap) {
            Write-Skip "$($cap.Name) already installed"
        } else {
            Write-Fail 'OpenSSH.Server capability not offered by this image'
        }
        # the client is handy too (ssh, scp, ssh-keygen on PATH)
        $ccap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' | Select-Object -First 1
        if ($ccap -and $ccap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $ccap.Name | Out-Null
            Write-Ok "installed $($ccap.Name)"
        }
    } catch {
        Write-Fail "openssh capability: $($_.Exception.Message)"
    }

    Write-Step 'enabling sshd + ssh-agent'
    # The capability can report "installed" before Windows has registered its sshd service.
    # That happens while a restart is pending (the Windows Update phase above leaves one),
    # and the service then appears after the restart. So wait a minute for it, and when it
    # does not come, say so and go on, instead of failing on a service that is not there yet.
    $sshdPending = $false
    $waited = 0
    while (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue) -and $waited -lt 60) {
        Start-Sleep -Seconds 5
        $waited += 5
    }
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        $sshdPending = $true
        Write-Skip 'the sshd service is not registered yet: Windows needs a restart first'
        Add-Note 'sshd is not registered yet (Windows has a restart pending). Restart Windows, then run this script again: it skips what is done, starts sshd and sets the shell and key'
    }
    foreach ($svc in @('sshd', 'ssh-agent')) {
        if ($svc -eq 'sshd' -and $sshdPending) { continue }
        try {
            Set-Service -Name $svc -StartupType Automatic
            Start-Service -Name $svc
            Write-Ok "$svc running"
        } catch {
            Write-Fail "service $svc : $($_.Exception.Message)"
        }
    }

    Write-Step 'opening the firewall for tcp/22'
    try {
        if (-not (Get-NetFirewallRule -Name 'sshd-tcp-22' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'sshd-tcp-22' -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            Write-Ok 'firewall rule sshd-tcp-22'
        } else {
            Write-Skip 'firewall rule already present'
        }
    } catch {
        Write-Fail "firewall: $($_.Exception.Message)"
    }

    # --- default shell ---
    $shellPath = switch ($DefaultShell) {
        'pwsh' {
            $p = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($p) { $p.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
        }
        'powershell' { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
        'bash'       { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
        'cmd'        { "$env:SystemRoot\System32\cmd.exe" }
    }
    if (-not (Test-Path $shellPath)) {
        Write-Fail "default shell $shellPath not present, leaving sshd on cmd.exe"
    } else {
        Write-Step "setting sshd default shell to $shellPath"
        try {
            if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
                New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
            }
            New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
                -Value $shellPath -PropertyType String -Force | Out-Null
            if ($DefaultShell -eq 'bash') {
                New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption `
                    -Value '-l -c' -PropertyType String -Force | Out-Null
            }
            Write-Ok "DefaultShell = $shellPath"
        } catch {
            Write-Fail "DefaultShell: $($_.Exception.Message)"
        }
    }

    # --- authorized key ---
    $key = $PublicKey.Trim()
    if ($key -notmatch '^(ssh|ecdsa)-') {
        Write-Fail "public key does not look like a key: '$key'"
    } else {
        if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
            Add-Note "there is no local account '$User' on this Windows. Was it installed with another name? Log in as that account; the key below still works for any administrator"
        }

        # per-user file, in the profile of the account the install made. That profile does not
        # exist until the account has logged in once, and the first run is as SYSTEM, before
        # that. Then only the administrators file below gets the key, which is enough for an
        # administrator account (and the install makes the account one).
        $userHome = Join-Path "$env:SystemDrive\Users" $User
        if (Test-Path -LiteralPath $userHome) {
            $userSsh = Join-Path $userHome '.ssh'
            $userAk  = Join-Path $userSsh 'authorized_keys'
            New-Item -ItemType Directory -Force -Path $userSsh | Out-Null
            $have = (Test-Path $userAk) -and ((Get-Content $userAk -Raw) -match [regex]::Escape($key))
            if ($have) {
                Write-Skip "key already in $userAk"
            } else {
                Add-Content -Path $userAk -Value $key -Encoding ascii
                Write-Ok "key -> $userAk"
            }
        } else {
            Write-Skip "no profile for '$User' yet ($userHome), so only the administrators file gets the key"
        }

        # administrators file: sshd ignores the per-user file for admin accounts
        $adminAk = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        New-Item -ItemType Directory -Force -Path (Split-Path $adminAk) | Out-Null
        $have = (Test-Path $adminAk) -and ((Get-Content $adminAk -Raw) -match [regex]::Escape($key))
        if ($have) {
            Write-Skip "key already in $adminAk"
        } else {
            Add-Content -Path $adminAk -Value $key -Encoding ascii
            Write-Ok "key -> $adminAk"
        }
        # sshd refuses the file unless only SYSTEM + Administrators can write it
        Write-Step 'fixing administrators_authorized_keys ACL'
        & icacls.exe $adminAk /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' 2>&1 |
            ForEach-Object { Write-Dim $_ }
        if ($LASTEXITCODE -eq 0) { Write-Ok 'ACL set' }
        else { Write-Fail 'icacls on administrators_authorized_keys' }

        Add-Note "authorized key installed for $User (and administrators)"
    }

    if (-not $sshdPending) {
        Write-Step 'restarting sshd'
        try { Restart-Service sshd -Force; Write-Ok 'sshd restarted' }
        catch { Write-Fail "restart sshd: $($_.Exception.Message)" }
    }

    Add-Note "ssh from the host (the launcher publishes port 2222): ssh -p 2222 $User@127.0.0.1"
}

# ==============================================================================
#  phase 5: firefox as the default browser
# ==============================================================================

if (-not $SkipBrowser) {
    Write-Head 'phase 5: firefox default browser'

    $ff = @(
        (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $ff) {
        Write-Fail 'firefox.exe not found, cannot set it as default browser'
    } else {
        # registering the app publishes its ProgIDs under HKLM\SOFTWARE\Classes
        Write-Step 'registering firefox as a browser'
        try {
            & $ff '-silent' '-setDefaultBrowser' 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            Write-Ok '-setDefaultBrowser'
        } catch {
            Write-Fail "firefox -setDefaultBrowser: $($_.Exception.Message)"
        }

        # firefox suffixes its ProgIDs with a per-install hash
        # (e.g. FirefoxURL-308046B0AF4A39CB), so discover them rather than guess
        function Get-FirefoxProgId([string]$Prefix) {
            $hit = Get-ChildItem 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like "$Prefix*" } |
                Sort-Object PSChildName -Descending |
                Select-Object -First 1
            if ($hit) { return $hit.PSChildName }
            return $Prefix
        }

        $urlId  = Get-FirefoxProgId 'FirefoxURL'
        $htmlId = Get-FirefoxProgId 'FirefoxHTML'
        Write-Ok "progids: $urlId / $htmlId"

        # Windows 11 will not let a script write the UserChoice hash. the
        # supported machine-wide route is the "Set a default associations
        # configuration file" policy, which Pro honours at next sign-in.
        $assocDir = Join-Path $env:ProgramData 'setup-dev'
        $assocXml = Join-Path $assocDir 'default-associations.xml'
        New-Item -ItemType Directory -Force -Path $assocDir | Out-Null

        $assoc = @(
            @{ id = 'http';   prog = $urlId  },
            @{ id = 'https';  prog = $urlId  },
            @{ id = 'ftp';    prog = $urlId  },
            @{ id = '.htm';   prog = $htmlId },
            @{ id = '.html';  prog = $htmlId },
            @{ id = '.shtml'; prog = $htmlId },
            @{ id = '.xhtml'; prog = $htmlId },
            @{ id = '.xht';   prog = $htmlId },
            @{ id = '.svg';   prog = $htmlId }
        )

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
        [void]$sb.AppendLine('<DefaultAssociations>')
        foreach ($a in $assoc) {
            [void]$sb.AppendLine(
                "  <Association Identifier=`"$($a.id)`" ProgId=`"$($a.prog)`" ApplicationName=`"Firefox`" />")
        }
        [void]$sb.AppendLine('</DefaultAssociations>')

        Write-Step "writing $assocXml"
        try {
            Set-Content -Path $assocXml -Value $sb.ToString() -Encoding UTF8
            Write-Ok 'association file written'
        } catch {
            Write-Fail "association file: $($_.Exception.Message)"
        }

        Write-Step 'applying the DefaultAssociationsConfiguration policy'
        try {
            $pk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
            New-Item -Path $pk -Force | Out-Null
            New-ItemProperty -Path $pk -Name DefaultAssociationsConfiguration `
                -Value $assocXml -PropertyType String -Force | Out-Null
            Write-Ok 'policy set'
            Add-Note 'firefox becomes the default browser at the next sign-in (policy-applied)'
            Add-Note "to change defaults by hand again, delete $pk\DefaultAssociationsConfiguration"
        } catch {
            Write-Fail "association policy: $($_.Exception.Message)"
        }

        try {
            & dism.exe /online /Import-DefaultAppAssociations:"$assocXml" 2>&1 |
                ForEach-Object { Write-Dim $_ }
            if ($LASTEXITCODE -eq 0) { Write-Ok 'dism default app associations imported' }
        } catch { }
    }
}

# ==============================================================================
#  summary
# ==============================================================================

Write-Head 'summary'

$elapsed = (Get-Date) - $script:Started
Write-Host ("    elapsed: {0:hh\:mm\:ss}" -f $elapsed)
Write-Host ("    activated: {0}" -f (Test-Activated))

if ($script:Notes.Count -gt 0) {
    Write-Host ''
    Write-Host '    notes:' -ForegroundColor Cyan
    foreach ($n in $script:Notes) { Write-Host "      - $n" -ForegroundColor Gray }
}

if ($script:Failures.Count -eq 0) {
    Write-Host ''
    Write-Host '    everything succeeded' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host "    $($script:Failures.Count) step(s) failed:" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "      - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '    winget ids drift; re-run with -Skip* to retry just what broke,' -ForegroundColor Yellow
    Write-Host '    or search a replacement with: winget search <name>' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '    sign out and back in (or reboot) to pick up PATH and browser defaults.' -ForegroundColor Yellow
Write-Host "    log: $script:LogFile (copied to the shared folder as setup-dev.log when it can be)" -ForegroundColor Gray
Write-Host ''

Save-Log
