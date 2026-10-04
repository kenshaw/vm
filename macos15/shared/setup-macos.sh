#!/bin/bash

# setup-macos.sh - provisions a fresh macOS install with the standard
# development environment.
#
# Run it after the macOS installer has finished and you have logged in:
#
#   bash setup-macos.sh
#
# What it does, in order:
#
#   1. asks for your password once and keeps sudo alive for the whole run
#   2. turns off what hurts in a VM: sleep, the screen saver, animations,
#      transparency, Spotlight, Time Machine and more. It sets macOS to
#      install point releases (15.x) by itself and never a major upgrade, and
#      logs in as you by itself at the login window (it asks for your password).
#   3. installs the Xcode Command Line Tools
#   4. installs full Xcode from the Xcode_*.xip that you put in the shared
#      folder. Apple requires a sign in to download Xcode, so that is by hand.
#   5. installs Homebrew
#   6. installs the command line tools (GNU userland, tools, languages): with
#      Homebrew, or with MacPorts on an Intel Mac (see PACKAGES below). It makes
#      the bash it installs your login shell, in place of zsh, and writes a
#      plain ~/.bash_profile and ~/.bashrc for it (see "bash config" below).
#   7. installs the casks (iterm2, chrome, firefox, desktoppr), then clears the
#      download quarantine flag from the Firefox, Chrome and iTerm apps so they
#      open without the "are you sure" prompt
#   8. sets the default wallpaper of this macOS release (the aerial ones need
#      a GPU and show as a white screen in a VM)
#   9. sets up the Dock: System Settings, Firefox, Chrome, iTerm and the App
#      Store, plus Applications and Downloads folders shown as a grid
#  10. turns on Remote Login (ssh) and authorizes a public key
#  11. installs Go with go-setup.sh from github.com/kenshaw/shell-config, run as
#      root with the new bash and the GNU tools (last: it builds Go from source)
#
# Every step is tolerant: a failure is recorded and shown in the summary
# instead of stopping the run. Running it again skips what is already done.
#
# bash config: ~/.bash_profile and ~/.bashrc are written for whoever runs the
# script. They set the PATH for Homebrew or MacPorts and the GNU tools, and add a
# history setting, a prompt, color for ls and grep, and completion. A file is only
# written when it does not exist, or when it is one that this script wrote (it has
# the line MANAGED-BY-SETUP-MACOS). Your own settings go in ~/.bashrc.local, which
# the script never touches. Any other existing file is left as it is, and the
# script writes its version next to it as <file>.setup-macos.
#
# Apart from that, the script does not change your environment variables. The
# MacPorts installer (hybrid mode) adds /opt/local/bin to ~/.zprofile itself; the
# script says so when that happens.
#
# usage: setup-macos.sh [--packages=auto|homebrew|hybrid]
#                       [--skip-tuning] [--skip-formulae] [--skip-casks]
#                       [--skip-wallpaper] [--skip-dock] [--skip-ssh]
#                       [--skip-xcode] [--skip-shell] [--skip-bashrc]
#                       [--skip-go] [--update-go] [--skip-autologin]
#                       [--skip-keyboard] [--skip-browsers] [--no-reboot]
#
# --packages (or PACKAGES in the environment) says how the command line tools are
# installed:
#   homebrew  Homebrew formulae. This is the default on Apple silicon, such as a
#             Tart VM.
#   hybrid    MacPorts for the command line tools, and Homebrew for the casks.
#             This is the default on an Intel Mac. Homebrew stopped building
#             bottles (ready-made binaries) for Intel, so most formulae would
#             compile from source there, which takes hours. MacPorts still has
#             ready-made Intel binaries, and is used in binary-only mode. When a
#             port fails because a small dependency has no binary, that one
#             dependency is built from source and the port is tried again.
#   auto      homebrew on Apple silicon, hybrid on Intel. This is the default.
# --skip-formulae skips the command line tools in either mode.
#
# GO_SETUP_SCRIPT in the environment names a go-setup.sh to run in place of the one
# downloaded from GO_SETUP_URL (default: scripts/go-setup.sh in
# github.com/kenshaw/shell-config). A go-setup.sh next to this script is used too.
# --update-go runs it again when Go is already installed; otherwise it is skipped.
# AUTOLOGIN_USER in the environment names the account that logs in by itself, in place
# of the one that runs this script.
# KEYBOARD_TYPE in the environment is ansi (the default), iso or jis: the keyboard layout
# that is saved so that the Keyboard Setup Assistant stops asking. See phase 2.
# When every step succeeded, the VM restarts by itself, 15 seconds after the summary
# (REBOOT_DELAY in the environment changes that; Ctrl-C cancels it): the key repeat,
# scroll direction and reduce motion only show after a log out and in, and the restart
# also tries the automatic login. It does not restart when a step failed, so that you can
# read the summary. --no-reboot never restarts.
# --skip-browsers leaves the browsers as they come. Otherwise Firefox becomes the default
# browser, and the first-run screens of Firefox and Chrome are turned off (see phase 7).
# KEY_REPEAT and INITIAL_KEY_REPEAT in the environment set how fast a held key repeats
# (default 2) and how long it waits before it starts (default 15). Each unit is 15 ms,
# and these are the fastest settings that System Settings offers. macOS starts at 6 and
# 25. Both belong to --skip-keyboard.
# DEFAULT_SHELL in the environment names the bash to make the login shell, in place
# of the one that Homebrew or MacPorts installed.
# PUBLIC_KEY in the environment replaces the key that is authorized for ssh.
# XCODE_SOURCE in the environment names the Xcode_*.xip (or an Xcode.app) to
# install. The default is the newest one in the folder of this script, or in
# /Volumes/shared.
# WALLPAPER_FILE in the environment names a PNG, JPEG or HEIC to use as the
# wallpaper, in place of the default one of this macOS release.
#
# This file must run under the /bin/bash that ships with macOS (bash 3.2).

PUBLIC_KEY="${PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG0VpXyS7XSOtkyobD0p97mqbDIst0bBz74f+aDzafV+ ken@ken-desktop}"

# the folder this script is in, which is the shared folder when it is run from there
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# where the apps live; the system ones are under /System/Applications
APPLICATIONS_DIR="${APPLICATIONS_DIR:-/Applications}"
SYSTEM_APPLICATIONS_DIR="${SYSTEM_APPLICATIONS_DIR:-/System/Applications}"

# ----[ package lists ]---------------------------------------------------------

# a name with a | in it is a list of alternatives: the first one that installs
# wins. Package names move between Homebrew releases.

# from notes/macos.md in shell-config
FORMULAE=(
    bash
    bat
    btop
    coreutils
    diffutils
    findutils
    gawk
    gnu-getopt
    gnu-indent
    gnu-sed
    gnu-tar
    gnu-which
    gnu-time
    gpatch
    grep
    gzip
    iproute2mac
    ldns
    make
    moreutils
    rsync
    sevenzip
    tmux
    tree
    unzip
    util-linux
    wget
    xz
    zstd

    # the darwin section of .bashrc puts these on PATH or sources them
    binutils
    curl
    ed
    gettext
    mtr
    neovim
    bash-completion

    # tools
    git
    gh
    jq
    node
    python
    rustup
)

# The same tools as FORMULAE, for MacPorts (PACKAGES=hybrid), by their MacPorts
# names. Every port here has a ready-made macOS 15 Intel binary. Left out:
# gnu-getopt (no port), git (Apple's comes with Xcode), gh and iproute2mac (no
# binary), bash-completion (your .bashrc looks for the Homebrew copy).
PORTS=(
    bash
    bat
    btop
    coreutils
    diffutils
    findutils
    gawk
    gindent         # gnu-indent
    gsed            # gnu-sed
    gnutar          # gnu-tar
    gwhich          # gnu-which
    gtime           # gnu-time
    gpatch
    grep
    gzip
    ldns
    gmake           # make
    moreutils
    rsync
    7zip            # sevenzip
    tmux
    tree
    unzip
    util-linux
    wget
    xz
    zstd

    binutils
    curl
    ed
    gettext
    mtr
    neovim

    jq
    nodejs24        # node
    python313       # python
    rustup
)

CASKS=(
    # the terminal. Ghostty is not here: it draws with Metal and does not start in a
    # VM without a GPU, and it has no software renderer
    iterm2

    google-chrome
    firefox

    # sets the wallpaper without the Automation prompt that osascript raises
    desktoppr
)

# the app bundles that casks put in $APPLICATIONS_DIR, which need the quarantine
# flag cleared. The other casks are command line tools and installer packages.
CASK_APPS=(
    "Firefox"
    "Google Chrome"
    "iTerm"
)

# ----[ arguments ]-------------------------------------------------------------

PACKAGES="${PACKAGES:-auto}"
SKIP_TUNING=0
SKIP_WALLPAPER=0
SKIP_DOCK=0
SKIP_XCODE=0
SKIP_SHELL=0
SKIP_BASHRC=0
SKIP_GO=0
SKIP_AUTOLOGIN=0
SKIP_KEYBOARD=0
SKIP_BROWSERS=0
NO_REBOOT=0
UPDATE_GO=0
SKIP_FORMULAE=0
SKIP_CASKS=0
SKIP_SSH=0
for arg in "$@"; do
    case "$arg" in
        --packages=*)    PACKAGES="${arg#--packages=}" ;;
        --skip-tuning)   SKIP_TUNING=1 ;;
        --skip-wallpaper) SKIP_WALLPAPER=1 ;;
        --skip-dock)     SKIP_DOCK=1 ;;
        --skip-xcode)    SKIP_XCODE=1 ;;
        --skip-shell)    SKIP_SHELL=1 ;;
        --skip-bashrc)   SKIP_BASHRC=1 ;;
        --skip-go)       SKIP_GO=1 ;;
        --skip-autologin) SKIP_AUTOLOGIN=1 ;;
        --skip-keyboard) SKIP_KEYBOARD=1 ;;
        --skip-browsers) SKIP_BROWSERS=1 ;;
        --no-reboot)     NO_REBOOT=1 ;;
        --update-go)     UPDATE_GO=1 ;;
        --skip-formulae) SKIP_FORMULAE=1 ;;
        --skip-casks)    SKIP_CASKS=1 ;;
        --skip-ssh)      SKIP_SSH=1 ;;
        -h|--help)       awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "Error: unknown argument '$arg' (try --help)"; exit 1 ;;
    esac
done

# ----[ browsers ]--------------------------------------------------------------

PLISTBUDDY=/usr/libexec/PlistBuddy
LSHANDLERS_PLIST="${LSHANDLERS_PLIST:-$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist}"
FIREFOX_DISTRIBUTION="${FIREFOX_DISTRIBUTION:-$APPLICATIONS_DIR/Firefox.app/Contents/Resources/distribution}"
CHROME_POLICY_PLIST="${CHROME_POLICY_PLIST:-/Library/Managed Preferences/com.google.Chrome.plist}"
CHROME_DATA_DIR="${CHROME_DATA_DIR:-$HOME/Library/Application Support/Google/Chrome}"

