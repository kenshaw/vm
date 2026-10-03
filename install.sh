#!/bin/bash

# install.sh - run the VMs as systemd user services, and start them with this computer
#
# usage: ./install.sh <vm>... [--start] [--yes] [--dry-run]
#        ./install.sh <vm>... --uninstall [--yes]
#
#   <vm>         macos15, win11, or all
#   --start      start the service now (it starts by itself from the next boot)
#   --yes        do not ask questions
#   --dry-run    show the unit that would be installed, and change nothing
#   --uninstall  stop the service and remove its unit. The VM disk is kept.
#
# What it does, for each VM:
#
#   1. fills in systemd/<unit>.container.in and checks the result with Podman's own
#      Quadlet generator (a dry run, which changes nothing)
#   2. puts it in ~/.config/containers/systemd/<unit>.container, which Quadlet turns
#      into the systemd user service <unit>.service
#   3. makes systemd read it (daemon-reload)
#
# and once, for the user:
#
#   4. turns on lingering (loginctl enable-linger), so the user's services start at
#      boot and keep running with nobody logged in
#
# The VMs run as you, in rootless Podman. Nothing here needs root, except that
# enable-linger may ask for it on a system that does not let a user do it.
#
# The service replaces launch-macos.sh and launch-windows.sh for running the VM, with
# the same settings. Do not run both at once: they use the same VM disk. This script
# offers to remove a container that a launcher made.
#
# These can be set in the environment, for one VM at a time:
#   RAM_SIZE  CPU_CORES  DISK_SIZE  VERSION  WEB_PORT  SSH_PORT
#   VNC_PORT (macos15)  RDP_PORT (win11)  DISK_FMT (raw or qcow2)
#   WIN_USERNAME (win11, default: user)  WIN_PASSWORD (win11, default: the image's "admin")
#
# The Windows account is made when Windows is installed. Changing it here does nothing for
# a Windows that is already installed. A WIN_PASSWORD is written into the unit file, which
# is then readable only by you.

set -e

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$HERE/systemd"
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
KVM_DEVICE="${KVM_DEVICE:-/dev/kvm}"
ME="$(id -un)"

usage() {
    awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

step() { printf '>>> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }

confirm() {
    local answer
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " answer
    case "$answer" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ----[ arguments ]-------------------------------------------------------------

VMS=()
START=0
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        macos15|win11) VMS+=("$arg") ;;
        all)           VMS+=(macos15 win11) ;;
        --start)       START=1 ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --uninstall)   UNINSTALL=1 ;;
        -h|--help)     usage ;;
        *) die "unknown argument '$arg' (try --help)" ;;
    esac
done
[ "${#VMS[@]}" -gt 0 ] || usage 1

# macos15 twice is the same as once
UNIQUE=()
for vm in "${VMS[@]}"; do
    seen=0
    for u in "${UNIQUE[@]}"; do [ "$u" = "$vm" ] && seen=1; done
    [ "$seen" = 0 ] && UNIQUE+=("$vm")
done
VMS=("${UNIQUE[@]}")

# a setting in the environment is for one VM: macos15 and win11 do not share defaults
if [ "${#VMS[@]}" -gt 1 ]; then
    for v in RAM_SIZE CPU_CORES DISK_SIZE VERSION WEB_PORT SSH_PORT VNC_PORT RDP_PORT DISK_FMT WIN_USERNAME WIN_PASSWORD; do
        [ -z "${!v:-}" ] || die "$v is set, and more than one VM is named. Install them one at a time to change a setting."
    done
fi

# ----[ the VMs ]---------------------------------------------------------------

# load_vm <vm>: sets the unit name, the folder and the settings for it
# quadlet_env <name> <value>: an Environment= line. Two layers read the value:
#   - Quadlet reads it the way systemd does, so a value with a space is quoted, and a
#     backslash or a double quote in it is escaped;
#   - then Quadlet copies it into ExecStart, where systemd expands "%x" as a specifier and
#     "$x" as an environment variable. Quadlet does not escape those, so % and $ are
#     doubled here, and systemd turns %% and $$ back into one character.
# Without the doubling, a password such as 'pa$$word' or '100%' would change when the
# service starts.
quadlet_env() {
    local value
    value="$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')"
    printf 'Environment="%s=%s"\n' "$1" "$value"
}

