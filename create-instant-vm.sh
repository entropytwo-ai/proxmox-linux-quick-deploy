#!/usr/bin/env bash
#
# create-instant-vm.sh — Instantly deploy pre-configured Linux VMs on Proxmox VE.
#
# Downloads an official cloud image once, bakes login credentials into it with
# virt-customize (cached per OS), then creates and boots a new VM from it.
#
# Nothing is installed, downloaded or created on the hypervisor until you have
# seen the plan and confirmed it. Run with --check first for a dry run.
#
# Project: https://github.com/entropytwo-ai/proxmox-linux-quick-deploy
# License: MIT
#
# Every setting below can be overridden from the environment, e.g.:
#   CACHE_DIR=/mnt/pve/nas/cloud-images MEMORY=4096 OS_CHOICE=1 ./create-instant-vm.sh
set -e

# --- CONFIGURATION (override any of these via environment variables) ---
DISK_SIZE="${DISK_SIZE:-20G}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
DEFAULT_USER="${DEFAULT_USER:-admin}"
DEFAULT_PASS="${DEFAULT_PASS:-password123}"
FALLBACK_CACHE_DIR="/var/lib/vz/template/iso/cloud-images"
STORAGE_CFG="${STORAGE_CFG:-/etc/pve/storage.cfg}"
ASSUME_YES="${ASSUME_YES:-0}"
# CACHE_DIR    : where cloud images are cached (auto-detected if unset)
# VM_STORAGE   : Proxmox storage for VM disks (auto-detected if unset)
# BRIDGE       : network bridge (auto-detected if unset, defaults to vmbr0)
# OS_CHOICE    : 1-10 to skip the interactive menu
# ASSUME_YES   : 1 to answer "yes" to every confirmation (same as --yes)
# -----------------------------------------------------------------------

# Host packages this script may install, as "command:package" pairs.
REQUIRED_PKGS=("virt-customize:libguestfs-tools" "wget:wget" "curl:curl")

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Create a ready-to-login Linux VM on this Proxmox VE host.

Options:
  -c, --check   Dry run: report what is installed, what would be installed,
                where images are cached and where VM disks will go. Changes
                nothing on the host and exits (0 = ready, 1 = action needed).
  -y, --yes     Don't ask for confirmation (package install + VM creation).
                Required when no terminal is available.
  -h, --help    Show this help.

