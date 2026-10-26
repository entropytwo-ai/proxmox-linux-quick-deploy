#!/usr/bin/env bash
#
# create-instant-vm.sh — Instantly deploy pre-configured Linux VMs on Proxmox VE.
#
# Downloads an official cloud image once, bakes login credentials into it with
# virt-customize (cached per OS), then creates and boots a new VM from it.
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
# CACHE_DIR    : where cloud images are cached (auto-detected if unset)
# VM_STORAGE   : Proxmox storage for VM disks (auto-detected if unset)
# BRIDGE       : network bridge (auto-detected if unset, defaults to vmbr0)
# OS_CHOICE    : 1-10 to skip the interactive menu
# -----------------------------------------------------------------------

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root on a Proxmox VE host." >&2
    exit 1
fi
for _cmd in qm pvesm pvesh; do
    if ! command -v "$_cmd" &>/dev/null; then
        echo "[!] '$_cmd' not found. This script must run on a Proxmox VE node." >&2
        exit 1
    fi
done

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

# --- Auto-detect cloud-image cache directory from Proxmox storage ---
# Order: active 'images' storages with a filesystem path -> active 'iso'
# storages -> $FALLBACK_CACHE_DIR. Override by exporting CACHE_DIR.
if [[ -z "${CACHE_DIR:-}" ]]; then
    _STORAGE_PATH=""
    for _content in images iso; do
        while read -r _storage; do
            [[ -z "$_storage" ]] && continue
            _STORAGE_PATH=$(resolve_storage_dir "$_storage" || true)
            if [[ -n "$_STORAGE_PATH" ]]; then
                echo "[*] Detected Proxmox storage '$_storage' (content: $_content) at $_STORAGE_PATH"
                break 2
            fi
        done < <(pvesm status -content "$_content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    done
    if [[ -n "$_STORAGE_PATH" ]]; then
        CACHE_DIR="${_STORAGE_PATH%/}/cloud-images"
    else
        echo "[*] No file-based Proxmox storage detected; using default."
        CACHE_DIR="$FALLBACK_CACHE_DIR"
    fi
fi
echo "[*] Using cloud image cache: $CACHE_DIR"
mkdir -p "$CACHE_DIR"

# --- Ensure virt-customize (libguestfs-tools) is installed AND functional ---
if ! command -v virt-customize &>/dev/null; then
    echo "[*] Installing libguestfs-tools (one-time setup)..."
    apt-get update && apt-get install -y libguestfs-tools
fi
if ! virt-customize --version &>/dev/null; then
    echo "[!] virt-customize installed but not functional. Trying: update-guestfs-appliance"
    update-guestfs-appliance 2>/dev/null || true
    if ! virt-customize --version &>/dev/null; then
        echo "[!] ERROR: virt-customize is not functional. Please check libguestfs installation." >&2
        echo "    Diagnose with: libguestfs-test-tool" >&2
        exit 1
    fi
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
    read -rp "Select OS (1-10): " OS_CHOICE
fi

BOOT_TYPE="bios"
OS_TYPE="standard"

case "$OS_CHOICE" in
    1)
        IMG_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
        IMG_URL="https://cloud-images.ubuntu.com/noble/current/${IMG_NAME}"
        ;;
    2)
        IMG_NAME="resolute-server-cloudimg-amd64.img"
        IMG_URL="https://cloud-images.ubuntu.com/resolute/current/${IMG_NAME}"
        ;;
    3)
        IMG_NAME="debian-12-generic-amd64.qcow2"
        IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${IMG_NAME}"
        ;;
    4)
        IMG_NAME="debian-13-generic-amd64.qcow2"
        IMG_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/${IMG_NAME}"
        ;;
    5)
        IMG_NAME="Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
        IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/${IMG_NAME}"
        ;;
    6)
        IMG_NAME="Arch-Linux-x86_64-cloudimg.qcow2"
        IMG_URL="https://geo.mirror.pkgbuild.com/images/latest/${IMG_NAME}"
        ;;
    7)
        IMG_NAME="Arch-Linux-x86_64-cloudimg.qcow2"
        IMG_URL="https://geo.mirror.pkgbuild.com/images/latest/${IMG_NAME}"
        OS_TYPE="omarchy"
        # Omarchy needs more headroom; only raise values the user didn't override.
        if [[ "$MEMORY" -lt 4096 ]]; then MEMORY="4096"; fi
        if [[ "$DISK_SIZE" == "20G" ]]; then DISK_SIZE="32G"; fi
        ;;
    8)
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
        IMG_NAME="Rocky-9-GenericCloud.latest.x86_64.qcow2"
        IMG_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/${IMG_NAME}"
        ;;
    10)
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

if [[ ! -f "$RAW_IMG_PATH" ]]; then
    echo "[*] Downloading pre-installed image..."
    # Download to a temp name so an interrupted transfer never poisons the cache.
    if ! wget -q --show-progress "$IMG_URL" -O "${RAW_IMG_PATH}.part"; then
        rm -f "${RAW_IMG_PATH}.part"
        echo "[!] Download failed: $IMG_URL" >&2
        exit 1
    fi
    mv "${RAW_IMG_PATH}.part" "$RAW_IMG_PATH"
fi

if [[ ! -f "$READY_IMG_PATH" ]]; then
    echo "[*] Baking credentials & config into image (happens once per OS)..."
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

# --- Target storage & network ---
STORAGE="${VM_STORAGE:-$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')}"
if [[ -z "$STORAGE" ]]; then
    echo "[!] No active Proxmox storage with 'images' content found. Set VM_STORAGE=<name>." >&2
    exit 1
fi
if [[ -z "${BRIDGE:-}" ]]; then
    BRIDGE=$(ip -o link show type bridge | awk -F': ' '{print $2; exit}')
fi
BRIDGE=${BRIDGE:-vmbr0}

EXISTING_NAMES=$(qm list 2>/dev/null | awk 'NR>1 {print $2}')
Counter=1
while echo "$EXISTING_NAMES" | grep -q "^Linux-New-${Counter}$"; do
    ((Counter++))
done
VM_NAME="Linux-New-${Counter}"
VM_ID=$(pvesh get /cluster/nextid)

echo "[*] Creating VM $VM_ID ($VM_NAME) on $STORAGE (bridge: $BRIDGE)..."

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

echo "[*] Importing disk..."
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
if [[ "$OS_TYPE" == "omarchy" ]]; then
    echo "🚀 Omarchy  : Log in as '$DEFAULT_USER' and run: ./install-omarchy.sh"
fi
echo "⚠️  Change the default password after first login!"
echo "===================================================="