load_vm() {
    V_EXTRA_ENV=""
    V_HAS_SECRET=0
    case "$1" in
        macos15)
            UNIT=macos15
            DIR="$HERE/macos15"
            DATA=macos-data
            V_VERSION="${VERSION:-15}"
            V_DISK_SIZE="${DISK_SIZE:-100G}"
            V_RAM_SIZE="${RAM_SIZE:-16G}"
            V_CPU_CORES="${CPU_CORES:-8}"
            # the windows11 container holds 8006 and 2222, so macOS uses other ports
            V_WEB_PORT="${WEB_PORT:-8007}"
            V_VNC_PORT="${VNC_PORT:-5900}"
            V_SSH_PORT="${SSH_PORT:-2223}"
            V_RDP_PORT=""
            if [ -n "${DISK_FMT:-}" ]; then
                V_EXTRA_ENV="$(quadlet_env DISK_FMT "$DISK_FMT")"
            fi
            ;;
        win11)
            UNIT=windows11
            DIR="$HERE/win11"
            DATA=windows-data
            V_VERSION="${VERSION:-11}"
            V_DISK_SIZE="${DISK_SIZE:-128G}"
            V_RAM_SIZE="${RAM_SIZE:-16G}"
            V_CPU_CORES="${CPU_CORES:-8}"
            V_WEB_PORT="${WEB_PORT:-8006}"
            V_RDP_PORT="${RDP_PORT:-3389}"
            V_SSH_PORT="${SSH_PORT:-2222}"
            V_VNC_PORT=""
            # the account that the Windows install creates
            V_EXTRA_ENV="$(quadlet_env USERNAME "${WIN_USERNAME:-user}")"
            if [ -n "${WIN_PASSWORD:-}" ]; then
                case "$WIN_PASSWORD" in
                    *$'\n'*) die "WIN_PASSWORD cannot contain a new line" ;;
                esac
                V_EXTRA_ENV="$V_EXTRA_ENV"$'\n'"$(quadlet_env PASSWORD "$WIN_PASSWORD")"
                V_HAS_SECRET=1
            fi
            if [ -n "${DISK_FMT:-}" ]; then
                V_EXTRA_ENV="$V_EXTRA_ENV"$'\n'"$(quadlet_env DISK_FMT "$DISK_FMT")"
            fi
            ;;
    esac
}

# sed_escape <text>: text that is safe on the right-hand side of s|...|...|
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# render: prints the unit for the loaded VM
render() {
    local template="$TEMPLATES/$UNIT.container.in"
    [ -f "$template" ] || die "missing template $template"
    sed \
        -e "s|@DIR@|$(sed_escape "$DIR")|g" \
        -e "s|@VERSION@|$(sed_escape "$V_VERSION")|g" \
        -e "s|@DISK_SIZE@|$(sed_escape "$V_DISK_SIZE")|g" \
        -e "s|@RAM_SIZE@|$(sed_escape "$V_RAM_SIZE")|g" \
        -e "s|@CPU_CORES@|$(sed_escape "$V_CPU_CORES")|g" \
        -e "s|@WEB_PORT@|$(sed_escape "$V_WEB_PORT")|g" \
        -e "s|@VNC_PORT@|$(sed_escape "$V_VNC_PORT")|g" \
        -e "s|@RDP_PORT@|$(sed_escape "$V_RDP_PORT")|g" \
        -e "s|@SSH_PORT@|$(sed_escape "$V_SSH_PORT")|g" \
        "$template" | EXTRA="$V_EXTRA_ENV" awk '
            $0 == "@EXTRA_ENV@" { if (ENVIRON["EXTRA"] != "") print ENVIRON["EXTRA"]; next }
            { print }'
}

# ----[ checks ]----------------------------------------------------------------

find_generator() {
    local g
    for g in /usr/lib/podman/quadlet /usr/libexec/podman/quadlet \
        /usr/lib/systemd/user-generators/podman-user-generator; do
        if [ -x "$g" ]; then echo "$g"; return 0; fi
    done
    return 1
}

# validate <folder>: Podman's Quadlet generator turns the .container files in the folder
# into units, in a dry run. It fails on a key it does not know or a value it cannot read.
validate() {
    local gen out
    gen="$(find_generator)" || { skip "no Quadlet generator found, so the unit is not checked"; return 0; }
    if ! out="$(QUADLET_UNIT_DIRS="$1" "$gen" --user --dryrun 2>&1)"; then
        printf '%s\n' "$out" >&2
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -q '^ExecStart=.*podman run'; then
        printf '%s\n' "$out" >&2
        return 1
    fi
    if printf '%s\n' "$out" | grep -i -E 'warning|unsupported|invalid' >&2; then
        return 1
    fi
}