Environment overrides: CACHE_DIR VM_STORAGE BRIDGE OS_CHOICE DISK_SIZE
MEMORY CORES DEFAULT_USER DEFAULT_PASS ASSUME_YES
USAGE
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check) CHECK_ONLY=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "[!] Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- Helpers ---
# Ask a yes/no question on the controlling terminal (works with bash <(curl ...)).
# $1 = prompt, $2 = default answer (y|n). Returns 0 for yes.
confirm() {
    local prompt="$1" default="${2:-n}" reply hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    if [[ "$ASSUME_YES" == "1" ]]; then
        echo "$prompt $hint y  (auto-confirmed by --yes)"
        return 0
    fi
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        echo "[!] $prompt — no terminal available to ask. Re-run with --yes to confirm." >&2
        return 1
    fi
    read -r -u 3 -p "$prompt $hint " reply || reply=""
    exec 3<&-
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# KiB -> human readable
human_kib() { awk -v k="$1" 'BEGIN { split("KiB MiB GiB TiB PiB", u); i=1; while (k>=1024 && i<5) { k/=1024; i++ } printf "%.1f %s", k, u[i] }'; }

# Free space at a path (walks up to the nearest existing parent).
free_space_at() {
    local p="$1"
    while [[ ! -e "$p" && "$p" != "/" ]]; do p=$(dirname "$p"); done
    df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Print the filesystem 'path' of a storage from /etc/pve/storage.cfg (empty if
# the storage has no path, e.g. lvmthin/zfspool/rbd).
storage_cfg_path() {
    awk -v name="$1" '
        /^[a-zA-Z0-9_-]+:[ \t]+/ { in_block = ($2 == name); next }
        in_block && $1 == "path" { print $2; exit }
    ' "$STORAGE_CFG" 2>/dev/null
}

# Resolve a storage name to a directory on disk: storage.cfg first, then
# 'pvesm path' as a second opinion (only trusted if it yields a directory).
resolve_storage_dir() {
    local storage="$1" path probe
    path=$(storage_cfg_path "$storage")
    if [[ -z "$path" ]]; then
        probe=$(pvesm path "${storage}:iso/probe.iso" 2>/dev/null || true)
        # .../template/iso/probe.iso  ->  storage root
        if [[ "$probe" == /*/template/iso/probe.iso ]]; then
            path="${probe%/template/iso/probe.iso}"
        fi
    fi
    if [[ -n "$path" && -d "$path" ]]; then echo "$path"; fi
}

# "type available-KiB" for a storage from 'pvesm status'.
storage_info() { pvesm status 2>/dev/null | awk -v s="$1" 'NR>1 && $1==s {print $2, $6; exit}'; }

# Actually launch the libguestfs appliance — proves the kernel, supermin
# appliance and qemu are usable, not just that the binary is on PATH.
guestfs_runtime_ok() {
    command -v libguestfs-test-tool &>/dev/null || return 1
    libguestfs-test-tool -t 180 &>/dev/null
}

# --- Pre-flight: environment ---
PREFLIGHT_ERRORS=()
if [[ $EUID -ne 0 ]]; then
    PREFLIGHT_ERRORS+=("Not running as root (required for qm/pvesm/apt-get).")
fi
for _cmd in qm pvesm pvesh; do
    if ! command -v "$_cmd" &>/dev/null; then
        PREFLIGHT_ERRORS+=("'$_cmd' not found — this must run on a Proxmox VE node.")
    fi
done
if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 && "$CHECK_ONLY" != "1" ]]; then
    printf '[!] %s\n' "${PREFLIGHT_ERRORS[@]}" >&2
    exit 1
fi

# --- Auto-detect cloud-image cache directory from Proxmox storage ---
# Order: active 'images' storages with a filesystem path -> active 'iso'
# storages -> $FALLBACK_CACHE_DIR. Override by exporting CACHE_DIR.
CACHE_SOURCE="set via CACHE_DIR"
if [[ -z "${CACHE_DIR:-}" ]]; then
    _STORAGE_PATH=""
    for _content in images iso; do
        while read -r _storage; do
            [[ -z "$_storage" ]] && continue
            _STORAGE_PATH=$(resolve_storage_dir "$_storage" || true)
            if [[ -n "$_STORAGE_PATH" ]]; then
                CACHE_SOURCE="auto-detected from Proxmox storage '$_storage' (content: $_content)"
                break 2
            fi
        done < <(pvesm status -content "$_content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    done
    if [[ -n "$_STORAGE_PATH" ]]; then
        CACHE_DIR="${_STORAGE_PATH%/}/cloud-images"
    else
        CACHE_SOURCE="default (no file-based Proxmox storage detected)"
        CACHE_DIR="$FALLBACK_CACHE_DIR"
    fi
fi

# --- Target VM storage & network ---
if [[ -n "${VM_STORAGE:-}" ]]; then
    STORAGE="$VM_STORAGE"; STORAGE_SOURCE="set via VM_STORAGE"
else
    STORAGE=$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
    STORAGE_SOURCE="first active storage with 'images' content"
fi
read -r STORAGE_TYPE STORAGE_AVAIL <<<"$(storage_info "$STORAGE")"
if [[ -n "${BRIDGE:-}" ]]; then
    BRIDGE_SOURCE="set via BRIDGE"
else
    BRIDGE=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2; exit}')
    BRIDGE_SOURCE="first Linux bridge"
    [[ -z "$BRIDGE" ]] && { BRIDGE="vmbr0"; BRIDGE_SOURCE="default, no bridge detected"; }
fi

# --- Dependency inventory (nothing is changed here) ---
MISSING_PKGS=()
DEP_LINES=()
for _pair in "${REQUIRED_PKGS[@]}"; do
    _cmd="${_pair%%:*}"; _pkg="${_pair#*:}"
    if command -v "$_cmd" &>/dev/null; then
        DEP_LINES+=("  [ok]      $_cmd  ($_pkg)")
    else
        DEP_LINES+=("  [missing] $_cmd  ($_pkg)  -> will be installed with apt-get")
        MISSING_PKGS+=("$_pkg")
    fi
done

# Ask apt what installing the missing packages would pull in (read-only).
apt_preview() {
    local sim
    sim=$(apt-get install -s "$@" 2>/dev/null | awk '/^Inst /{print $2}' | sort -u | tr '\n' ' ')
    if [[ -n "$sim" ]]; then
        echo "  apt would install $(wc -w <<<"$sim") package(s) in total (incl. dependencies):"
        fold -s -w 74 <<<"$sim" | sed 's/^/    /'
    else
        echo "  (could not simulate the install — package lists may be stale; 'apt-get update' runs first)"
    fi
    apt-get install --assume-no "$@" 2>/dev/null \
        | grep -E '^(Need to get|After this operation)' | sed 's/^/  /' || true
}

print_locations() {
    echo "Where things will go:"
    echo "  Image cache (downloads + customized images):"
    echo "    $CACHE_DIR"
    echo "    ($CACHE_SOURCE)"
    if [[ -d "$CACHE_DIR" ]]; then
        echo "    exists, $(human_kib "$(free_space_at "$CACHE_DIR")") free"
    else
        echo "    does NOT exist yet — will be created ($(human_kib "$(free_space_at "$CACHE_DIR")") free on that filesystem)"
    fi
    if [[ -n "$STORAGE" ]]; then
        echo "  VM disks / EFI disk / cloud-init drive:"
        echo "    Proxmox storage '$STORAGE' (type: ${STORAGE_TYPE:-unknown}${STORAGE_AVAIL:+, $(human_kib "$STORAGE_AVAIL") available})"
        echo "    ($STORAGE_SOURCE)"
    else
        echo "  VM disks: [!] no active Proxmox storage with 'images' content found — set VM_STORAGE=<name>"
    fi
    echo "  Network bridge: $BRIDGE ($BRIDGE_SOURCE)"
}

# --- --check: report and exit without touching anything ---
if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "=== Pre-flight check (dry run — nothing will be changed) ==="
    _rc=0
    echo "Environment:"
    if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
        printf '  [!] %s\n' "${PREFLIGHT_ERRORS[@]}"; _rc=1
    else
        echo "  [ok]      root on a Proxmox VE node (qm, pvesm, pvesh found)"
    fi
    echo "Host packages:"
    printf '%s\n' "${DEP_LINES[@]}"
    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        _rc=1
        echo "  Would run: apt-get update && apt-get install -y ${MISSING_PKGS[*]}"
        apt_preview "${MISSING_PKGS[@]}"
    elif command -v virt-customize &>/dev/null; then
        echo "  Testing libguestfs appliance (boots a tiny VM, may take up to a minute)..."
        if guestfs_runtime_ok; then
            echo "  [ok]      libguestfs appliance boots — virt-customize is functional"
        else
            echo "  [!]       libguestfs appliance failed to boot. The script would offer to run"
            echo "            'update-guestfs-appliance'. Diagnose with: libguestfs-test-tool"
            _rc=1
        fi
    fi
    echo
    print_locations
    [[ -z "$STORAGE" ]] && _rc=1
    if [[ -d "$CACHE_DIR" ]]; then
        echo
        echo "Already cached images in $CACHE_DIR:"
        _found=0
        for _f in "$CACHE_DIR"/*.qcow2 "$CACHE_DIR"/*.img; do
            [[ -f "$_f" ]] || continue
            _found=1
            echo "  $(du -h "$_f" | cut -f1)  $(basename "$_f")"
        done
        [[ "$_found" == "0" ]] && echo "  (none)"
    fi
    echo
    if [[ "$_rc" == "0" ]]; then
        echo "✅ Ready. Run without --check to create a VM."
    else
        echo "⚠️  Action needed (see above). The script will ask before installing anything."
    fi
    exit "$_rc"
fi

# --- Install missing host packages (only with explicit consent) ---
FRESH_INSTALL=0
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "=================================================================="
    echo "⚠️  This script needs software that is not installed on this"
    echo "    Proxmox hypervisor:"
    printf '%s\n' "${DEP_LINES[@]}"
    echo
    echo "  It will run:"
    echo "    apt-get update"
    echo "    apt-get install -y ${MISSING_PKGS[*]}"
    apt_preview "${MISSING_PKGS[@]}"
    echo "=================================================================="
    if ! confirm "Install these packages on the Proxmox host now?" n; then
        echo "[*] Nothing was installed. To install manually, run:"
        echo "    apt-get update && apt-get install -y ${MISSING_PKGS[*]}"
        exit 1
    fi
    apt-get update
    apt-get install -y "${MISSING_PKGS[@]}"
    FRESH_INSTALL=1
fi

# --- Verify every required command is now present ---
for _pair in "${REQUIRED_PKGS[@]}"; do
    _cmd="${_pair%%:*}"
    if ! command -v "$_cmd" &>/dev/null; then
        echo "[!] '$_cmd' is still not available after installation. Aborting." >&2
        exit 1
    fi
done

# --- Verify virt-customize actually works ---
# Quick check every run; full appliance boot test right after a fresh install.
_guestfs_ok=1
if ! virt-customize --version &>/dev/null; then
    _guestfs_ok=0
elif [[ "$FRESH_INSTALL" == "1" ]]; then
    echo "[*] Verifying the libguestfs appliance boots (first run only, may take a minute)..."
    guestfs_runtime_ok || _guestfs_ok=0
fi
if [[ "$_guestfs_ok" == "0" ]]; then
    echo "[!] virt-customize is installed but not functional."
    echo "    Fix attempt: 'update-guestfs-appliance' (rebuilds the libguestfs appliance"
    echo "    under /usr/lib/x86_64-linux-gnu/guestfs on this host)."
    if confirm "Run update-guestfs-appliance now?" y; then
        update-guestfs-appliance || true
    fi
    if ! virt-customize --version &>/dev/null || ! guestfs_runtime_ok; then
        echo "[!] ERROR: virt-customize is not functional. Please check libguestfs installation." >&2
        echo "    Diagnose with: libguestfs-test-tool" >&2
        exit 1
    fi
fi

if [[ -z "$STORAGE" ]]; then
    echo "[!] No active Proxmox storage with 'images' content found. Set VM_STORAGE=<name>." >&2
    exit 1
fi

echo "=== Instant Proxmox VM Creator (Guaranteed Login!) ==="
if [[ -z "${OS_CHOICE:-}" ]]; then
    echo "Select an OS to deploy instantly:"
    echo "  [1] Ubuntu 24.04 LTS (Noble)"
    echo "  [2] Ubuntu 26.04 Daily (Resolute)"
    echo "  [3] Debian 12 (Bookworm)"
    echo "  [4] Debian 13 (Trixie)"
    echo "  [5] Fedora 41 Cloud"
    echo "  [6] Arch Linux"
    echo "  [7] Omarchy (Arch + Omarchy Ready)"
    echo "  [8] NixOS (Unstable VM)"
    echo "  [9] Rocky Linux 9 (RHEL Clone)"
    echo "  [10] Alpine Linux (Ultra-lightweight)"
    echo ""
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -u 3 -p "Select OS (1-10): " OS_CHOICE || true
        exec 3<&-
    else
        echo "[!] No terminal available. Set OS_CHOICE=1..10." >&2
        exit 1
    fi
fi

BOOT_TYPE="bios"
OS_TYPE="standard"

case "$OS_CHOICE" in
    1)
        OS_LABEL="Ubuntu 24.04 LTS (Noble)"
        IMG_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
        IMG_URL="https://cloud-images.ubuntu.com/noble/current/${IMG_NAME}"
        ;;
    2)
        OS_LABEL="Ubuntu 26.04 Daily (Resolute)"
        IMG_NAME="resolute-server-cloudimg-amd64.img"
        IMG_URL="https://cloud-images.ubuntu.com/resolute/current/${IMG_NAME}"
        ;;
    3)
        OS_LABEL="Debian 12 (Bookworm)"
        IMG_NAME="debian-12-generic-amd64.qcow2"
        IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${IMG_NAME}"
        ;;
    4)
        OS_LABEL="Debian 13 (Trixie)"
        IMG_NAME="debian-13-generic-amd64.qcow2"
        IMG_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/${IMG_NAME}"
        ;;
    5)
        OS_LABEL="Fedora 41 Cloud"
        IMG_NAME="Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
        IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/${IMG_NAME}"
        ;;
    6)
        OS_LABEL="Arch Linux"
        IMG_NAME="Arch-Linux-x86_64-cloudimg.qcow2"
        IMG_URL="https://geo.mirror.pkgbuild.com/images/latest/${IMG_NAME}"
        ;;
    7)
        OS_LABEL="Omarchy (Arch + Omarchy Ready)"
        IMG_NAME="Arch-Linux-x86_64-cloudimg.qcow2"
        IMG_URL="https://geo.mirror.pkgbuild.com/images/latest/${IMG_NAME}"
        OS_TYPE="omarchy"
        # Omarchy needs more headroom; only raise values the user didn't override.
        if [[ "$MEMORY" -lt 4096 ]]; then MEMORY="4096"; fi
        if [[ "$DISK_SIZE" == "20G" ]]; then DISK_SIZE="32G"; fi
        ;;
    8)
        OS_LABEL="NixOS (Unstable VM)"
        echo "[*] Finding latest NixOS qcow2 build..."
        BASE_NIX_URL="https://images.linuxcontainers.org/images/nixos/unstable/amd64/default/"
        LATEST_DIR=$(curl -fsSL "$BASE_NIX_URL" | grep -oE '[0-9]{8}_[0-9]{2}(%3A|:)[0-9]{2}/' | tail -n 1 || true)
        if [[ -z "$LATEST_DIR" ]]; then
            echo "[!] Could not determine the latest NixOS build from $BASE_NIX_URL" >&2
            exit 1
        fi
        IMG_NAME="nixos-unstable-disk.qcow2"
        IMG_URL="${BASE_NIX_URL}${LATEST_DIR}disk.qcow2"
        OS_TYPE="nixos"
        BOOT_TYPE="uefi"
        ;;
    9)
        OS_LABEL="Rocky Linux 9"
        IMG_NAME="Rocky-9-GenericCloud.latest.x86_64.qcow2"
        IMG_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/${IMG_NAME}"
        ;;
    10)
        OS_LABEL="Alpine Linux 3.21"
        IMG_NAME="generic_alpine-3.21.2-x86_64-bios-cloudinit-r0.qcow2"
        IMG_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/${IMG_NAME}"
        ;;
    *)
        echo "[!] Invalid choice: '$OS_CHOICE'" >&2
        exit 1
        ;;
esac

RAW_IMG_PATH="${CACHE_DIR}/${IMG_NAME}"
if [[ "$OS_TYPE" == "omarchy" ]]; then
    READY_IMG_PATH="${CACHE_DIR}/ready-omarchy-${IMG_NAME}"
else
    READY_IMG_PATH="${CACHE_DIR}/ready-${IMG_NAME}"
fi

EXISTING_NAMES=$(qm list 2>/dev/null | awk 'NR>1 {print $2}')
Counter=1
while echo "$EXISTING_NAMES" | grep -q "^Linux-New-${Counter}$"; do
    ((Counter++))
done
VM_NAME="Linux-New-${Counter}"
VM_ID=$(pvesh get /cluster/nextid)

# --- Show the full plan and ask before changing anything ---
echo
echo "=================================================================="
echo " Deployment plan: $OS_LABEL"
echo "=================================================================="
print_locations
echo
echo "Cloud image:"
if [[ -f "$RAW_IMG_PATH" ]]; then
    echo "  [cached]   $RAW_IMG_PATH"
else
    echo "  [download] $IMG_URL"
    echo "          -> $RAW_IMG_PATH"
fi
if [[ -f "$READY_IMG_PATH" ]]; then
    echo "  [cached]   customized image: $READY_IMG_PATH"
else
    echo "  [create]   customized image: $READY_IMG_PATH"
    echo "             (copy of the cloud image with credentials/SSH baked in via virt-customize)"
fi
echo
echo "New VM:"
echo "  ID / name : $VM_ID / $VM_NAME"
echo "  Resources : $CORES cores, $MEMORY MiB RAM, ${DISK_SIZE} disk on '$STORAGE'"
echo "  Boot      : $BOOT_TYPE$([[ "$BOOT_TYPE" == "uefi" ]] && echo " (OVMF + EFI disk on '$STORAGE')")"
if [[ "$OS_TYPE" != "nixos" ]]; then
    echo "  Cloud-init: drive on '$STORAGE', DHCP on $BRIDGE"
else
    echo "  Network   : DHCP on $BRIDGE (NixOS native, no cloud-init drive)"
fi
echo "  Login     : $DEFAULT_USER / root, password '$DEFAULT_PASS'"
echo "  Starts automatically after creation."
echo "=================================================================="
if ! confirm "Proceed with this plan?" y; then
    echo "[*] Aborted. Nothing was downloaded or created."
    exit 0
fi

mkdir -p "$CACHE_DIR"

if [[ ! -f "$RAW_IMG_PATH" ]]; then
    echo "[*] Downloading $IMG_URL"
    echo "    -> $RAW_IMG_PATH"
    # Download to a temp name so an interrupted transfer never poisons the cache.
    if ! wget -q --show-progress "$IMG_URL" -O "${RAW_IMG_PATH}.part"; then
        rm -f "${RAW_IMG_PATH}.part"
        echo "[!] Download failed: $IMG_URL" >&2
        exit 1
    fi
    mv "${RAW_IMG_PATH}.part" "$RAW_IMG_PATH"
fi

if [[ ! -f "$READY_IMG_PATH" ]]; then
    echo "[*] Baking credentials & config into $READY_IMG_PATH (happens once per OS)..."
    # Bake into a temp file; only promote it to the cache when customization succeeds.
    WORK_IMG="${READY_IMG_PATH}.part"
    cp "$RAW_IMG_PATH" "$WORK_IMG"
    trap 'rm -f "$WORK_IMG"' EXIT

    if [[ "$OS_TYPE" == "nixos" ]]; then
        NIX_TMP=$(mktemp)
        cat << NIXEOF > "$NIX_TMP"
{ config, pkgs, ... }:
{
  users.users.root.initialPassword = "${DEFAULT_PASS}";
  users.users.${DEFAULT_USER} = {
    isNormalUser = true;
    initialPassword = "${DEFAULT_PASS}";
    extraGroups = [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };
  services.qemuGuest.enable = true;
}
NIXEOF
        virt-customize -a "$WORK_IMG" \
            --upload "${NIX_TMP}:/etc/nixos/proxmox-user.nix" \
            --run-command "sed -i 's|imports = \[|imports = [ ./proxmox-user.nix |' /etc/nixos/configuration.nix" \
            --root-password "password:${DEFAULT_PASS}"
        rm -f "$NIX_TMP"

    elif [[ "$OS_TYPE" == "omarchy" ]]; then
        virt-customize -a "$WORK_IMG" \
            --root-password "password:${DEFAULT_PASS}" \
            --run-command "id -u ${DEFAULT_USER} &>/dev/null || useradd -m -s /bin/bash -G wheel ${DEFAULT_USER}" \
            --password "${DEFAULT_USER}:password:${DEFAULT_PASS}" \
            --run-command "echo '${DEFAULT_USER} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${DEFAULT_USER}" \
            --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config" \
            --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config" \
            --run-command "echo -e '#!/bin/bash\nset -e\nsudo pacman -Sy --noconfirm git curl\nwget -qO- https://omarchy.org/install | bash' > /home/${DEFAULT_USER}/install-omarchy.sh" \
            --run-command "chmod +x /home/${DEFAULT_USER}/install-omarchy.sh && chown ${DEFAULT_USER}:${DEFAULT_USER} /home/${DEFAULT_USER}/install-omarchy.sh" \
            --run-command "echo 'echo \"👉 Run ./install-omarchy.sh to launch the Omarchy installer!\"' >> /home/${DEFAULT_USER}/.bashrc"
    else
        virt-customize -a "$WORK_IMG" \
            --root-password "password:${DEFAULT_PASS}" \
            --run-command "id -u ${DEFAULT_USER} &>/dev/null || useradd -m -s /bin/bash -G sudo,adm ${DEFAULT_USER} 2>/dev/null || useradd -m -s /bin/bash -G wheel ${DEFAULT_USER}" \
            --password "${DEFAULT_USER}:password:${DEFAULT_PASS}" \
            --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true" \
            --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true" \
            --run-command "rm -f /etc/ssh/sshd_config.d/*cloudimg*.conf 2>/dev/null || true"
    fi
    mv "$WORK_IMG" "$READY_IMG_PATH"
    trap - EXIT
else
    echo "[*] Using cached ready image: $READY_IMG_PATH"
fi

echo "[*] Creating VM $VM_ID ($VM_NAME) on storage '$STORAGE' (bridge: $BRIDGE)..."

qm create "$VM_ID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --serial0 socket

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    qm set "$VM_ID" --bios ovmf
    qm set "$VM_ID" --efidisk0 "${STORAGE}:1,pre-enrolled-keys=0"
fi

echo "[*] Importing disk into '$STORAGE'..."
qm set "$VM_ID" --scsi0 "${STORAGE}:0,import-from=${READY_IMG_PATH},iothread=1,discard=on"
qm disk resize "$VM_ID" scsi0 "$DISK_SIZE"

if [[ "$OS_TYPE" != "nixos" ]]; then
    qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
    qm set "$VM_ID" --ciuser "$DEFAULT_USER"
    qm set "$VM_ID" --cipassword "$DEFAULT_PASS"
    qm set "$VM_ID" --ipconfig0 ip=dhcp
fi
qm set "$VM_ID" --boot order=scsi0

echo "[*] Starting $VM_NAME ($VM_ID)..."
qm start "$VM_ID"

echo "===================================================="
echo "✅ Success! $VM_NAME (ID: $VM_ID) is booting!"
echo "👤 Login as : $DEFAULT_USER  (or 'root')"
echo "🔑 Password : $DEFAULT_PASS"
echo "💾 Disk     : storage '$STORAGE'   Image cache: $CACHE_DIR"
if [[ "$OS_TYPE" == "omarchy" ]]; then
    echo "🚀 Omarchy  : Log in as '$DEFAULT_USER' and run: ./install-omarchy.sh"
fi
echo "⚠️  Change the default password after first login!"
echo "===================================================="