# set_default_browser <bundle id>: writes the handlers of http, https and html files into
# the LaunchServices plist, which is what System Settings > Desktop & Dock > Default web
# browser writes. The usual way for a program to do it (LSSetDefaultHandlerForURLScheme)
# makes macOS ask "Do you want to change your default web browser?", and a script cannot
# answer that. Writing the plist asks nothing; lsd reads it again once it is restarted.
# The handlers that http, https, public.html and public.xhtml had are replaced.
set_default_browser() {
    local id="$1" P="$LSHANDLERS_PLIST" i count before after scheme ctype kv k v
    mkdir -p "$(dirname "$P")"
    before="$(shasum "$P" 2>/dev/null)"
    "$PLISTBUDDY" -c 'Print :LSHandlers' "$P" >/dev/null 2>&1 || "$PLISTBUDDY" -c 'Add :LSHandlers array' "$P" >/dev/null 2>&1
    count=0
    while "$PLISTBUDDY" -c "Print :LSHandlers:$count" "$P" >/dev/null 2>&1; do
        count=$((count + 1))
    done
    i=$((count - 1))
    while [ "$i" -ge 0 ]; do
        scheme="$("$PLISTBUDDY" -c "Print :LSHandlers:$i:LSHandlerURLScheme" "$P" 2>/dev/null)"
        ctype="$("$PLISTBUDDY" -c "Print :LSHandlers:$i:LSHandlerContentType" "$P" 2>/dev/null)"
        case "$scheme|$ctype" in
            'http|'*|'https|'*|*'|public.html'|*'|public.xhtml')
                "$PLISTBUDDY" -c "Delete :LSHandlers:$i" "$P" >/dev/null 2>&1 ;;
        esac
        i=$((i - 1))
    done
    for kv in LSHandlerURLScheme:http LSHandlerURLScheme:https LSHandlerContentType:public.html LSHandlerContentType:public.xhtml; do
        k="${kv%%:*}"
        v="${kv#*:}"
        "$PLISTBUDDY" \
            -c "Add :LSHandlers:0 dict" \
            -c "Add :LSHandlers:0:$k string $v" \
            -c "Add :LSHandlers:0:LSHandlerRoleAll string $id" \
            -c "Add :LSHandlers:0:LSHandlerPreferredVersions dict" \
            -c "Add :LSHandlers:0:LSHandlerPreferredVersions:LSHandlerRoleAll string -" \
            "$P" >/dev/null 2>&1 || { fail "could not write the default browser to $P"; return 0; }
    done
    plutil -lint "$P" >/dev/null 2>&1 || { fail "$P is not a valid plist after the change"; return 0; }
    after="$(shasum "$P" 2>/dev/null)"
    if [ "$before" = "$after" ]; then
        skip "$id is the default browser already"
        return 0
    fi
    # lsd and cfprefsd keep the old handlers until they are restarted
    killall lsd cfprefsd >/dev/null 2>&1 || true
    ok "$id is the default browser (macOS asks nothing when a plist is written)"
}

# write_if_changed <file> <content>: writes a file, with sudo when the folder is not
# writable, and says whether it changed it (0) or found it as it was (1)
write_if_changed() {
    local file="$1" content="$2" dir tmp
    if [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$content" ]; then
        return 1
    fi
    dir="$(dirname "$file")"
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    if mkdir -p "$dir" 2>/dev/null && cp "$tmp" "$file" 2>/dev/null; then
        :
    else
        sudo mkdir -p "$dir" && sudo cp "$tmp" "$file" && sudo chmod 644 "$file" || { rm -f "$tmp"; fail "could not write $file"; return 2; }
    fi
    rm -f "$tmp"
    return 0
}

# set_firefox_policies: distribution/policies.json in the app is how an organization sets
# up Firefox, and it is read at every start. It turns off the welcome page and the
# onboarding, the "what's new" page after an update, the "make Firefox the default?" bar
# and the telemetry notice. Firefox says "managed by your organization" in its menu, and
# that is the price. An update of Firefox can replace the app: run this script again.
set_firefox_policies() {
    local f="$FIREFOX_DISTRIBUTION/policies.json" rc=0
    step 'Firefox: no welcome pages or prompts'
    if [ ! -d "$APPLICATIONS_DIR/Firefox.app" ] && [ -z "${FIREFOX_DISTRIBUTION_FORCE:-}" ]; then
        skip 'Firefox is not installed'
        return 0
    fi
    write_if_changed "$f" '{
  "policies": {
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DontCheckDefaultBrowser": true,
    "DisableTelemetry": true,
    "UserMessaging": {
      "SkipOnboarding": true,
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "UrlbarInterventions": false,
      "MoreFromMozilla": false
    }
  }
}' || rc=$?
    case "$rc" in
        0) ok "wrote $f" ;;
        1) skip "$f is as it should be" ;;
    esac
}

# set_chrome_policies: Chrome skips its welcome screen when a "First Run" file is in its
# data folder, and reads managed preferences from /Library/Managed Preferences (a system
# folder, so this needs sudo). The policies stop the "make Chrome your default browser"
# bar, the usage statistics question, the sign-in prompt and the promotional tabs.
# Chrome says "managed by your organization" in its menu, and that is the price. Chrome
# may ignore some policies on a Mac that no MDM manages; these are not among the sensitive
# ones. If a prompt still comes up, it has to be answered once, by hand.
set_chrome_policies() {
    local P="$CHROME_POLICY_PLIST" i key kind val line first="$CHROME_DATA_DIR/First Run"
    step 'Chrome: no welcome screen or prompts'
    CHROME_CHANGED=0
    if [ ! -d "$APPLICATIONS_DIR/Google Chrome.app" ] && [ -z "${CHROME_FORCE:-}" ]; then
        skip 'Chrome is not installed'
        return 0
    fi
    if [ -e "$first" ]; then
        skip 'the First Run file exists already'
    elif mkdir -p "$CHROME_DATA_DIR" && : > "$first"; then
        ok "wrote $first"
    else
        fail "could not write $first"
    fi

    for line in 'DefaultBrowserSettingEnabled bool false' 'MetricsReportingEnabled bool false' \
                'BrowserSignin integer 0' 'PromotionalTabsEnabled bool false'; do
        key="${line%% *}"; line="${line#* }"; kind="${line%% *}"; val="${line#* }"
        if [ "$(sudo "$PLISTBUDDY" -c "Print :$key" "$P" 2>/dev/null)" = "$val" ]; then
            continue
        fi
        sudo mkdir -p "$(dirname "$P")"
        if sudo "$PLISTBUDDY" -c "Set :$key $val" "$P" >/dev/null 2>&1 \
            || sudo "$PLISTBUDDY" -c "Add :$key $kind $val" "$P" >/dev/null 2>&1; then
            CHROME_CHANGED=1
        else
            fail "could not set the Chrome policy $key"
        fi
    done
    sudo chown root:wheel "$P" 2>/dev/null || true
    sudo chmod 644 "$P" 2>/dev/null || true
    if [ "${CHROME_CHANGED:-0}" = 1 ]; then
        killall cfprefsd >/dev/null 2>&1 || true
        ok "wrote the Chrome policies to $P"
    else
        skip "the Chrome policies in $P are as they should be"
    fi
}

# ----[ restart ]---------------------------------------------------------------

# reboot_now: counts down, so that Ctrl-C can cancel it, then restarts. It runs after
# the log is complete. REBOOT_COMMAND (in the environment) replaces the restart
# command, for tests.
reboot_now() {
    local n="${REBOOT_DELAY:-15}"
    case "$n" in ''|*[!0-9]*) n=15 ;; esac
    trap 'printf "\n    restart cancelled. Restart when you like: sudo shutdown -r now\n"; exit 0' INT
    printf '\n    Everything succeeded. Restarting the VM in %s seconds, so that the settings take effect.\n' "$n"
    printf '    Press Ctrl-C to cancel.\n'
    while [ "$n" -gt 0 ]; do
        printf '\r    restarting in %2d ' "$n"
        sleep 1
        n=$((n - 1))
    done
    printf '\r    restarting now      \n'
    sync
    if [ -n "${REBOOT_COMMAND:-}" ]; then
        # shellcheck disable=SC2086
        $REBOOT_COMMAND
    else
        sudo shutdown -r now
    fi
    trap - INT
}

# ----[ log ]-------------------------------------------------------------------

# Keep a copy of everything the script prints: in the home folder, and next to the
# script when that folder is writable. (On the dockur shared folder it is owned by root,
# so a normal user gets only ~/setup-macos.log.)
# The script runs itself again with its output piped to tee. The inner run sees
# SETUP_MACOS_LOGGING, so it does not do this again.
if [ -z "$SETUP_MACOS_LOGGING" ]; then
    SETUP_MACOS_LOGGING=1
    export SETUP_MACOS_LOGGING
    SETUP_LOGS=("$HOME/setup-macos.log")
    [ -w "$SCRIPT_DIR" ] && SETUP_LOGS+=("$SCRIPT_DIR/setup-macos.log")
    echo "log: ${SETUP_LOGS[*]}"
    {
        printf '\n===== setup-macos.sh started %s =====\n' "$(date '+%F %T')"
        bash "$0" "$@" 2>&1
        SETUP_RC=$?
        printf '===== setup-macos.sh finished %s, exit status %s =====\n' "$(date '+%F %T')" "$SETUP_RC"
        exit "$SETUP_RC"
    } | tee -a "${SETUP_LOGS[@]}"
    SETUP_RC="${PIPESTATUS[0]}"
    if [ "$SETUP_RC" = 0 ] && [ "$NO_REBOOT" = 0 ]; then
        reboot_now
    fi
    exit "$SETUP_RC"
fi

# ----[ output helpers ]--------------------------------------------------------

if [ -t 1 ]; then
    C_HEAD=$'\033[1;36m'; C_STEP=$'\033[1m'; C_OK=$'\033[32m'
    C_SKIP=$'\033[90m';   C_FAIL=$'\033[31m'; C_NOTE=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_HEAD=''; C_STEP=''; C_OK=''; C_SKIP=''; C_FAIL=''; C_NOTE=''; C_OFF=''
fi

FAILURES=()
NOTES=()
NOT_APPLIED=()
STARTED=$(date +%s)

head_()  { printf '\n%s%s%s\n  %s\n%s%s%s\n' "$C_HEAD" "$(printf '=%.0s' $(seq 1 78))" "$C_OFF" "$1" "$C_HEAD" "$(printf '=%.0s' $(seq 1 78))" "$C_OFF"; }
step()   { printf '%s>>> %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
ok()     { printf '%s    ok: %s%s\n' "$C_OK" "$1" "$C_OFF"; }
skip()   { printf '%s    skip: %s%s\n' "$C_SKIP" "$1" "$C_OFF"; }
fail()   { printf '%s    FAILED: %s%s\n' "$C_FAIL" "$1" "$C_OFF"; FAILURES+=("$1"); }
note()   { NOTES+=("$1"); }
dim()    { while IFS= read -r line; do printf '%s      %s%s\n' "$C_SKIP" "$line" "$C_OFF"; done; }

# ----[ preflight ]-------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: this script is for macOS."
    exit 1
fi
if [ "$(id -u)" = 0 ]; then
    echo "Error: do not run this as root or with sudo. Homebrew refuses to run as root."
    echo "Run it as your own (administrator) user. It asks for your password when needed."
    exit 1
fi

OS_VERSION="$(sw_vers -productVersion 2>/dev/null)"
ARCH="$(uname -m)"
echo "macOS $OS_VERSION on $ARCH, user $USER"

case "$PACKAGES" in
    auto)
        if [ "$ARCH" = x86_64 ]; then PACKAGES=hybrid; else PACKAGES=homebrew; fi
        ;;
    homebrew|hybrid) ;;
    *)
        echo "Error: --packages must be auto, homebrew or hybrid (not '$PACKAGES')"
        exit 1
        ;;
