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
CUSTOM_IMG_URL="${IMG_URL:-}"
# Preloaded into every VM's shell history (press Up) and ~/install-dotfiles.sh.
# Set DOTFILES_CMD="" to disable.
DOTFILES_CMD="${DOTFILES_CMD-bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/dotfiles-nixish/main/install.sh)}"
# CACHE_DIR    : where cloud images are cached (auto-detected if unset)
# VM_STORAGE   : Proxmox storage for VM disks (auto-detected if unset)
# BRIDGE       : network bridge (auto-detected if unset, defaults to vmbr0)
# OS_CHOICE    : menu number or id (e.g. 'debian-stable') to skip the menu
# IMG_URL      : custom image URL — skips version discovery
# ASSUME_YES   : 1 to answer "yes" to every confirmation (same as --yes)
# -----------------------------------------------------------------------

# Host packages this script may install, as "command:package" pairs.
REQUIRED_PKGS=("virt-customize:libguestfs-tools" "guestfish:libguestfs-tools" "wget:wget" "curl:curl" "openssl:openssl")

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Create a ready-to-login Linux VM on this Proxmox VE host.

Options:
  -c, --check   Dry run: report what is installed, what would be installed,
                where images are cached and where VM disks will go. Changes
                nothing on the host and exits (0 = ready, 1 = action needed).
  -l, --list    Look up the newest image of every supported distro (live,
                from the official mirrors) and print versions + URLs. Needs
                only curl; changes nothing.
  -y, --yes     Don't ask for confirmation (package install + VM creation).
                Required when no terminal is available.
  -h, --help    Show this help.

Images are discovered at runtime: the script always offers the newest
release each distro publishes, so new versions appear without an update.

Environment overrides: CACHE_DIR VM_STORAGE BRIDGE OS_CHOICE (number or id,
e.g. 'fedora') DISK_SIZE MEMORY CORES DEFAULT_USER DEFAULT_PASS ASSUME_YES
IMG_URL (skip discovery and use this image; OS_CHOICE picks how it is
customized) DOTFILES_CMD (command preloaded into shell history and
~/install-dotfiles.sh in every VM; "" disables)
USAGE
}

CHECK_ONLY=0
LIST_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check) CHECK_ONLY=1 ;;
        -l|--list)  LIST_ONLY=1 ;;
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

# =====================================================================
# --- Image discovery: find the newest release of each distro at runtime ---
# =====================================================================
# Nothing below hard-codes a version number. Each resolver reads the distro's
# own release metadata or directory listing, walks from the newest release
# down until it finds one that actually has a cloud image, and sets:
#   OS_LABEL  human readable name incl. resolved version
#   IMG_URL   direct download URL (a dated/versioned file, not a moving alias)
#   IMG_NAME  versioned cache filename, so a new release is downloaded fresh
#   SUM_URL   checksum file for IMG_URL (verified after download)
#   OS_TYPE   standard | omarchy | nixos      BOOT_TYPE  bios | uefi
# To add a distro: write resolve_<id>() and add a line to OS_MENU.

# "id|menu label" — menu numbers are the array position (+1); append new
# entries at the end so existing OS_CHOICE numbers keep working.
OS_MENU=(
    "ubuntu-lts|Ubuntu LTS (newest)"
    "ubuntu-dev|Ubuntu development daily (next release)"
    "debian-stable|Debian stable (newest)"
    "debian-testing|Debian testing daily (next release)"
    "fedora|Fedora Cloud (newest)"
    "arch|Arch Linux (rolling)"
    "omarchy|Omarchy (Arch + Omarchy installer)"
    "nixos|NixOS unstable"
    "rocky|Rocky Linux (newest, RHEL clone)"
    "alpine|Alpine Linux (newest stable, ultra-lightweight)"
    "ubuntu-latest|Ubuntu newest release (incl. interim)"
    "debian-oldstable|Debian oldstable"
)