preflight() {
    [ "$(id -u)" != 0 ] || die "do not run this as root. The VMs run as your own user, in rootless Podman."
    command -v podman >/dev/null 2>&1 || die "podman is not installed or not in PATH."
    command -v systemctl >/dev/null 2>&1 || die "systemctl is not installed."

    # Quadlet came with Podman 4.4
    local ver major minor
    ver="$(podman --version | sed -n 's/^podman version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    major="${ver%%.*}"
    minor="${ver#*.}"
    if [ -n "$ver" ] && { [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 4 ]; }; }; then
        die "podman $ver is too old for Quadlet (4.4 or newer)."
    fi

    [ -e "$KVM_DEVICE" ] || die "$KVM_DEVICE not found. KVM acceleration is required."
    { [ -r "$KVM_DEVICE" ] && [ -w "$KVM_DEVICE" ]; } || die "you cannot read and write $KVM_DEVICE. Add yourself to the kvm group (sudo usermod -aG kvm $ME), then log in again."

    # "degraded" only means some unrelated unit failed
    systemctl --user show-environment >/dev/null 2>&1 \
        || die "there is no systemd user session here. Log in at the console or over ssh, so that XDG_RUNTIME_DIR is set."
}

# ----[ install ]---------------------------------------------------------------

# a container made by launch-*.sh has the same name as the service's, and uses the same VM disk
adopt_existing_container() {
    podman container exists "$UNIT" 2>/dev/null || return 0
    # a container that the service itself started is not in the way
    if systemctl --user is-active --quiet "$UNIT.service" 2>/dev/null; then
        return 0
    fi
    echo "    A container named $UNIT exists (made by the launcher script). It uses the same VM disk"
    echo "    as the service, so only one of them may run."
    if confirm "    Stop it (a clean shutdown, up to 2 minutes) and remove it? The VM disk is kept."; then
        podman stop --time 120 "$UNIT" >/dev/null 2>&1 || true
        podman rm --force "$UNIT" >/dev/null
        ok "removed the container $UNIT"
    else
        die "left the container $UNIT in place; the service was not installed for it."
    fi
}

# first_install_ram: an AMD host must not give a macOS install more than 8 GB (the image's
# documentation says so), the same rule launch-macos.sh uses
apply_install_ram_rule() {
    [ "$UNIT" = macos15 ] || return 0
    [ -z "${RAM_SIZE:-}" ] || return 0
    grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null || return 0
    if [ -z "$(find "$DIR/$DATA" -type f -name 'data.*' 2>/dev/null | head -n 1)" ]; then
        V_RAM_SIZE=8G
        echo "    macOS is not installed yet, and this is an AMD host: the service gets 8G of RAM for the install."
        echo "    After macOS is installed, run ./install.sh macos15 again to move to 16G."
    fi
}

install_vm() {
    local vm="$1" tmp target
    load_vm "$vm"
    step "$vm: service $UNIT.service"
    apply_install_ram_rule

    tmp="$(mktemp -d)"
    render > "$tmp/$UNIT.container"

    if [ "$DRY_RUN" = 1 ]; then
        echo "    The unit that would be installed as $QUADLET_DIR/$UNIT.container:"
        echo
        sed 's/^/        /' "$tmp/$UNIT.container"
        echo
        validate "$tmp" && ok "Podman's Quadlet generator accepts it" || { rm -rf "${tmp:?}"; die "the generator rejects the unit"; }
        rm -rf "${tmp:?}"
        return 0
    fi

    validate "$tmp" || { rm -rf "${tmp:?}"; die "Podman's Quadlet generator rejects the unit for $vm (see above); nothing was installed."; }
    ok "Podman's Quadlet generator accepts the unit"

    # Podman fails to start a container whose bind mount does not exist
    mkdir -p "$DIR/$DATA" "$DIR/shared"

    adopt_existing_container

    mkdir -p "$QUADLET_DIR"
    target="$QUADLET_DIR/$UNIT.container"
    if [ -f "$target" ] && cmp -s "$tmp/$UNIT.container" "$target"; then
        skip "$target is already up to date"
    else
        local changed=0
        [ -f "$target" ] && changed=1
        cp "$tmp/$UNIT.container" "$target"
        if [ "$V_HAS_SECRET" = 1 ]; then chmod 600 "$target"; fi
        ok "wrote $target"
        if [ "$changed" = 1 ] && systemctl --user is-active --quiet "$UNIT.service" 2>/dev/null; then
            echo "    The service is running with the old settings. Restart it to use the new ones:"
            echo "        systemctl --user restart $UNIT.service      (this restarts the VM)"
        fi
    fi
    rm -rf "${tmp:?}"
    INSTALLED+=("$vm")
}