esac
echo "packages: $PACKAGES"

# ==============================================================================
#  phase 1: sudo
# ==============================================================================

head_ 'phase 1: administrator access'

# The password is asked here, once. It is the password of the account that runs the
# script, so it does three jobs: it authorizes sudo, it answers every later sudo (through
# SUDO_ASKPASS, in case the sudo ticket does not carry over to a program that has no
# terminal of its own), and it answers the password question of the automatic login.
# It is kept in a shell variable and in the environment of this script and what it starts
# (SETUP_PW). It is never put on a command line, never written to a file and never printed.
SETUP_PW=''

# ask_password: asks up to three times, and checks the password with sudo
ask_password() {
    local try pw
    for try in 1 2 3; do
        printf '    Password of %s (asked once: it is used for sudo and for the automatic login): ' "$USER" >&2
        IFS= read -rs pw || return 1
        printf '\n' >&2
        if printf '%s\n' "$pw" | command sudo -S -p '' -v 2>/dev/null; then
            SETUP_PW="$pw"
            return 0
        fi
        printf '    That password did not work.\n' >&2
    done
    return 1
}

step 'asking for your password (once)'
if [ -t 0 ]; then
    if ! ask_password; then
        echo "Error: sudo failed. The user must be an administrator, with the right password."
        exit 1
    fi
elif ! command sudo -v; then
    echo "Error: sudo failed. The user must be an administrator."
    exit 1
fi
ok 'sudo authorized'

# SUDO_ASKPASS names a program that prints the password. sudo -A runs it when sudo needs
# a password; when the ticket is valid it is not used. It reads the password from the
# environment, so no file holds it.
if [ -n "$SETUP_PW" ]; then
    ASKPASS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/setup-macos.XXXXXX")"
    chmod 700 "$ASKPASS_DIR"
    printf '#!/bin/sh\nprintf "%%s\\n" "$SETUP_PW"\n' > "$ASKPASS_DIR/askpass"
    chmod 700 "$ASKPASS_DIR/askpass"
    export SETUP_PW
    export SUDO_ASKPASS="$ASKPASS_DIR/askpass"
    sudo() { command sudo -A "$@"; }
fi

# keep the sudo timestamp fresh until this script exits
( while true; do
      sudo -n true 2>/dev/null || exit 0
      sleep 50
      kill -0 "$$" 2>/dev/null || exit 0
  done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null; [ -n "${ASKPASS_DIR:-}" ] && rm -rf "$ASKPASS_DIR"' EXIT

# ==============================================================================
#  phase 2: vm tuning
#  runs before the long installs, so the VM does not sleep or lock half way
# ==============================================================================

# ----[ automatic login ]-------------------------------------------------------

KEYBOARD_PLIST="${KEYBOARD_PLIST:-/Library/Preferences/com.apple.keyboardtype}"
KEYBOARD_TYPE="${KEYBOARD_TYPE:-ansi}"

# keyboard_ids: one "vendor-product-country" for each keyboard macOS can see. The
# Keyboard Setup Assistant saves its answer under that name, and a QEMU keyboard does
# not say which layout it has, so macOS asks again whenever the answer is missing.
# A keyboard is a HID device with usage page 1 and usage 6. The ids are in decimal.
# Product id 65535 is the placeholder of a virtual keyboard that macOS makes itself
# (Apple vendor 1452); it is never asked about, so it is left out.
keyboard_ids() {
    ioreg -r -c IOHIDDevice -l -w0 2>/dev/null | awk '
        function flush() { if (page == 1 && usage == 6 && vendor != "" && product != "" && product != 65535) print vendor "-" product "-" (country == "" ? 0 : country) }
        /\+-o / { flush(); vendor = product = country = page = usage = "" }
        /"VendorID" = /        { vendor = $NF }
        /"ProductID" = /       { product = $NF }
        /"CountryCode" = /     { country = $NF }
        /"PrimaryUsagePage" = / { page = $NF }
        /"PrimaryUsage" = /    { usage = $NF }
        END { flush() }' | sort -u
}

# set_keyboard_type: saves the layout for every keyboard that is connected now, and for
# the QEMU keyboard (1575-1-0), so that the Keyboard Setup Assistant does not come up at
# every start. The values are 40 for ANSI, 41 for ISO and 42 for JIS.
set_keyboard_type() {
    local code id ids missing=0 now
    step "keyboard layout: $KEYBOARD_TYPE"
    case "$KEYBOARD_TYPE" in
        ansi|ANSI) code=40 ;;
        iso|ISO)   code=41 ;;
        jis|JIS)   code=42 ;;
        *) fail "KEYBOARD_TYPE is '$KEYBOARD_TYPE'; use ansi, iso or jis"; return 0 ;;
    esac
    ids="$(printf '%s\n%s\n' "$(keyboard_ids)" '1575-1-0' | sed '/^$/d' | sort -u)"
    now="$(sudo defaults read "$KEYBOARD_PLIST" keyboardtype 2>/dev/null || true)"
    for id in $ids; do
        if printf '%s\n' "$now" | grep -Eq "\"?$id\"? = $code;"; then
            continue
        fi
        missing=1
        if sudo defaults write "$KEYBOARD_PLIST" keyboardtype -dict-add "$id" -int "$code"; then
            ok "saved $id as $KEYBOARD_TYPE ($code)"
        else
            fail "could not save the keyboard layout for $id"
        fi
    done
    if [ "$missing" = 0 ]; then
        skip "already saved for: $(echo $ids)"
        return 0
    fi
    # an Assistant that is open now has nothing left to ask
    pkill -x KeyboardSetupAssistant 2>/dev/null || true
    note "keyboard layout saved as $KEYBOARD_TYPE; if the Keyboard Setup Assistant still comes up after a restart, run it through once (press Z, then /) and tell the maintainers"
}

KEY_REPEAT="${KEY_REPEAT:-2}"
INITIAL_KEY_REPEAT="${INITIAL_KEY_REPEAT:-15}"

# set_key_repeat: macOS repeats a held key slowly (6, which is 90 ms, after a wait of 25,
# which is 375 ms; a unit is 15 ms), which is painful through the web viewer. The guest
# does the repeating, so these settings are the ones that count. A held key repeats
# instead of showing the accent menu, which matters in a terminal and in vim. All three
# show only after a log out and in.
set_key_repeat() {
    step 'key repeat'
    case "$KEY_REPEAT$INITIAL_KEY_REPEAT" in
        *[!0-9]*|'') fail "KEY_REPEAT and INITIAL_KEY_REPEAT are whole numbers (2 and 15 are the fastest that System Settings offers)"; return 0 ;;
    esac
    tune 'key repeat rate' defaults write -g KeyRepeat -int "$KEY_REPEAT"
    tune 'key repeat delay' defaults write -g InitialKeyRepeat -int "$INITIAL_KEY_REPEAT"
    tune 'press and hold' defaults write -g ApplePressAndHoldEnabled -bool false
    ok "a held key repeats every $((KEY_REPEAT * 15)) ms after $((INITIAL_KEY_REPEAT * 15)) ms; this shows after the next log out and in"
}

KCPASSWORD="${KCPASSWORD:-/etc/kcpassword}"
AUTOLOGIN_USER="${AUTOLOGIN_USER:-$USER}"

autologin_user_now() {
    defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null
}

# set_autologin: to log in by itself, macOS keeps the password of the account (lightly
# obfuscated, in /etc/kcpassword), so it has to be told the password. `sysadminctl
# -autologin set ... -password -` asks for it itself, at the terminal. This script never
# sees it, never writes it to the log, and never puts it on a command line.
set_autologin() {
    local u="$AUTOLOGIN_USER"
    step "automatic login as $u"

    if [ "$(autologin_user_now)" = "$u" ] && sudo test -f "$KCPASSWORD"; then
        skip "automatic login is already set up for $u"
        return 0
    fi
    # with FileVault on, the disk is locked until the password is typed, so macOS cannot
    if fdesetup status 2>/dev/null | grep -q 'FileVault is On'; then
        skip "FileVault is on, and macOS does not log in by itself then"
        return 0
    fi
    if [ ! -t 0 ]; then
        skip "there is no terminal to type the password in. Later, run: sudo sysadminctl -autologin set -userName $u -password -"
        return 0
    fi

    # With the password from phase 1, expect answers the question that sysadminctl asks
    # itself (-password - makes it read the password from the terminal, so it is not on a
    # command line). The password goes to expect through a pipe, not the command line.
    # If that does not work, sysadminctl asks you.
    if [ "$u" = "$USER" ] && [ -n "${SETUP_PW:-}" ] && [ -x /usr/bin/expect ] \
        && printf '%s' "$u" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        printf '%s\n' "$SETUP_PW" | sudo /usr/bin/expect -c "
            log_user 0
            set timeout 60
            gets stdin pw
            spawn sysadminctl -autologin set -userName $u -password -
            expect {
                -re {(?i)password} { sleep 0.5; send -- \"\$pw\\r\" }
                timeout { exit 2 }
                eof { exit 3 }
            }
            expect eof
            catch wait result
            exit [lindex \$result 3]
        " >/dev/null 2>&1
    fi
    if ! { [ "$(autologin_user_now)" = "$u" ] && sudo test -f "$KCPASSWORD"; }; then
        echo "    macOS needs the password of $u for this. It asks below: type it (nothing is shown)."
        sudo sysadminctl -autologin set -userName "$u" -password -
    fi

    if [ "$(autologin_user_now)" = "$u" ] && sudo test -f "$KCPASSWORD"; then
        ok "$u logs in by itself at the login window"
        note "automatic login keeps the password of $u, lightly obfuscated, in $KCPASSWORD: anyone who can read the disk can recover it. That is how macOS does it, and it is why it is off by default."
    else
        fail "automatic login was not set up (was the password right?). Try again with: sudo sysadminctl -autologin set -userName $u -password -"
    fi
}

# tune <label> <command...>: run one setting. A setting that macOS refuses (a
# SIP-protected domain, say) is listed in the summary, and the run goes on.
TUNE_OK=0
tune() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        TUNE_OK=$((TUNE_OK + 1))
    else
        NOT_APPLIED+=("$label")
    fi
}