fetch()  { curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$1"; }
url_ok() { curl -fsL  --connect-timeout 10 --max-time 30 --retry 1 -r 0-0 -o /dev/null "$1"; }
newest() { sort -uV | tail -n 1; }   # newest line by version sort
# Extract hrefs matching a regex from a directory listing.
hrefs()  { grep -oE "href=\"$1\"" | sed -E 's/^href="//; s/"$//'; }

reset_image() { OS_LABEL=""; IMG_URL=""; IMG_NAME=""; SUM_URL=""; OS_TYPE="standard"; BOOT_TYPE="bios"; }

# Ubuntu: Canonical's release-upgrader metadata lists every release with its
# codename; cloud images live under /<codename>/<serial>/.  $1 = lts|latest|dev
resolve_ubuntu_kind() {
    local kind="$1" meta="https://changelogs.ubuntu.com/meta-release" list c v lts serial
    [[ "$kind" == "dev" ]] && meta+="-development"
    list=$(fetch "$meta" | awk '/^Dist:/{d=$2} /^Version:/{lts=($0 ~ /LTS/); split($2,p,"."); if (d!="") print d, p[1]"."p[2], lts; d=""}') || return 1
    [[ "$kind" == "lts" ]] && list=$(awk '$3==1' <<<"$list")
    [[ "$kind" == "dev" ]] && list=$(tail -n 1 <<<"$list")
    while read -r c v lts; do
        [[ -z "$c" ]] && continue
        serial=$(fetch "https://cloud-images.ubuntu.com/${c}/" 2>/dev/null | hrefs '[0-9]{8}(\.[0-9]+)?/' | tr -d / | newest)
        [[ -z "$serial" ]] && continue
        IMG_URL="https://cloud-images.ubuntu.com/${c}/${serial}/${c}-server-cloudimg-amd64.img"
        url_ok "$IMG_URL" || continue
        SUM_URL="https://cloud-images.ubuntu.com/${c}/${serial}/SHA256SUMS"
        IMG_NAME="ubuntu-${v}-${c}-${serial}.qcow2"
        OS_LABEL="Ubuntu ${v}$([[ "$lts" == 1 ]] && echo " LTS") (${c^}, build ${serial})"
        [[ "$kind" == "dev" ]] && OS_LABEL+=" — development daily"
        return 0
    done < <(tac <<<"$list")
    return 1
}
resolve_ubuntu_lts()    { resolve_ubuntu_kind lts; }
resolve_ubuntu_latest() { resolve_ubuntu_kind latest; }
resolve_ubuntu_dev()    { resolve_ubuntu_kind dev; }

# Debian: the archive's suite alias (stable/testing/...) gives the codename;
# cloud.debian.org has dated build dirs per codename.  $1 = suite
resolve_debian_suite() {
    local suite="$1" codename base serial file n
    codename=$(fetch "https://deb.debian.org/debian/dists/${suite}/Release" | awk '/^Codename:/ && !c {print $2; c=1}') || return 1
    [[ -z "$codename" ]] && return 1
    base="https://cloud.debian.org/images/cloud/${codename}/"
    [[ "$suite" == "testing" ]] && base+="daily/"
    while read -r serial; do
        [[ -z "$serial" ]] && continue
        file=$(fetch "${base}${serial}/" 2>/dev/null | grep -oE "debian-[0-9]+-generic-amd64(-daily)?-${serial}\.qcow2" | head -n 1)
        [[ -z "$file" ]] && continue
        n=$(sed -E 's/^debian-([0-9]+)-.*/\1/' <<<"$file")
        IMG_URL="${base}${serial}/${file}"
        SUM_URL="${base}${serial}/SHA512SUMS"
        IMG_NAME="debian-${n}-${codename}-${serial}.qcow2"
        OS_LABEL="Debian ${n} (${codename^}, ${suite}, build ${serial})"
        return 0
    done < <(fetch "$base" | hrefs '[0-9]{8}-[0-9]+/' | tr -d / | sort -uV | tac | sed -n '1,5p')
    return 1
}
resolve_debian_stable()    { resolve_debian_suite stable; }
resolve_debian_testing()   { resolve_debian_suite testing; }
resolve_debian_oldstable() { resolve_debian_suite oldstable; }

# Fedora: newest numbered release that actually ships a Cloud Generic image
# (not every release dir has one, e.g. while a release is being composed).
resolve_fedora() {
    local base="https://dl.fedoraproject.org/pub/fedora/linux/releases/" n dir file build
    while read -r n; do
        [[ -z "$n" ]] && continue
        dir="${base}${n}/Cloud/x86_64/images/"
        file=$(fetch "$dir" 2>/dev/null | grep -oE "Fedora-Cloud-Base-Generic-${n}-[0-9.]+\.x86_64\.qcow2" | newest)
        [[ -z "$file" ]] && continue
        build="${file#Fedora-Cloud-Base-Generic-"${n}"-}"; build="${build%.x86_64.qcow2}"
        # Prefer the mirror network, fall back to the master server.
        IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${n}/Cloud/x86_64/images/${file}"
        url_ok "$IMG_URL" || IMG_URL="${dir}${file}"
        SUM_URL="${dir}Fedora-Cloud-${n}-${build}-x86_64-CHECKSUM"
        IMG_NAME="fedora-${n}-${build}.qcow2"
        OS_LABEL="Fedora ${n} Cloud (build ${build})"
        return 0
    done < <(fetch "$base" | hrefs '[0-9]+/' | tr -d / | sort -rn | sed -n '1,4p')
    return 1
}

# Arch: the 'latest' dir holds a dated image next to the moving alias.
resolve_arch() {
    local dir="https://geo.mirror.pkgbuild.com/images/latest/" file ver
    file=$(fetch "$dir" | grep -oE 'Arch-Linux-x86_64-cloudimg-[0-9.]+\.qcow2' | newest) || return 1
    [[ -z "$file" ]] && return 1
    ver="${file#Arch-Linux-x86_64-cloudimg-}"; ver="${ver%.qcow2}"
    IMG_URL="${dir}${file}"
    SUM_URL="${IMG_URL}.SHA256"
    IMG_NAME="arch-${ver}.qcow2"
    OS_LABEL="Arch Linux (build ${ver})"
}
resolve_omarchy() {
    resolve_arch || return 1
    OS_LABEL="Omarchy on ${OS_LABEL}"
    OS_TYPE="omarchy"
}

# NixOS: newest build of the linuxcontainers.org VM image.
resolve_nixos() {
    local base="https://images.linuxcontainers.org/images/nixos/unstable/amd64/default/" build stamp
    build=$(fetch "$base" | grep -oE '[0-9]{8}_[0-9]{2}(%3A|:)[0-9]{2}/' | sort -u | tail -n 1) || return 1
    [[ -z "$build" ]] && return 1
    stamp=$(sed -E 's/(%3A|:)//; s#/$##' <<<"$build")
    IMG_URL="${base}${build}disk.qcow2"
    SUM_URL="${base}${build}SHA256SUMS"
    IMG_NAME="nixos-unstable-${stamp}.qcow2"
    OS_LABEL="NixOS unstable (build ${stamp})"
    OS_TYPE="nixos"
    BOOT_TYPE="uefi"
}

# Rocky: newest major version dir that has a versioned GenericCloud image.
resolve_rocky() {
    local base="https://dl.rockylinux.org/pub/rocky/" n dir file ver
    while read -r n; do
        [[ -z "$n" ]] && continue
        dir="${base}${n}/images/x86_64/"
        file=$(fetch "$dir" 2>/dev/null | grep -oE "Rocky-${n}-GenericCloud(-Base)?-${n}\.[0-9]+-[0-9.]+\.x86_64\.qcow2" | newest)
        [[ -z "$file" ]] && continue
        ver=$(sed -E "s/^Rocky-${n}-GenericCloud(-Base)?-//; s/\.x86_64\.qcow2$//" <<<"$file")
        IMG_URL="${dir}${file}"
        SUM_URL="${IMG_URL}.CHECKSUM"
        IMG_NAME="rocky-${ver}.qcow2"
        OS_LABEL="Rocky Linux ${ver%%-*} (build ${ver#*-})"
        return 0
    done < <(fetch "$base" | hrefs '[0-9]+/' | tr -d / | sort -rn | sed -n '1,3p')
    return 1
}

# Alpine: the latest-stable alias always points to the newest stable branch.
resolve_alpine() {
    local dir="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/" file ver
    file=$(fetch "$dir" | grep -oE 'generic_alpine-[0-9.]+-x86_64-bios-cloudinit-r[0-9]+\.qcow2' | newest) || return 1
    [[ -z "$file" ]] && return 1
    ver=$(sed -E 's/^generic_alpine-([0-9.]+)-x86_64-bios-cloudinit-(r[0-9]+)\.qcow2$/\1-\2/' <<<"$file")
    IMG_URL="${dir}${file}"
    SUM_URL="${IMG_URL}.sha512"
    IMG_NAME="alpine-${ver}.qcow2"
    OS_LABEL="Alpine Linux ${ver%-r*}"
}

# Map a menu number or id to an id (empty if unknown).
os_id_for() {
    local choice="$1" i entry
    for i in "${!OS_MENU[@]}"; do
        entry="${OS_MENU[$i]%%|*}"
        if [[ "$choice" == "$((i + 1))" || "$choice" == "$entry" ]]; then echo "$entry"; return; fi
    done
}

# Run the resolver for an id; leaves the result in the globals above.
resolve_os() {
    reset_image
    "resolve_${1//-/_}" && [[ -n "$IMG_URL" && -n "$IMG_NAME" ]]
}

# Print the resolved image for every menu entry (used by --list and --check).
print_image_sources() {
    local i id rc=0
    for i in "${!OS_MENU[@]}"; do
        id="${OS_MENU[$i]%%|*}"
        if resolve_os "$id" 2>/dev/null; then
            printf '  [%2d] %-16s %s\n       %s\n' "$((i + 1))" "$id" "$OS_LABEL" "$IMG_URL"
        else
            printf '  [%2d] %-16s [!] could not determine the newest image (network/mirror issue?)\n' "$((i + 1))" "$id"
            rc=1
        fi
    done
    return "$rc"
}

# Expected hash for a file from a checksum file in any common format:
# GNU ("hash  name" / "hash *name"), BSD ("SHA256 (name) = hash") or bare hash.
expected_hash() {
    local sums="$1" name="$2" h
    h=$(awk -v n="$name" '{
            ok = 0
            for (i = 1; i <= NF; i++) { t = $i; gsub(/^[*(]|[)]$/, "", t); if (t == n) ok = 1 }
            if (ok) for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9a-fA-F]+$/ && (length($i) == 64 || length($i) == 128)) { print tolower($i); exit }
        }' <<<"$sums")
    if [[ -z "$h" && $(wc -w <<<"$sums") -eq 1 ]] && [[ "$sums" =~ ^[0-9a-fA-F]{64}([0-9a-fA-F]{64})?$ ]]; then
        h="${sums,,}"
    fi
    echo "$h"
}