# ensure_linger: lets the user's services start at boot, and keep running when nobody is logged in
ensure_linger() {
    local state
    state="$(loginctl show-user "$ME" -p Linger --value 2>/dev/null || true)"
    if [ "$state" = yes ]; then
        skip "lingering is already on for $ME"
        return 0
    fi
    if loginctl enable-linger "$ME" 2>/dev/null; then
        ok "turned on lingering for $ME, so the VMs start at boot"
    else
        echo "    Could not turn on lingering. Without it, the VMs start only after you log in. Run:"
        echo "        sudo loginctl enable-linger $ME"
        LINGER_MISSING=1
    fi
}

INSTALLED=()
LINGER_MISSING=0

do_install() {
    preflight
    local vm unit
    for vm in "${VMS[@]}"; do
        install_vm "$vm"
    done
    [ "$DRY_RUN" = 1 ] && { echo; echo "Dry run: nothing was changed."; return 0; }

    step "reading the new units"
    systemctl --user daemon-reload
    for vm in "${INSTALLED[@]}"; do
        load_vm "$vm"
        if systemctl --user cat "$UNIT.service" >/dev/null 2>&1; then
            ok "$UNIT.service exists ($(systemctl --user is-enabled "$UNIT.service" 2>/dev/null || echo unknown))"
        else
            die "systemd did not make $UNIT.service from $QUADLET_DIR/$UNIT.container. Run: /usr/lib/podman/quadlet --user --dryrun"
        fi
    done

    step "starting at boot"
    ensure_linger

    if [ "$START" = 1 ]; then
        for vm in "${INSTALLED[@]}"; do
            load_vm "$vm"
            step "starting $UNIT.service (the first start downloads the image, which can take minutes)"
            systemctl --user start "$UNIT.service"
            ok "$UNIT.service started"
        done
    fi

    echo
    echo "Done."
    for vm in "${INSTALLED[@]}"; do
        load_vm "$vm"
        echo
        echo "  $UNIT.service"
        echo "    start:   systemctl --user start $UNIT.service"
        echo "    stop:    systemctl --user stop $UNIT.service        (a clean shutdown, up to 2.5 minutes)"
        echo "    status:  systemctl --user status $UNIT.service"
        echo "    log:     journalctl --user -u $UNIT.service -f"
    done
    echo
    if [ "$LINGER_MISSING" = 1 ]; then
        echo "  Starts at boot: NOT YET (see lingering above)."
    else
        echo "  Starts at boot: yes."
    fi
    echo "  Use these, not the launch scripts, to start and stop the VMs from now on."
}

# ----[ uninstall ]-------------------------------------------------------------

do_uninstall() {
    command -v systemctl >/dev/null 2>&1 || die "systemctl is not installed."
    local vm target removed=0
    for vm in "${VMS[@]}"; do
        load_vm "$vm"
        target="$QUADLET_DIR/$UNIT.container"
        step "$vm: removing $UNIT.service"
        if [ ! -f "$target" ]; then
            skip "$target does not exist"
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            skip "would stop $UNIT.service and remove $target"
            continue
        fi
        if systemctl --user is-active --quiet "$UNIT.service" 2>/dev/null; then
            confirm "    $UNIT.service is running. Stop it (a clean shutdown, up to 2.5 minutes)?" || die "left $UNIT.service running."
            systemctl --user stop "$UNIT.service"
            ok "stopped $UNIT.service"
        fi
        rm -f "${target:?}"
        ok "removed $target"
        removed=1
    done
    if [ "$removed" = 1 ]; then
        systemctl --user daemon-reload
        ok "systemd has read the change"
    fi
    echo
    echo "The VM disks in macos15/macos-data and win11/windows-data were not touched."
    echo "Lingering was left on; turn it off with: loginctl disable-linger $ME"
}

if [ "$UNINSTALL" = 1 ]; then
    do_uninstall
else
    do_install
fi