if [ "$SKIP_TUNING" = 0 ]; then
    head_ 'phase 2: VM tuning'

    # ---- never sleep, never lock ----
    # a sleeping guest does not wake over VNC, and a locked one needs a
    # password typed through the web viewer
    step 'power: no sleep, no hibernation'
    for key in sleep displaysleep disksleep standby autopoweroff powernap; do
        tune "pmset $key" sudo pmset -a "$key" 0
    done
    tune 'pmset hibernatemode' sudo pmset -a hibernatemode 0
    tune 'pmset lessbright' sudo pmset -a lessbright 0
    tune 'pmset halfdim' sudo pmset -a halfdim 0

    step 'screen saver and lock'
    tune 'screensaver idleTime'    defaults -currentHost write com.apple.screensaver idleTime -int 0
    tune 'screensaver askForPassword' defaults write com.apple.screensaver askForPassword -int 0
    tune 'screensaver askForPasswordDelay' defaults write com.apple.screensaver askForPasswordDelay -int 0
    tune 'automatic logout' sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0
    tune 'login window screen lock' defaults write com.apple.loginwindow DisableScreenLock -bool true
    tune 'login window screen lock (system)' sudo defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLock -bool true
    if [ "$SKIP_KEYBOARD" = 0 ]; then
        set_keyboard_type
        set_key_repeat
    fi
    if [ "$SKIP_AUTOLOGIN" = 0 ]; then
        set_autologin
    fi

    # ---- no GPU: cut everything the window server has to composite ----
    step 'animations, transparency, motion and scroll direction'
    # the window and Dock animation keys from notes/macos/osx-disable-animations.sh
    # still work on macOS 15. com.apple.universalaccess (reduceMotion and
    # reduceTransparency) does not: macOS 15 refuses a write to it from a script
    # unless Terminal has Full Disk Access ("Could not write domain"), so those two
    # are left for System Settings, and the summary says so. ReduceMotionEnabled in
    # com.apple.Accessibility is accepted and stays below. Mail has no account in this VM, so its
    # animation keys are gone.
    #
    # com.apple.swipescrolldirection false turns off Natural scrolling, so the
    # mouse wheel scrolls the usual way. It is one setting for the mouse and the
    # trackpad, and it also shows only after a log out and in.
    while IFS='|' read -r domain key type value; do
        [ -n "$domain" ] || continue
        tune "$domain $key" defaults write "$domain" "$key" "-$type" "$value"
    done <<'EOF'
-g|NSAutomaticWindowAnimationsEnabled|bool|false
-g|NSScrollAnimationEnabled|bool|false
-g|com.apple.swipescrolldirection|bool|false
-g|NSWindowResizeTime|float|0.001
-g|QLPanelAnimationDuration|float|0
-g|NSScrollViewRubberbanding|bool|false
-g|NSDocumentRevisionsWindowTransformAnimation|bool|false
-g|NSToolbarFullScreenAnimationDuration|float|0
-g|NSBrowserColumnAnimationSpeedMultiplier|float|0
com.apple.dock|autohide-time-modifier|float|0
com.apple.dock|autohide-delay|float|0
com.apple.dock|expose-animation-duration|float|0
com.apple.dock|springboard-show-duration|float|0
com.apple.dock|springboard-hide-duration|float|0
com.apple.dock|springboard-page-duration|float|0
com.apple.finder|DisableAllAnimations|bool|true
com.apple.dock|launchanim|bool|false
com.apple.dock|no-bouncing|bool|true
com.apple.dock|mineffect|string|scale
com.apple.dock|show-recents|bool|false
com.apple.Accessibility|ReduceMotionEnabled|int|1
EOF

    # ---- background work that burns the VM's CPU and disk ----
    step 'Spotlight and Time Machine'
    tune 'Spotlight indexing' sudo mdutil -a -i off
    # tmutil disable needs Full Disk Access on macOS 15, and there is nothing to
    # disable when no backup disk is set up, which is always so in a new VM
    if tmutil destinationinfo 2>&1 | grep -q 'No destinations configured'; then
        skip 'Time Machine has no backup disk, so it does nothing'
    else
        tune 'Time Machine' sudo tmutil disable
    fi
    tune 'Time Machine disk offer' defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true

    # ---- updates ----
    # Point releases (15.x), security updates and system data files install by
    # themselves. These five keys are the toggles under System Settings >
    # General > Software Update > Automatic Updates.
    #
    # macOS never installs a major upgrade (15 to 26) by itself, whatever these
    # say: a major upgrade always needs "Upgrade Now". So nothing is set here to
    # stop one. There is also no way to hide the upgrade prompt on a Mac that is
    # not enrolled in MDM: `softwareupdate --ignore` stopped working for major
    # releases in 2020, and profile deferral is MDM only and ends after 90 days.
    step 'automatic updates: point releases on'
    SU=/Library/Preferences/com.apple.SoftwareUpdate
    for key in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do
        tune "SoftwareUpdate $key" sudo defaults write "$SU" "$key" -bool true
    done
    # there is no Apple ID in this VM, so App Store apps have nothing to update
    tune 'App Store auto update' sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

    # ---- prompts nobody can answer in a VM ----
    step 'prompts and dialogs'
    # no Bluetooth keyboard or mouse exists, so skip the "no keyboard" pairing window
    tune 'Bluetooth keyboard seek' sudo defaults write /Library/Preferences/com.apple.Bluetooth BluetoothAutoSeekKeyboard -int 0
    tune 'Bluetooth pointing seek' sudo defaults write /Library/Preferences/com.apple.Bluetooth BluetoothAutoSeekPointingDevice -int 0
    # a modal crash dialog blocks the web viewer; log the crash instead
    tune 'crash reporter dialog' defaults write com.apple.CrashReporter DialogType -string none
    # no Apple ID is signed in, so skip the iCloud, Siri and privacy prompts
    for key in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeAccessibilitySetup; do
        tune "SetupAssistant $key" defaults write com.apple.SetupAssistant "$key" -bool true
    done
    tune 'Siri' defaults write com.apple.assistant.support 'Assistant Enabled' -bool false

    # make the Dock, Finder and menu bar re-read what changed
    killall Dock Finder SystemUIServer >/dev/null 2>&1

    ok "$TUNE_OK settings applied"
    if [ "${#NOT_APPLIED[@]}" -gt 0 ]; then
        printf '%s    %d not applied (macOS refused them, or they do not exist on this release):%s\n' \
            "$C_NOTE" "${#NOT_APPLIED[@]}" "$C_OFF"
        for n in "${NOT_APPLIED[@]}"; do printf '%s      - %s%s\n' "$C_SKIP" "$n" "$C_OFF"; done
        note 'some settings were refused (listed above); macOS 15 blocks some of them from a script'
    fi
    note 'turn on Reduce transparency (and Reduce motion) in System Settings > Accessibility > Display: macOS 15 does not let a script do it'
    note 'log out and in (or reboot) so the scroll direction, the key repeat and reduce motion show'
    note 'point releases install by themselves and restart the VM; a major upgrade (macOS 26) never does, so do not click Upgrade Now'
fi

# ==============================================================================
#  phase 3: command line tools
# ==============================================================================

head_ 'phase 3: Xcode Command Line Tools'

if xcode-select -p >/dev/null 2>&1; then
    skip "already installed at $(xcode-select -p)"
else
    step 'looking for the Command Line Tools in Software Update'
    # this marker makes softwareupdate list the tools as an update
    CLT_MARKER=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    touch "$CLT_MARKER"
    CLT_LABEL="$(softwareupdate -l 2>/dev/null \
        | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^ *\*/ {print $2}' \
        | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort -V | tail -n 1)"
    if [ -n "$CLT_LABEL" ]; then
        step "installing: $CLT_LABEL"
        if sudo softwareupdate -i "$CLT_LABEL" --verbose 2>&1 | dim && xcode-select -p >/dev/null 2>&1; then
            ok 'Command Line Tools installed'
        else
            fail 'Command Line Tools install'
        fi
    else
        fail 'Command Line Tools not offered by Software Update (run: xcode-select --install, then run this script again)'
    fi
    rm -f "$CLT_MARKER"
fi

# ==============================================================================
#  phase 4: xcode
# ==============================================================================

# ver_ge <a> <b>: true if version a is the same as b or newer
ver_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

# newest Xcode app in the Applications folder, if any
find_xcode_app() {
    ls -d "$APPLICATIONS_DIR"/Xcode*.app 2>/dev/null | sort -V | tail -n 1
}

# xcode_version <file>: the version in a name such as Xcode_26.2_Universal.xip
xcode_version() {
    basename "$1" | sed -nE 's/^Xcode[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/p'
}

# why_xcode_wont_run <file>: prints the reason if the name shows that this Mac
# cannot run the Xcode, and nothing if it can. This only saves time: the check
# on the expanded app (can_run_xcode) is the one that decides.
why_xcode_wont_run() {
    local f="$1" ver
    ver="$(xcode_version "$f")"
    if [ "$ARCH" = x86_64 ]; then
        if printf '%s' "$f" | grep -qi 'apple.silicon'; then
            echo 'it is the Apple silicon download'
            return
        fi
        # Apple's release notes: "Xcode 27 will only install and run on Apple
        # silicon Macs"
        if [ -n "$ver" ] && ver_ge "$ver" 27; then
            echo 'Xcode 27 and newer run on Apple silicon only'
            return
        fi
    fi
    # Xcode 26.0 to 26.3 need macOS 15.6; Xcode 26.4 and newer need macOS 26.2
    if [ -n "$ver" ] && ver_ge "$ver" 26.4 && ! ver_ge "$OS_VERSION" 26.2; then
        echo "Xcode 26.4 and newer need macOS 26.2, and this is macOS $OS_VERSION"
        return
    fi
}

# The Xcode to install: XCODE_SOURCE, or the newest Xcode*.xip (then Xcode*.app)
# in the folder of this script or in /Volumes/shared. It sets XCODE_SRC. It does
# not print it, because a $(...) would run in a subshell and lose XCODE_PASSED_OVER.
#
# A file is passed over when its name shows that it cannot run on this Mac (see
# why_xcode_wont_run), so the script does not spend 40 minutes expanding it. What it
# passes over, and why, is left in XCODE_PASSED_OVER.
XCODE_SRC=''
XCODE_PASSED_OVER=''
find_xcode_source() {
    local dir kind f why best
    if [ -n "$XCODE_SOURCE" ]; then
        XCODE_SRC="$XCODE_SOURCE"
        return
    fi
    for dir in "$SCRIPT_DIR" /Volumes/shared; do
        for kind in xip app; do
            best=''
            # a loop on lines, so a name with a space (a browser can add one) works
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                why="$(why_xcode_wont_run "$f")"
                if [ -n "$why" ]; then
                    XCODE_PASSED_OVER="$XCODE_PASSED_OVER
      $(basename "$f"): $why"
                    continue
                fi
                best="$f"
            done < <(ls -d "$dir"/Xcode*."$kind" 2>/dev/null | sort -V)
            if [ -n "$best" ]; then
                XCODE_SRC="$best"
                return
            fi
        done
    done
}