# Verify a downloaded file against SUM_URL. Returns 1 only on a real mismatch;
# a missing/unreadable checksum file is reported but not fatal.
verify_download() {
    local file="$1" name sums expected actual
    if [[ -z "$SUM_URL" ]]; then echo "    [!] no checksum published — skipping verification"; return 0; fi
    name=$(basename "$IMG_URL")
    if ! sums=$(fetch "$SUM_URL"); then
        echo "    [!] could not fetch $SUM_URL — skipping verification"; return 0
    fi
    expected=$(expected_hash "$sums" "$name")
    if [[ -z "$expected" ]]; then
        echo "    [!] $name not listed in $SUM_URL — skipping verification"; return 0
    fi
    if [[ ${#expected} -eq 128 ]]; then actual=$(sha512sum "$file" | cut -d' ' -f1)
    else actual=$(sha256sum "$file" | cut -d' ' -f1); fi
    if [[ "$actual" != "$expected" ]]; then
        echo "    [!] CHECKSUM MISMATCH for $name" >&2
        echo "        expected $expected" >&2
        echo "        got      $actual" >&2
        return 1
    fi
    echo "    [ok] SHA$([[ ${#expected} -eq 128 ]] && echo 512 || echo 256) checksum verified"
}

# NixOS VM images boot a unified kernel image; the ext4 root holds only
# /nix/store (no /etc), so virt-customize's OS inspection cannot work. Instead
# pre-seed /etc/passwd, /etc/group and /etc/shadow with guestfish: with NixOS'
# default mutableUsers=true, first-boot activation keeps these entries and
# merges the declared system users in. Also adds DHCP for any NIC name (the
# upstream image only matches Incus' enp5s0).
nixos_root_fs() {
    local img="$1" dev fstype
    while IFS=': ' read -r dev fstype; do
        [[ "$fstype" =~ ^(ext4|btrfs|xfs)$ ]] || continue
        if [[ "$(guestfish --ro -a "$img" run : mount-ro "$dev" / : is-dir /nix/store 2>/dev/null)" == "true" ]]; then
            echo "$dev"; return 0
        fi
    done < <(guestfish --ro -a "$img" run : list-filesystems 2>/dev/null)
    return 1
}

# Write the dotfiles preload files into directory $1: 'bash_history' (the
# command, so Up-arrow recalls it) and 'install-dotfiles.sh' (runs it).
# Returns 1 (and writes nothing) when DOTFILES_CMD is empty.
make_dotfiles_files() {
    [[ -n "$DOTFILES_CMD" ]] || return 1
    printf '%s\n' "$DOTFILES_CMD" > "$1/bash_history"
    printf '#!/usr/bin/env bash\n# Installs your dotfiles (preloaded by proxmox-linux-quick-deploy).\n%s "$@"\n' \
        "$DOTFILES_CMD" > "$1/install-dotfiles.sh"
}

customize_nixos() {
    local img="$1" rootdev tmp check rc=0 dotfiles_cmds=""
    if ! rootdev=$(nixos_root_fs "$img"); then
        echo "[!] Could not find the NixOS root filesystem (/nix/store) in $img" >&2
        return 1
    fi
    tmp=$(mktemp -d)
    printf 'root:x:0:0:System administrator:/root:/run/current-system/sw/bin/bash\n%s:x:1000:100::/home/%s:/run/current-system/sw/bin/bash\n' \
        "$DEFAULT_USER" "$DEFAULT_USER" > "$tmp/passwd"
    printf 'root:x:0:\nwheel:x:1:%s\nusers:x:100:\n' "$DEFAULT_USER" > "$tmp/group"
    printf 'root:%s:1::::::\n%s:%s:1::::::\n' \
        "$(openssl passwd -6 "$DEFAULT_PASS")" "$DEFAULT_USER" "$(openssl passwd -6 "$DEFAULT_PASS")" > "$tmp/shadow"
    printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=true\n' > "$tmp/90-proxmox-dhcp.network"
    if make_dotfiles_files "$tmp"; then
        local h
        for h in /root "/home/$DEFAULT_USER"; do
            dotfiles_cmds+="upload $tmp/bash_history $h/.bash_history
upload $tmp/install-dotfiles.sh $h/install-dotfiles.sh
chmod 0600 $h/.bash_history
chmod 0755 $h/install-dotfiles.sh
"
        done
        dotfiles_cmds+="chown 1000 100 /home/$DEFAULT_USER/.bash_history
chown 1000 100 /home/$DEFAULT_USER/install-dotfiles.sh
"
    fi

    guestfish --rw -a "$img" <<GFEOF || rc=1
run
mount $rootdev /
mkdir-p /etc/systemd/network
upload $tmp/passwd /etc/passwd
upload $tmp/group /etc/group
upload $tmp/shadow /etc/shadow
upload $tmp/90-proxmox-dhcp.network /etc/systemd/network/90-proxmox-dhcp.network
chmod 0644 /etc/passwd
chmod 0644 /etc/group
chmod 0640 /etc/shadow
chmod 0644 /etc/systemd/network/90-proxmox-dhcp.network
mkdir-p /root
chmod 0700 /root
mkdir-p /home/$DEFAULT_USER
chown 1000 100 /home/$DEFAULT_USER
chmod 0700 /home/$DEFAULT_USER
$dotfiles_cmds
GFEOF
    rm -rf "$tmp"
    [[ "$rc" == 0 ]] || return 1
    # Read the result back so a silently broken image is never cached.
    check=$(guestfish --ro -a "$img" run : mount-ro "$rootdev" / : cat /etc/shadow 2>/dev/null || true)
    if ! grep -qE "^${DEFAULT_USER}:[\$]6[\$]" <<<"$check" || ! grep -qE '^root:[$]6[$]' <<<"$check"; then
        echo "[!] Verification failed: credentials not found in the customized NixOS image." >&2
        return 1
    fi
}

# --- --list: show what each menu entry resolves to right now, then exit ---
if [[ "$LIST_ONLY" == "1" ]]; then
    command -v curl &>/dev/null || { echo "[!] --list needs curl." >&2; exit 1; }
    echo "Newest images available right now (looked up live):"
    print_image_sources && exit 0 || exit 1
fi

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
    echo
    echo "Image sources (newest releases, looked up live):"
    if ! command -v curl &>/dev/null; then
        echo "  (skipped — curl is not installed yet)"
    elif ! print_image_sources; then
        echo "  Some lookups failed; those entries would fail until the mirror is reachable."
    fi
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
    echo "Select an OS to deploy instantly (the newest version is looked up live):"
    for _i in "${!OS_MENU[@]}"; do
        printf '  [%2d] %s\n' "$((_i + 1))" "${OS_MENU[$_i]#*|}"
    done
    echo ""
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -u 3 -p "Select OS (1-${#OS_MENU[@]}): " OS_CHOICE || true
        exec 3<&-
    else
        echo "[!] No terminal available. Set OS_CHOICE=1..${#OS_MENU[@]} (or an id like 'fedora')." >&2
        exit 1
    fi
fi

OS_ID=$(os_id_for "$OS_CHOICE")
if [[ -z "$OS_ID" ]]; then
    echo "[!] Invalid choice: '$OS_CHOICE'" >&2
    exit 1
fi

if [[ -n "$CUSTOM_IMG_URL" ]]; then
    # Custom image: no discovery; OS_CHOICE only decides how it is customized.
    reset_image
    IMG_URL="$CUSTOM_IMG_URL"
    IMG_NAME="custom-$(basename "${IMG_URL%%\?*}")"
    OS_LABEL="Custom image ($OS_ID customization)"
    case "$OS_ID" in
        omarchy) OS_TYPE="omarchy" ;;
        nixos)   OS_TYPE="nixos"; BOOT_TYPE="uefi" ;;
    esac
else
    echo "[*] Looking up the newest '$OS_ID' image..."
    if ! resolve_os "$OS_ID"; then
        echo "[!] Could not determine the newest '$OS_ID' image from its official mirror." >&2
        echo "    Check this host's internet/DNS, try again later, or pin an image with" >&2
        echo "    IMG_URL=<url> OS_CHOICE=$OS_ID $(basename "$0")" >&2
        exit 1
    fi
    echo "    Found: $OS_LABEL"
fi

if [[ "$OS_TYPE" == "omarchy" ]]; then
    # Omarchy needs more headroom; only raise values the user didn't override.
    if [[ "$MEMORY" -lt 4096 ]]; then MEMORY="4096"; fi
    if [[ "$DISK_SIZE" == "20G" ]]; then DISK_SIZE="32G"; fi
fi

RAW_IMG_PATH="${CACHE_DIR}/${IMG_NAME}"
# Fingerprint of everything baked into the image: changing the user, password
# or DOTFILES_CMD (or a new customization version) builds a fresh ready image
# instead of silently reusing a stale one.
CUSTOM_TAG=$(printf 'v2|%s|%s|%s' "$DEFAULT_USER" "$DEFAULT_PASS" "$DOTFILES_CMD" | sha256sum | cut -c1-8)
if [[ "$OS_TYPE" == "omarchy" ]]; then
    READY_IMG_PATH="${CACHE_DIR}/ready-omarchy-${CUSTOM_TAG}-${IMG_NAME}"
else
    READY_IMG_PATH="${CACHE_DIR}/ready-${CUSTOM_TAG}-${IMG_NAME}"
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
    [[ -n "$SUM_URL" ]] && echo "             verified against $SUM_URL"
fi
if [[ -f "$READY_IMG_PATH" ]]; then
    echo "  [cached]   customized image: $READY_IMG_PATH"
else
    echo "  [create]   customized image: $READY_IMG_PATH"
    if [[ "$OS_TYPE" == "nixos" ]]; then
        echo "             (copy of the cloud image with users/passwords + DHCP seeded via guestfish)"
    else
        echo "             (copy of the cloud image with credentials/SSH baked in via virt-customize)"
    fi
    [[ -n "$DOTFILES_CMD" ]] && echo "             + dotfiles command preloaded in shell history and ~/install-dotfiles.sh"
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
if [[ "$OS_TYPE" == "nixos" ]]; then
    echo "              (NixOS: root password works on the console; over SSH log in as"
    echo "               '$DEFAULT_USER' and use sudo — NixOS refuses root password SSH)"
fi
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
    if ! verify_download "${RAW_IMG_PATH}.part"; then
        rm -f "${RAW_IMG_PATH}.part"
        echo "[!] Downloaded image is corrupt or was tampered with — deleted. Try again." >&2
        exit 1
    fi
    mv "${RAW_IMG_PATH}.part" "$RAW_IMG_PATH"
fi

if [[ ! -f "$READY_IMG_PATH" ]]; then
    echo "[*] Baking credentials & config into $READY_IMG_PATH (happens once per OS)..."
    # Bake into a temp file; only promote it to the cache when customization succeeds.
    WORK_IMG="${READY_IMG_PATH}.part"
    cp "$RAW_IMG_PATH" "$WORK_IMG"
    DOTFILES_TMP=$(mktemp -d)
    trap 'rm -f "$WORK_IMG"; rm -rf "$DOTFILES_TMP"' EXIT

    # Dotfiles preload for virt-customize images: put the files in /etc/skel
    # BEFORE the user is created (so useradd -m / cloud-init copy them), then
    # copy them into root's and any already-existing user home.
    DOTFILES_PRE=(); DOTFILES_POST=()
    if make_dotfiles_files "$DOTFILES_TMP"; then
        DOTFILES_PRE=(--mkdir /etc/skel
            --upload "$DOTFILES_TMP/bash_history:/etc/skel/.bash_history"
            --upload "$DOTFILES_TMP/install-dotfiles.sh:/etc/skel/install-dotfiles.sh"
            --chmod "0600:/etc/skel/.bash_history"
            --chmod "0755:/etc/skel/install-dotfiles.sh")
        # The command needs bash + curl (missing on e.g. Alpine): install them
        # when absent. Best effort — a failure here never breaks the bake.
        DOTFILES_POST=(--run-command "if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then if command -v apk >/dev/null 2>&1; then apk add --no-cache bash curl; elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y bash curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y bash curl; elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm --needed bash curl; elif command -v zypper >/dev/null 2>&1; then zypper -n install bash curl; fi; fi || true"
            --run-command "for h in /root \$(getent passwd ${DEFAULT_USER} | cut -d: -f6); do [ -d \"\$h\" ] || continue; for f in .bash_history install-dotfiles.sh; do [ -e \"\$h/\$f\" ] || cp -p /etc/skel/\$f \"\$h/\$f\"; done; [ \"\$h\" = /root ] || chown ${DEFAULT_USER}: \"\$h/.bash_history\" \"\$h/install-dotfiles.sh\"; done")
    fi

    if [[ "$OS_TYPE" == "nixos" ]]; then
        if ! customize_nixos "$WORK_IMG"; then
            echo "[!] NixOS customization failed; nothing was cached." >&2
            exit 1
        fi

    elif [[ "$OS_TYPE" == "omarchy" ]]; then
        virt-customize -a "$WORK_IMG" \
            --root-password "password:${DEFAULT_PASS}" \
            "${DOTFILES_PRE[@]}" \
            --run-command "id -u ${DEFAULT_USER} &>/dev/null || useradd -m -s /bin/bash -G wheel ${DEFAULT_USER}" \
            --password "${DEFAULT_USER}:password:${DEFAULT_PASS}" \
            --run-command "echo '${DEFAULT_USER} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${DEFAULT_USER}" \
            --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config" \
            --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config" \
            --run-command "echo -e '#!/bin/bash\nset -e\nsudo pacman -Sy --noconfirm git curl\nwget -qO- https://omarchy.org/install | bash' > /home/${DEFAULT_USER}/install-omarchy.sh" \
            --run-command "chmod +x /home/${DEFAULT_USER}/install-omarchy.sh && chown ${DEFAULT_USER}:${DEFAULT_USER} /home/${DEFAULT_USER}/install-omarchy.sh" \
            --run-command "echo 'echo \"👉 Run ./install-omarchy.sh to launch the Omarchy installer!\"' >> /home/${DEFAULT_USER}/.bashrc" \
            "${DOTFILES_POST[@]}"
    else
        virt-customize -a "$WORK_IMG" \
            --root-password "password:${DEFAULT_PASS}" \
            "${DOTFILES_PRE[@]}" \
            --run-command "id -u ${DEFAULT_USER} &>/dev/null || useradd -m -s /bin/bash -G sudo,adm ${DEFAULT_USER} 2>/dev/null || useradd -m -s /bin/bash -G wheel ${DEFAULT_USER}" \
            --password "${DEFAULT_USER}:password:${DEFAULT_PASS}" \
            --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true" \
            --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true" \
            --run-command "rm -f /etc/ssh/sshd_config.d/*cloudimg*.conf 2>/dev/null || true" \
            "${DOTFILES_POST[@]}"
    fi
    mv "$WORK_IMG" "$READY_IMG_PATH"
    rm -rf "$DOTFILES_TMP"
    trap - EXIT
else
    echo "[*] Using cached ready image: $READY_IMG_PATH"
fi

# The NixOS image ships no qemu-guest-agent; enabling the agent there would
# make Proxmox shutdown/reboot wait for an agent that never answers.
AGENT_ENABLED=1
[[ "$OS_TYPE" == "nixos" ]] && AGENT_ENABLED=0

echo "[*] Creating VM $VM_ID ($VM_NAME) on storage '$STORAGE' (bridge: $BRIDGE)..."

qm create "$VM_ID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE" \
    --scsihw virtio-scsi-single \
    --agent enabled="$AGENT_ENABLED" \
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
if [[ "$OS_TYPE" == "nixos" ]]; then
    echo "   NixOS    : SSH as '$DEFAULT_USER' (sudo asks for the password); root works on the console"
fi
echo "🔑 Password : $DEFAULT_PASS"
echo "💾 Disk     : storage '$STORAGE'   Image cache: $CACHE_DIR"
if [[ "$OS_TYPE" == "omarchy" ]]; then
    echo "🚀 Omarchy  : Log in as '$DEFAULT_USER' and run: ./install-omarchy.sh"
fi
if [[ -n "$DOTFILES_CMD" ]]; then
    echo "🧰 Dotfiles : press ↑ then Enter after login, or run ./install-dotfiles.sh"
fi
echo "⚠️  Change the default password after first login!"
echo "===================================================="