# can_run_xcode <app>: this Mac must be new enough and the right kind of Mac. The
# app says what it needs itself, so no list of versions is kept here.
can_run_xcode() {
    local app="$1" need archs
    need="$(defaults read "$app/Contents/Info" LSMinimumSystemVersion 2>/dev/null)"
    if [ -n "$need" ] && ! ver_ge "$OS_VERSION" "$need"; then
        fail "$(basename "$app") needs macOS $need or newer, and this is macOS $OS_VERSION (use an older Xcode, or update macOS by hand)"
        return 1
    fi
    archs="$(lipo -archs "$app/Contents/MacOS/Xcode" 2>/dev/null)"
    if [ -n "$archs" ] && ! printf '%s' "$archs" | grep -qw "$ARCH"; then
        fail "$(basename "$app") is built for $archs only, and this Mac is $ARCH (use an older Xcode)"
        return 1
    fi
    return 0
}

if [ "$SKIP_XCODE" = 0 ]; then
    head_ 'phase 4: Xcode'

    XCODE_APP="$(find_xcode_app)"
    if [ -n "$XCODE_APP" ]; then
        skip "$(basename "$XCODE_APP") is already installed"
    else
        find_xcode_source
        if [ -z "$XCODE_SRC" ] && [ -n "$XCODE_PASSED_OVER" ]; then
            fail "no Xcode here can run on this Mac:$XCODE_PASSED_OVER
    Download Xcode 26.3 from developer.apple.com/download/all (the newest that runs on macOS 15), put it in the shared folder, and run this script again"
        elif [ -z "$XCODE_SRC" ]; then
            fail 'no Xcode_*.xip found. Download it from developer.apple.com/download/all (it needs your Apple ID), put it in the shared folder, and run this script again'
        elif [ ! -e "$XCODE_SRC" ]; then
            fail "XCODE_SOURCE $XCODE_SRC does not exist"
        else
            step "installing from $XCODE_SRC"

            # Expand on the local disk, not on the shared folder: the share is slow
            # and does not keep file attributes. Xcode needs about 15GB when
            # expanded and the .xip is as big again.
            XCODE_WORK="$HOME/xcode-install"
            mkdir -p "$XCODE_WORK"
            FREE_GB="$(df -k "$XCODE_WORK" | awk 'NR == 2 { print int($4 / 1048576) }')"
            NEW_APP=''
            REPORTED=0
            if [ "${FREE_GB:-0}" -lt 35 ]; then
                fail "only ${FREE_GB}GB of disk is free; Xcode needs about 35GB to expand"
                REPORTED=1
            else
                case "$XCODE_SRC" in
                    *.xip)
                        step 'expanding the .xip (this takes 15 to 40 minutes, and prints nothing until it ends)'
                        ( cd "$XCODE_WORK" && xip --expand "$XCODE_SRC" )
                        NEW_APP="$(ls -d "$XCODE_WORK"/Xcode*.app 2>/dev/null | sort -V | tail -n 1)"
                        ;;
                    *.app)
                        step 'copying the app (this takes a few minutes)'
                        NEW_APP="$XCODE_WORK/$(basename "$XCODE_SRC")"
                        ditto "$XCODE_SRC" "$NEW_APP"
                        ;;
                    *)
                        fail "do not know how to install $XCODE_SRC (use an Xcode_*.xip or an Xcode.app)"
                        REPORTED=1
                        ;;
                esac
            fi

            if [ -n "$NEW_APP" ] && [ -d "$NEW_APP" ]; then
                if can_run_xcode "$NEW_APP"; then
                    step "moving $(basename "$NEW_APP") to $APPLICATIONS_DIR"
                    if mv "$NEW_APP" "$APPLICATIONS_DIR/" 2>/dev/null || sudo mv "$NEW_APP" "$APPLICATIONS_DIR/"; then
                        XCODE_APP="$APPLICATIONS_DIR/$(basename "$NEW_APP")"
                        ok "$(basename "$XCODE_APP")"
                    else
                        fail "could not move $NEW_APP into $APPLICATIONS_DIR"
                    fi
                else
                    note "the expanded app is still in $XCODE_WORK (about 15GB); delete that folder when you do not need it"
                fi
            elif [ "$REPORTED" = 0 ]; then
                fail "no Xcode app came out of $XCODE_SRC (see the messages above)"
            fi
            # the work folder is empty once the app has moved out
            rmdir "$XCODE_WORK" 2>/dev/null
        fi
    fi

    if [ -n "$XCODE_APP" ]; then
        step 'pointing the developer tools at Xcode'
        if sudo xcode-select -s "$XCODE_APP/Contents/Developer"; then
            ok "xcode-select -> $XCODE_APP"
        else
            fail 'xcode-select --switch'
        fi

        # Without these, xcodebuild stops with a licence error and Xcode asks to
        # install components the first time it opens.
        step 'accepting the Xcode licence'
        sudo xcodebuild -license accept 2>&1 | dim
        XB_RC="${PIPESTATUS[0]}"
        if [ "$XB_RC" = 0 ]; then
            ok 'licence accepted'
        else
            fail 'xcodebuild -license accept'
        fi

        step 'running the Xcode first launch tasks'
        sudo xcodebuild -runFirstLaunch 2>&1 | dim
        XB_RC="${PIPESTATUS[0]}"
        if [ "$XB_RC" = 0 ]; then
            ok 'first launch tasks done'
        else
            fail 'xcodebuild -runFirstLaunch'
        fi

        XCODE_INFO="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        if [ -n "$XCODE_INFO" ]; then
            ok "$XCODE_INFO"
        else
            fail 'xcodebuild -version does not work'
        fi
        note 'simulators are not installed: add one with xcodebuild -downloadPlatform iOS (several GB)'
    fi
fi

# ==============================================================================
#  phase 5: homebrew
# ==============================================================================

head_ 'phase 5: Homebrew'

# Where Homebrew is set up by hand on an Intel Mac. This is Homebrew's own default
# prefix for Intel.
HOMEBREW_MANUAL_PREFIX="${HOMEBREW_MANUAL_PREFIX:-/usr/local}"

find_brew() {
    local b
    for b in /opt/homebrew/bin/brew "$HOMEBREW_MANUAL_PREFIX/bin/brew" /home/linuxbrew/.linuxbrew/bin/brew; do
        if [ -x "$b" ]; then echo "$b"; return 0; fi
    done
    command -v brew
}

# Homebrew's installer stops on an Intel Mac ("Homebrew on macOS is only supported
# on Apple Silicon processors!"), and it has no switch to allow one. brew itself
# still runs on Intel until 2027-09-01. So this does what the installer does for a
# standard install: the folders (owned by you), a clone of Homebrew/brew on its
# latest release, and a link to brew on the PATH.
install_homebrew_by_hand() {
    local prefix="$HOMEBREW_MANUAL_PREFIX" repo tag
    repo="$prefix/Homebrew"

    step "creating the Homebrew folders in $prefix (needs sudo)"
    sudo mkdir -p "$repo" "$prefix/Cellar" "$prefix/Caskroom" "$prefix/Frameworks" \
        "$prefix/bin" "$prefix/etc" "$prefix/include" "$prefix/lib" "$prefix/opt" \
        "$prefix/sbin" "$prefix/share" "$prefix/var" || return 1
    sudo chown "$USER:admin" "$prefix/bin" "$prefix/etc" "$prefix/include" "$prefix/lib" \
        "$prefix/opt" "$prefix/sbin" "$prefix/share" "$prefix/var" || return 1
    sudo chown -R "$USER:admin" "$repo" "$prefix/Cellar" "$prefix/Caskroom" "$prefix/Frameworks" || return 1

    if [ -d "$repo/.git" ]; then
        skip "Homebrew/brew is already cloned in $repo"
    else
        step 'cloning Homebrew/brew'
        git clone --quiet https://github.com/Homebrew/brew "$repo" || return 1
    fi

    tag="$(git -C "$repo" describe --abbrev=0 --tags --match '[0-9]*' 2>/dev/null)"
    if [ -n "$tag" ]; then
        git -C "$repo" checkout --quiet --force -B stable "$tag" || return 1
        ok "Homebrew $tag"
    fi
    ln -sf "$repo/bin/brew" "$prefix/bin/brew" || return 1
}

BREW="$(find_brew)"
if [ -n "$BREW" ]; then
    skip "already installed at $BREW"
elif [ "$ARCH" = arm64 ]; then
    step 'running the Homebrew installer'
    INSTALLER="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -z "$INSTALLER" ]; then
        fail 'could not download the Homebrew installer'
    else
        NONINTERACTIVE=1 /bin/bash -c "$INSTALLER" 2>&1 | dim
        BREW="$(find_brew)"
        if [ -n "$BREW" ]; then ok "installed at $BREW"; else fail 'Homebrew install'; fi
    fi
else
    step 'Homebrew has no installer for Intel Macs, so it is set up by hand'
    if install_homebrew_by_hand; then
        BREW="$(find_brew)"
        if [ -n "$BREW" ]; then ok "set up at $BREW"; else fail 'Homebrew set up by hand'; fi
    else
        fail 'Homebrew set up by hand'
    fi
fi

if [ -z "$BREW" ]; then
    fail 'no brew, skipping the casks'
    SKIP_CASKS=1
    [ "$PACKAGES" = homebrew ] && SKIP_FORMULAE=1
else
    # brew's environment for this run only; nothing is written to a profile
    eval "$("$BREW" shellenv)"
    export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1

    step 'brew update'
    "$BREW" update 2>&1 | dim
fi

# ----[ install helpers ]-------------------------------------------------------

# install_pkg <formula|cask> <name[|alternative...]>
install_pkg() {
    local kind="$1" spec="$2" alt name base flag

    case "$kind" in
        cask) flag=--cask ;;
        *)    flag=--formula ;;
    esac

    local IFS='|'
    for alt in $spec; do
        name="$alt"
        base="${name##*/}"
        if "$BREW" list "$flag" "$base" >/dev/null 2>&1; then
            skip "$base (already installed)"
            return 0
        fi
    done

    for alt in $spec; do
        step "installing $kind $alt"
        if "$BREW" install "$flag" "$alt" 2>&1 | dim && "$BREW" list "$flag" "${alt##*/}" >/dev/null 2>&1; then
            ok "$alt"
            return 0
        fi
    done
    fail "brew $kind $spec"
    return 1
}

# ==============================================================================
#  phase 6: command line tools
# ==============================================================================

MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
PORT="$MACPORTS_PREFIX/bin/port"

# the list of shells that login and ssh accept
SHELLS_FILE="${SHELLS_FILE:-/etc/shells}"

# set_default_shell <bash>: makes it this user's login shell. chsh asks for the
# password, so the shell is set with dscl, which sudo can do without asking. The
# shell must be in /etc/shells, or ssh and login can refuse it.
set_default_shell() {
    local sh="${DEFAULT_SHELL:-$1}" major current
    if [ "$SKIP_SHELL" = 1 ]; then
        return 0
    fi
    step "making $sh the login shell"

    if [ ! -x "$sh" ]; then
        fail "no bash at $sh, so the login shell is not changed"
        return 1
    fi
    major="$("$sh" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    case "$major" in
        ''|*[!0-9]*) fail "$sh does not run, so the login shell is not changed"; return 1 ;;
    esac
    # macOS ships bash 3.2; this must be a newer one
    if [ "$major" -lt 4 ]; then
        fail "$sh is bash $major, not a modern bash, so the login shell is not changed"
        return 1
    fi

    current="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{ print $2 }')"
    if [ "$current" = "$sh" ]; then
        skip "the login shell is already $sh"
        return 0
    fi

    if ! grep -qxF "$sh" "$SHELLS_FILE" 2>/dev/null; then
        if printf '%s\n' "$sh" | sudo tee -a "$SHELLS_FILE" >/dev/null; then
            ok "added $sh to $SHELLS_FILE"
        else
            fail "could not add $sh to $SHELLS_FILE"
            return 1
        fi
    fi

    sudo dscl . -create "/Users/$USER" UserShell "$sh" 2>&1 | dim
    current="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{ print $2 }')"
    if [ "$current" = "$sh" ]; then
        ok "the login shell of $USER is $sh (bash $major)"
        note "the login shell is now $sh. It applies to new Terminal windows and ssh logins. To go back to zsh: chsh -s /bin/zsh"
    else
        fail "could not set the login shell to $sh"
        return 1
    fi
}

# ----[ bash config ]----------------------------------------------------------

BASH_CONFIG_MARKER='MANAGED-BY-SETUP-MACOS'

# The text of ~/.bash_profile. Terminal and ssh start login shells, which read this
# file and not ~/.bashrc, so it only hands over to ~/.bashrc.
bash_profile_text() {
    cat <<'EOF'
# ~/.bash_profile
# MANAGED-BY-SETUP-MACOS: written by setup-macos.sh. If you remove the line above,
# the script will not change this file again. Put your own settings in ~/.bashrc.local.

# a login shell reads this file, not ~/.bashrc
if [ -r "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF
}

# The text of ~/.bashrc. It works with bash 3.2 as well as a modern bash. The PATH
# is worked out each time a shell starts, so it is right for Homebrew, MacPorts or
# both, whichever is installed.
bashrc_text() {
    cat <<'EOF'
# ~/.bashrc
# MANAGED-BY-SETUP-MACOS: written by setup-macos.sh. If you remove the line above,
# the script will not change this file again. Put your own settings in ~/.bashrc.local,
# which is read at the end and is never touched.

# ----[ PATH ]------------------------------------------------------------------
# This part runs for every bash, including `ssh host some-command`, so the tools
# are found there too.

path_prepend() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) [ -d "$1" ] && PATH="$1:$PATH" ;;
    esac
}

# Homebrew: /opt/homebrew on Apple silicon, /usr/local on Intel. `brew shellenv`
# adds to the PATH every time it runs, so it only runs when a parent shell has not
# already done it (a child shell inherits HOMEBREW_PREFIX and the PATH).
if [ -z "${HOMEBREW_PREFIX-}" ]; then
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$brew" ]; then
            eval "$("$brew" shellenv)"
            break
        fi
    done
fi
if [ -n "${HOMEBREW_PREFIX-}" ]; then
    path_prepend "$HOMEBREW_PREFIX/sbin"
    path_prepend "$HOMEBREW_PREFIX/bin"
fi

# MacPorts
path_prepend /opt/local/sbin
path_prepend /opt/local/bin

# The GNU tools under their plain names (ls, sed, tar, grep, ...) ahead of the BSD
# ones that macOS ships. Delete this part to get the macOS tools back.
if [ -n "${HOMEBREW_PREFIX-}" ]; then
    for pkg in coreutils findutils gnu-sed gnu-tar grep gnu-which gnu-indent make; do
        path_prepend "$HOMEBREW_PREFIX/opt/$pkg/libexec/gnubin"
    done
fi
path_prepend /opt/local/libexec/gnubin

# Go: go-setup.sh installs it in /usr/local/go, and `go install` puts programs in ~/go/bin
path_prepend /usr/local/go/bin
path_prepend "$HOME/go/bin"

export PATH

# ----[ interactive shells only ]-----------------------------------------------
case $- in
    *i*) ;;
    *) return 0 ;;
esac

# history: no duplicates, no commands that start with a space, and every shell adds to
# the file instead of replacing it
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend checkwinsize cmdhist

# the editor and the pager
if command -v nvim >/dev/null 2>&1; then
    EDITOR=nvim
else
    EDITOR=vim
fi
export EDITOR
export PAGER=less
export LESS='-R -I'

# color for ls and grep, with the GNU or the BSD option
if ls --color=auto / >/dev/null 2>&1; then
    alias ls='ls --color=auto'
else
    alias ls='ls -G'
fi
alias grep='grep --color=auto'
alias ll='ls -lh'
alias la='ls -lAh'

# completion, when Homebrew's bash-completion is installed
if [ -n "${HOMEBREW_PREFIX-}" ]; then
    if [ -r "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh" ]; then
        . "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
    elif [ -r "$HOMEBREW_PREFIX/etc/bash_completion" ]; then
        . "$HOMEBREW_PREFIX/etc/bash_completion"
    fi
fi

# prompt: user@host:directory$
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# your own settings
if [ -r "$HOME/.bashrc.local" ]; then
    . "$HOME/.bashrc.local"
fi
EOF
}

# write_managed_file <path> <function that prints the text>
#   absent                      -> written
#   written by this script      -> updated, if the text changed
#   anything else               -> left alone; the text goes next to it as <path>.setup-macos
write_managed_file() {
    local file="$1" text="$2"
    if [ ! -e "$file" ]; then
        if "$text" > "$file"; then ok "wrote $file"; else fail "could not write $file"; fi
    elif grep -q "$BASH_CONFIG_MARKER" "$file"; then
        if "$text" | cmp -s - "$file"; then
            skip "$file is already up to date"
        elif "$text" > "$file"; then
            ok "updated $file"
        else
            fail "could not update $file"
        fi
    else
        if "$text" > "$file.setup-macos"; then
            skip "$file exists and was not written by this script, so it is left alone"
            note "$file was not changed. This script's version is in $file.setup-macos; copy from it what you want"
        else
            fail "could not write $file.setup-macos"
        fi
    fi
}

install_bash_config() {
    step 'writing ~/.bash_profile and ~/.bashrc'
    write_managed_file "$HOME/.bash_profile" bash_profile_text
    write_managed_file "$HOME/.bashrc" bashrc_text
}

# The URL of the MacPorts installer for this macOS, from its latest release.
macports_installer_url() {
    local major="${OS_VERSION%%.*}" name
    case "$major" in
        13) name=Ventura ;;
        14) name=Sonoma ;;
        15) name=Sequoia ;;
        26) name=Tahoe ;;
        *) return 1 ;;
    esac
    curl -fsSL https://api.github.com/repos/macports/macports-base/releases/latest \
        | sed -n 's/.*"browser_download_url": *"\([^"]*-'"$major"'-'"$name"'\.pkg\)".*/\1/p' \
        | head -n 1
}

install_macports() {
    local url tmp profile_before profile_after
    url="$(macports_installer_url)"
    if [ -z "$url" ]; then
        fail "no MacPorts installer for macOS $OS_VERSION"
        return 1
    fi
    tmp="$(mktemp -d)"
    step "downloading $(basename "$url")"
    if ! curl -fsSL -o "$tmp/macports.pkg" "$url"; then
        fail "could not download $url"
        return 1
    fi
    if ! pkgutil --check-signature "$tmp/macports.pkg" 2>&1 | grep -q 'Status: signed'; then
        fail 'the MacPorts installer is not signed, so it is not installed'
        return 1
    fi

    # the MacPorts installer adds its folders to the PATH in your profile; see
    # whether it did, so the summary can say so
    profile_before="$(shasum "$HOME/.zprofile" 2>/dev/null)"
    step 'running the MacPorts installer'
    sudo installer -pkg "$tmp/macports.pkg" -target / 2>&1 | dim
    rm -f "$tmp/macports.pkg"
    rmdir "$tmp" 2>/dev/null
    profile_after="$(shasum "$HOME/.zprofile" 2>/dev/null)"
    if [ "$profile_before" != "$profile_after" ]; then
        note 'the MacPorts installer added /opt/local/bin to your ~/.zprofile (it does that itself)'
    fi

    if [ ! -x "$PORT" ]; then
        fail "MacPorts did not install ($PORT is missing)"
        return 1
    fi
    ok "MacPorts at $PORT"
}

# Ports that are too slow to build from source in a VM (compilers, languages, big
# frameworks). If the ready-made binary of one of these is missing, the port that
# needs it fails, instead of starting a build that takes hours.
SLOW_PORTS_RE='^(llvm|clang|gcc|libgcc|rust|go|ghc|nodejs|python|openjdk|qt|webkit|chromium|boost|ocaml|swift|emacs)'

# MacPorts builds Python with profile-guided optimization and LTO, which takes most of an
# hour. Without those two variants it builds in a few minutes and runs a little slower.
# Python is the one slow port that this script does build, because glib2, and with it
# wget, needs it, and macOS 15 on Intel has no ready-made binary of python313 or python314.
PYTHON_PORT_RE='^python3[0-9]+$'
PYTHON_PORT_VARIANTS='-lto -optimizations'

# install_port <port>: binary-only (-b), so a port with no ready-made binary fails at
# once. Without it, the port would compile from source for hours.
#
# A port's own binary can exist while the binary of something it depends on is missing
# (on macOS 15 Intel, openssl3 and bzip2 have none at all). MacPorts then stops with
# "Failed to archivefetch <name>". This builds that one dependency from source, when it
# is small, and tries the port again.
install_port() {
    local p="$1" log dep tries=0
    if [ -n "$("$PORT" -q installed "$p" 2>/dev/null)" ]; then
        skip "$p (already installed)"
        return 0
    fi
    step "installing port $p"
    log="$(mktemp)"
    while :; do
        sudo "$PORT" -N -b install "$p" 2>&1 | tee "$log" | dim
        if [ -n "$("$PORT" -q installed "$p" 2>/dev/null)" ]; then
            ok "$p"
            rm -f "$log"
            return 0
        fi

        dep="$(sed -n 's/.*Failed to archivefetch \([^:]*\):.*/\1/p' "$log" | head -n 1)"
        tries=$((tries + 1))
        if [ -z "$dep" ]; then
            fail "port $p (see the messages above)"
            break
        fi
        if printf '%s' "$dep" | grep -Eq "$PYTHON_PORT_RE"; then
            step "no ready-made binary of $dep for this macOS: building it from source without LTO and PGO (a few minutes), then trying $p again"
            # The binary-only try above stops half way through a +lto+optimizations build
            # and leaves it behind. MacPorts then refuses other variants ("do not match
            # those the build was started with"), so clear it first.
            sudo "$PORT" -N clean "$dep" 2>&1 | dim
            # shellcheck disable=SC2086
            sudo "$PORT" -N install "$dep" $PYTHON_PORT_VARIANTS 2>&1 | dim
            if [ -z "$("$PORT" -q installed "$dep" 2>/dev/null)" ]; then
                fail "port $dep (needed by $p) did not build"
                break
            fi
            [ "$tries" -gt 5 ] && { fail "port $p: still missing a ready-made binary after building $((tries - 1)) dependencies"; break; }
            continue
        fi
        if printf '%s' "$dep" | grep -Eq "$SLOW_PORTS_RE"; then
            fail "port $p: the ready-made binary of $dep is missing, and $dep is too slow to build here"
            break
        fi
        if [ "$tries" -gt 5 ]; then
            fail "port $p: still missing a ready-made binary after building $((tries - 1)) dependencies"
            break
        fi

        step "no ready-made binary of $dep for this macOS: building $dep from source, then trying $p again"
        sudo "$PORT" -N install "$dep" 2>&1 | dim
        if [ -z "$("$PORT" -q installed "$dep" 2>/dev/null)" ]; then
            fail "port $dep (needed by $p) did not build"
            break
        fi
    done
    rm -f "$log"
    return 1
}

if [ "$SKIP_FORMULAE" = 0 ]; then
    if [ "$PACKAGES" = homebrew ]; then
        head_ 'phase 6: command line tools (Homebrew)'
        if [ "$ARCH" = x86_64 ]; then
            printf '%s    Homebrew has no Intel bottles for macOS 15: most formulae build from\n    source here, which takes hours. PACKAGES=hybrid avoids that.%s\n' "$C_NOTE" "$C_OFF"
        fi
        for p in "${FORMULAE[@]}"; do
            install_pkg formula "$p"
        done
        # brew is at <prefix>/bin/brew, and the bash formula is at <prefix>/bin/bash
        [ -n "$BREW" ] && set_default_shell "${BREW%/bin/brew}/bin/bash"
    else
        head_ 'phase 6: command line tools (MacPorts)'
        if [ -x "$PORT" ]; then
            skip "MacPorts is already installed at $PORT"
            MACPORTS_OK=1
        elif install_macports; then
            MACPORTS_OK=1
        fi

        if [ "${MACPORTS_OK:-0}" = 1 ]; then
            step 'updating the ports tree'
            sudo "$PORT" -N selfupdate 2>&1 | dim
            for p in "${PORTS[@]}"; do
                install_port "$p"
            done
            note "MacPorts tools are in $MACPORTS_PREFIX/bin. GNU tools are installed with a g prefix (gls, gsed); put $MACPORTS_PREFIX/libexec/gnubin first on your PATH for the plain names"
            note 'left out with MacPorts: gnu-getopt (no port), git (use Apple git), gh and iproute2mac (no binary), bash-completion'
            set_default_shell "$MACPORTS_PREFIX/bin/bash"
            # MacPorts puts its folders on the PATH in ~/.zprofile, which only zsh
            # reads. The ~/.bashrc that this script writes adds them for bash; this
            # note is only for a run with --skip-bashrc.
            if [ "$SKIP_SHELL" = 0 ] && [ "$SKIP_BASHRC" = 1 ]; then
                note "bash does not read ~/.zprofile, so $MACPORTS_PREFIX/bin is not on its PATH until your ~/.bash_profile or bashrc adds $MACPORTS_PREFIX/bin (and $MACPORTS_PREFIX/libexec/gnubin for the plain GNU names)"
            fi
        fi
    fi
fi

if [ "$SKIP_BASHRC" = 0 ]; then
    install_bash_config
fi

# ==============================================================================
#  phase 7: casks
# ==============================================================================

if [ "$SKIP_CASKS" = 0 ]; then
    head_ 'phase 7: casks'
    for p in "${CASKS[@]}"; do
        install_pkg cask "$p"
    done

    # Homebrew downloads a cask and macOS marks the app as quarantined, so the
    # first launch asks "are you sure you want to open it". Homebrew removed
    # --no-quarantine, so clear the flag after the install. This is limited to the
    # apps in CASK_APPS. It is not the same as `spctl --master-disable`, which
    # turns Gatekeeper off for everything.
    step 'clearing the quarantine flag so the apps open without a prompt'
    for name in "${CASK_APPS[@]}"; do
        app="$APPLICATIONS_DIR/$name.app"
        if [ ! -d "$app" ]; then
            skip "$name is not installed"
            continue
        fi
        # xattr -l lists the flags, and it is the check: xattr -d exits with an
        # error on a file that has no flag
        xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1
        if xattr -lr "$app" 2>/dev/null | grep -q 'com.apple.quarantine'; then
            sudo xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1
        fi
        if xattr -lr "$app" 2>/dev/null | grep -q 'com.apple.quarantine'; then
            fail "could not clear the quarantine flag on $name"
        else
            ok "$name opens without a prompt"
        fi
    done

    # ---- Firefox is the default browser, and nothing asks about a first run ----
    if [ "$SKIP_BROWSERS" = 0 ]; then
        step 'default browser: Firefox'
        if [ -d "$APPLICATIONS_DIR/Firefox.app" ]; then
            set_default_browser org.mozilla.firefox
        else
            skip 'Firefox is not installed'
        fi
        set_firefox_policies
        set_chrome_policies
    fi
fi

# ==============================================================================
#  phase 8: default wallpaper
# ==============================================================================

# Why this phase exists: since Sonoma the aerial wallpapers (Landscape,
# Cityscape, Underwater, Earth and their shuffle) and anything stored as a
# .madesktop file need Metal 3D acceleration. This VM has no GPU, so they draw
# as a white or black screen. A still image, such as a HEIC, PNG or JPEG,
# always draws.
#
# The default wallpaper of each release is a still image. Apple keeps a symlink
# to it, so the script follows the link and no file name is fixed here (it is
# "Sequoia Sunrise" on macOS 15).
DEFAULT_DESKTOP="${DEFAULT_DESKTOP:-/System/Library/CoreServices/DefaultDesktop.heic}"

# with_timeout <seconds> <command...>: bash 3.2 has no timeout command, and
# osascript waits forever on a permission prompt that nobody sees
with_timeout() {
    local secs="$1" pid killer rc
    shift
    "$@" &
    pid=$!
    # the killer must not share our stdout, or a $(...) around this function
    # waits for its sleep to end
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    killer=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill "$killer" 2>/dev/null
    return $rc
}

if [ "$SKIP_WALLPAPER" = 0 ]; then
    head_ 'phase 8: default wallpaper'

    WALLPAPER=''
    if [ -n "$WALLPAPER_FILE" ]; then
        if [ -r "$WALLPAPER_FILE" ]; then
            WALLPAPER="$WALLPAPER_FILE"
            skip "using $WALLPAPER (WALLPAPER_FILE)"
        else
            fail "WALLPAPER_FILE $WALLPAPER_FILE is not readable"
        fi
    elif [ -e "$DEFAULT_DESKTOP" ]; then
        WALLPAPER="$(realpath "$DEFAULT_DESKTOP" 2>/dev/null)"
        [ -n "$WALLPAPER" ] || WALLPAPER="$DEFAULT_DESKTOP"
        step "the default wallpaper of macOS $OS_VERSION is $WALLPAPER"
    else
        fail "no default wallpaper at $DEFAULT_DESKTOP (set one in System Settings > Wallpaper > Pictures)"
    fi

    # an aerial is a video or a .madesktop file; only a still image is safe here
    if [ -n "$WALLPAPER" ]; then
        case "$(printf '%s' "$WALLPAPER" | tr '[:upper:]' '[:lower:]')" in
            *.heic|*.jpg|*.jpeg|*.png) ;;
            *)
                fail "$WALLPAPER is not a still image (heic, jpg or png), so it may need a GPU"
                WALLPAPER=''
                ;;
        esac
    fi

    if [ -n "$WALLPAPER" ]; then
        step 'setting the wallpaper on every display'
        APPLIED=0
        if command -v desktoppr >/dev/null 2>&1; then
            desktoppr "$WALLPAPER" 2>&1 | dim
            # desktoppr with no arguments prints the current wallpaper
            case "$(desktoppr 2>/dev/null)" in
                *"$(basename "$WALLPAPER")"*) APPLIED=1; ok 'desktoppr set the wallpaper' ;;
                *) skip 'desktoppr did not report the new wallpaper' ;;
            esac
        else
            skip 'desktoppr is not installed'
        fi

        if [ "$APPLIED" = 0 ]; then
            step 'trying osascript (this may raise an Automation prompt: click Allow)'
            # the status comes from osascript itself, not from a pipe into dim
            OSA_OUT="$(with_timeout 30 osascript -e "tell application \"System Events\" to set picture of every desktop to \"$WALLPAPER\"" 2>&1)"
            OSA_RC=$?
            [ -n "$OSA_OUT" ] && printf '%s\n' "$OSA_OUT" | dim
            if [ "$OSA_RC" = 0 ]; then
                APPLIED=1
                ok 'osascript set the wallpaper'
            else
                fail 'could not set the wallpaper (set it in System Settings > Wallpaper > Pictures)'
            fi
        fi

        if [ "$APPLIED" = 1 ]; then
            # since Sonoma the wallpaper is drawn by its own daemon, which
            # caches the old choice; launchd starts it again at once
            killall WallpaperAgent >/dev/null 2>&1
        fi
    fi

    # idleassetsd downloads the aerial videos, 600MB to 1.5GB each, into this
    # folder. They are a cache that macOS fetches again if it needs them.
    AERIALS='/Library/Application Support/com.apple.idleassetsd/Customer'
    if [ -d "$AERIALS" ]; then
        step "removing downloaded aerial videos ($(du -sh "$AERIALS" 2>/dev/null | cut -f1))"
        if sudo find "$AERIALS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
            ok 'aerial video cache removed'
        else
            skip 'could not remove the aerial video cache'
        fi
    else
        skip 'no aerial videos have been downloaded'
    fi

    note 'the wallpaper is a still image on purpose; pick only Pictures or Colors in System Settings > Wallpaper, never an aerial'
fi

# ==============================================================================
#  phase 9: dock
# ==============================================================================

# a Dock tile for an app. Type 0 takes a plain path, so a space in "Google
# Chrome.app" needs no escaping.
dock_app_tile() {
    printf '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>%s</string><key>_CFURLStringType</key><integer>0</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>' "$1"
}

# a Dock tile for a folder, shown as a Folder icon (displayas 1) that opens as a
# Grid (showas 2). $2 is the sort: 1 name, 2 date added, 3 date modified,
# 4 date created, 5 kind.
dock_folder_tile() {
    printf '<dict><key>tile-data</key><dict><key>arrangement</key><integer>%s</integer><key>displayas</key><integer>1</integer><key>file-data</key><dict><key>_CFURLString</key><string>file://%s</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-type</key><integer>2</integer><key>showas</key><integer>2</integer></dict><key>tile-type</key><string>directory-tile</string></dict>' "$2" "${1// /%20}"
}

if [ "$SKIP_DOCK" = 0 ]; then
    head_ 'phase 9: dock'

    # Writing both lists replaces whatever the Dock held, so everything else
    # (Launchpad, Safari, Mail, ...) goes. Finder and the Trash cannot be removed
    # from the Dock, and a running app shows there until it quits.
    #
    # dockutil would do this, but Homebrew has no Intel bottle of it for macOS 15,
    # so it would build from source.
    step 'choosing the apps'
    DOCK_APPS=()
    for app in \
        "$SYSTEM_APPLICATIONS_DIR/System Settings.app" \
        "$APPLICATIONS_DIR/Firefox.app" \
        "$APPLICATIONS_DIR/Google Chrome.app" \
        "$APPLICATIONS_DIR/iTerm.app" \
        "$SYSTEM_APPLICATIONS_DIR/App Store.app"; do
        if [ -d "$app" ]; then
            DOCK_APPS+=("$(dock_app_tile "$app")")
            ok "$(basename "$app" .app)"
        else
            fail "$app is not installed, so it is left out of the Dock"
        fi
    done

    mkdir -p "$HOME/Downloads"

    step 'writing the Dock'
    if defaults write com.apple.dock persistent-apps -array "${DOCK_APPS[@]}" \
        && defaults write com.apple.dock persistent-others -array \
            "$(dock_folder_tile "$APPLICATIONS_DIR" 1)" \
            "$(dock_folder_tile "$HOME/Downloads" 2)"; then
        ok "${#DOCK_APPS[@]} apps, then Applications and Downloads as folders shown as a grid"
    else
        fail 'could not write the Dock preferences'
    fi

    # the Dock reads its preferences again when it starts
    killall Dock >/dev/null 2>&1
fi

# ==============================================================================
#  phase 10: ssh
# ==============================================================================

if [ "$SKIP_SSH" = 0 ]; then
    head_ 'phase 10: ssh'

    ssh_listening() { nc -z 127.0.0.1 22 >/dev/null 2>&1; }

    step 'turning on Remote Login'
    if ssh_listening; then
        skip 'sshd is already listening on port 22'
    else
        # needs Full Disk Access for the terminal on recent macOS, so it can fail
        sudo systemsetup -setremotelogin on 2>&1 | dim
        if ! ssh_listening; then
            step 'systemsetup did not work, loading the sshd launchd job directly'
            sudo launchctl enable system/com.openssh.sshd 2>&1 | dim
            sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>&1 | dim
            sleep 2
        fi
        if ssh_listening; then
            ok 'sshd is listening on port 22'
        else
            fail 'Remote Login (turn it on in System Settings > General > Sharing > Remote Login)'
        fi
    fi

    step 'authorizing the public key'
    case "$PUBLIC_KEY" in
        ssh-*|ecdsa-*)
            mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
            AK="$HOME/.ssh/authorized_keys"
            touch "$AK" && chmod 600 "$AK"
            if grep -qxF "$PUBLIC_KEY" "$AK"; then
                skip "key already in $AK"
            else
                # start on a new line if the file does not end with one
                [ -s "$AK" ] && [ -n "$(tail -c 1 "$AK")" ] && echo >> "$AK"
                echo "$PUBLIC_KEY" >> "$AK"
                ok "key -> $AK"
            fi
            note "authorized key installed for $USER"
            ;;
        *)
            fail "public key does not look like a key: '$PUBLIC_KEY'"
            ;;
    esac

    note 'ssh reaches the VM from the host with: ssh -p 2223 <user>@127.0.0.1'
fi

# ==============================================================================
#  phase 11: go
#  Last, because go-setup.sh builds Go from source, which takes several minutes.
# ==============================================================================

GO_SETUP_URL="${GO_SETUP_URL:-https://raw.githubusercontent.com/kenshaw/shell-config/HEAD/scripts/go-setup.sh}"
GO_DEST="${GO_DEST:-/usr/local}"

# first_executable <path>...: prints the first one that is an executable file
first_executable() {
    local p
    for p in "$@"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# prepare_go_environment: sets GO_BASH, GO_GNU_DIR and GO_PATH.
#
# go-setup.sh reads the Go download page with `sed -E` regular expressions that use
# `.+?`, which the BSD sed of macOS cannot parse, and it expects GNU tools (its own
# header says: brew install curl gawk gnu-sed). So it runs with the bash that was just
# installed, and with a PATH that starts with GNU sed and awk (linked, under the plain
# names, into a folder of their own, so this does not depend on how Homebrew or MacPorts
# name theirs) and then the GNU coreutils folders.
prepare_go_environment() {
    local hb mp sed_bin awk_bin candidate dir
    hb="${BREW%/bin/brew}"
    mp="$MACPORTS_PREFIX"

    if [ "$PACKAGES" = homebrew ] && [ -n "$hb" ]; then
        candidate="$hb/bin/bash"
    else
        candidate="$mp/bin/bash"
    fi
    GO_BASH="$(first_executable "${DEFAULT_SHELL:-}" "$candidate")"
    if [ -z "$GO_BASH" ]; then
        GO_BASH=/bin/bash
        note 'go-setup.sh ran with the bash 3.2 that ships with macOS, because no newer bash was found'
    fi

    sed_bin="$(first_executable "$hb/opt/gnu-sed/libexec/gnubin/sed" "$hb/bin/gsed" "$mp/bin/gsed")"
    awk_bin="$(first_executable "$hb/bin/gawk" "$mp/bin/gawk")"
    if [ -z "$sed_bin" ]; then
        fail 'no GNU sed found, and go-setup.sh needs it (install gnu-sed with Homebrew, or gsed with MacPorts)'
        return 1
    fi

    GO_GNU_DIR="$(mktemp -d)"
    ln -s "$sed_bin" "$GO_GNU_DIR/sed"
    [ -n "$awk_bin" ] && ln -s "$awk_bin" "$GO_GNU_DIR/awk"

    GO_PATH="$GO_GNU_DIR"
    for dir in "$hb/opt/coreutils/libexec/gnubin" "$mp/libexec/gnubin"; do
        [ -d "$dir" ] && GO_PATH="$GO_PATH:$dir"
    done
    GO_PATH="$GO_PATH:$PATH"

    ok "bash $GO_BASH, sed $sed_bin${awk_bin:+, awk $awk_bin}"
}

# fetch_go_setup: sets GO_SETUP_FILE. It runs as root, so it must be a bash script that
# parses; a web page, or an error message from a proxy, is not run.
fetch_go_setup() {
    local tmp
    if [ -n "${GO_SETUP_SCRIPT:-}" ]; then
        GO_SETUP_FILE="$GO_SETUP_SCRIPT"
        step "using $GO_SETUP_FILE (GO_SETUP_SCRIPT)"
    elif [ -f "$SCRIPT_DIR/go-setup.sh" ]; then
        GO_SETUP_FILE="$SCRIPT_DIR/go-setup.sh"
        step "using $GO_SETUP_FILE (next to this script)"
    else
        tmp="$(mktemp -d)"
        GO_SETUP_FILE="$tmp/go-setup.sh"
        step "downloading go-setup.sh from $GO_SETUP_URL"
        if ! curl -fsSL -o "$GO_SETUP_FILE" "$GO_SETUP_URL"; then
            fail "could not download $GO_SETUP_URL"
            return 1
        fi
    fi

    if [ ! -s "$GO_SETUP_FILE" ] || ! head -n 1 "$GO_SETUP_FILE" | grep -q '^#!.*bash'; then
        fail "$GO_SETUP_FILE is not a bash script, so it is not run"
        return 1
    fi
    if ! "$GO_BASH" -n "$GO_SETUP_FILE" 2>/dev/null; then
        fail "$GO_SETUP_FILE does not parse as bash, so it is not run"
        return 1
    fi
    ok "go-setup.sh, sha256 $(shasum -a 256 "$GO_SETUP_FILE" | cut -c1-16)..."
}

install_go() {
    local go_version args
    go_version="$("$GO_DEST/go/bin/go" version 2>/dev/null)"
    if [ -n "$go_version" ] && [ "$UPDATE_GO" = 0 ]; then
        skip "Go is already installed ($go_version); --update-go runs go-setup.sh again"
        return 0
    fi

    prepare_go_environment || return 1
    fetch_go_setup || return 1

    # -u: update (go-setup.sh refuses to do anything without it); -f: no "not root" check,
    # since sudo sets USER to root and the script compares it
    args=(-u -f)
    [ "$GO_DEST" != /usr/local ] && args+=(-d "$GO_DEST")

    step "running: sudo env PATH=... $GO_BASH go-setup.sh ${args[*]}  (this builds Go; it takes several minutes)"
    # `env PATH=...` because sudo does not keep the PATH. The curl progress bars end in
    # carriage returns, so they are split and dropped; the RETRIEVING lines stay.
    sudo env "PATH=$GO_PATH" "$GO_BASH" "$GO_SETUP_FILE" "${args[@]}" 2>&1 \
        | tr '\r' '\n' | grep -v -E '^#+ +[0-9.]+%$|^ *$' | dim

    go_version="$("$GO_DEST/go/bin/go" version 2>/dev/null)"
    if [ -n "$go_version" ]; then
        ok "$go_version"
        if [ "$SKIP_BASHRC" = 0 ]; then
            note "Go is in $GO_DEST/go/bin. The ~/.bashrc this script wrote puts it on your PATH (open a new terminal)"
        else
            note "Go is in $GO_DEST/go/bin; add it to your PATH"
        fi
    else
        fail "go-setup.sh did not leave a working $GO_DEST/go/bin/go (see the messages above)"
    fi

    # the folder of links is only for that run
    rm -f "${GO_GNU_DIR:?}/sed" "${GO_GNU_DIR:?}/awk"
    rmdir "$GO_GNU_DIR" 2>/dev/null
}

if [ "$SKIP_GO" = 0 ]; then
    head_ 'phase 11: Go'
    install_go
fi

# ==============================================================================
#  summary
# ==============================================================================

head_ 'summary'

ELAPSED=$(( $(date +%s) - STARTED ))
printf '    elapsed: %02d:%02d\n' $((ELAPSED / 60)) $((ELAPSED % 60))

if [ "${#NOTES[@]}" -gt 0 ]; then
    printf '\n%s    notes:%s\n' "$C_HEAD" "$C_OFF"
    for n in "${NOTES[@]}"; do printf '      - %s\n' "$n"; done
fi

if [ "${#FAILURES[@]}" -eq 0 ]; then
    printf '\n%s    everything succeeded%s\n' "$C_OK" "$C_OFF"
else
    printf '\n%s    %d step(s) failed:%s\n' "$C_FAIL" "${#FAILURES[@]}" "$C_OFF"
    for f in "${FAILURES[@]}"; do printf '%s      - %s%s\n' "$C_FAIL" "$f" "$C_OFF"; done
    printf '\n%s    If a Homebrew name has moved, search for the new one with: brew search <name>%s\n' "$C_NOTE" "$C_OFF"
    printf '%s    then run this script again. It skips what is already done.%s\n' "$C_NOTE" "$C_OFF"
fi

printf '\n%s    open a new terminal to pick up the new tools.%s\n\n' "$C_NOTE" "$C_OFF"

[ "${#FAILURES[@]}" -eq 0 ]
