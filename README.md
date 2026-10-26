# proxmox-linux-quick-deploy

> Instantly deploy pre-configured Linux VMs on Proxmox with one script. Supports Ubuntu, Debian, Fedora, Arch, NixOS, Rocky, Alpine, and Omarchy.

`create-instant-vm.sh` turns "I need a fresh Linux VM" into a single menu choice. No ISO installers, no clicking through wizards: the VM boots straight into a working system with a user account, a password, and SSH you can log in to right away.

---

## Table of Contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [What the script changes on your host](#what-the-script-changes-on-your-host)
- [Supported operating systems](#supported-operating-systems)
- [Configuration](#configuration)
- [Storage auto-detection](#storage-auto-detection)
- [How NixOS works](#how-nixos-works)
- [How Omarchy works](#how-omarchy-works)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [Security notice](#security-notice)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

1. **Finds a cache directory** for cloud images by asking Proxmox (`pvesm`) where your file-based storage lives. See [Storage auto-detection](#storage-auto-detection).
2. **Checks for host software** (`libguestfs-tools`, `wget`, `curl`). If any is missing it shows exactly what `apt-get` would install, including dependencies and disk usage, and **asks before installing**. After installing, it boots the libguestfs appliance once to prove `virt-customize` really works. If it doesn't, it **asks** before running `update-guestfs-appliance`.
3. **Shows the full deployment plan** and asks you to confirm: where images will be downloaded and cached, which Proxmox storage will hold the VM disks (with free space), the bridge, VMID, name and resources. See [What the script changes on your host](#what-the-script-changes-on-your-host).
4. **Downloads the official cloud image** for the OS you pick. This happens once per OS and is cached.
5. **Bakes credentials into a copy** of the image (`ready-*.qcow2`) with `virt-customize`: root password, a sudo user, SSH password login enabled. This also happens once per OS and is cached.
6. **Creates the VM** with the next free VMID and a unique name (`Linux-New-1`, `Linux-New-2`, …), VirtIO SCSI + iothread, QEMU guest agent, serial console, and cloud-init (except NixOS).
7. **Imports and resizes the disk**, then **starts the VM**.

Once both images are cached, a new VM is usually ready in seconds.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Proxmox VE 7.2+** (8.x recommended) | `import-from` disk import needs 7.2 or later. |
| **Root shell on a PVE node** | The script runs `qm`, `pvesm`, `pvesh`, and `apt-get`. |
| **Internet access** | Used to download cloud images and `libguestfs-tools`. |
| **An active storage with `images` content** | Holds the VM disks (e.g. `local-lvm`, `local-zfs`, Ceph RBD, NFS). |
| **A Linux bridge** | Detected automatically, falls back to `vmbr0`. |
| **Free disk space** | About 1 GB per cached OS (raw + ready image). |

## Quick start

Run this on your Proxmox host as root. Start with a **dry run** to see what's installed, what would be installed, and where images and VM disks will go. It changes nothing:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/proxmox-linux-quick-deploy/main/create-instant-vm.sh) --check
```

Then run it for real. You'll be asked before any software is installed and again before anything is downloaded or created:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/proxmox-linux-quick-deploy/main/create-instant-vm.sh)
```

Or clone the repo first:

```bash
git clone https://github.com/entropytwo-ai/proxmox-linux-quick-deploy.git
cd proxmox-linux-quick-deploy
chmod +x create-instant-vm.sh
./create-instant-vm.sh
```

Non-interactive, with custom settings. `--yes` is required when there's no terminal to answer prompts, and it approves both the package install and the plan:

```bash
OS_CHOICE=3 MEMORY=4096 CORES=4 DISK_SIZE=40G \
DEFAULT_USER=alice DEFAULT_PASS='S3cure!' ./create-instant-vm.sh --yes
```

### Command-line options

| Option | Effect |
|---|---|
| `-c`, `--check` | Dry run. Reports Proxmox/root status, which host packages are present or missing, the exact `apt-get` command and what it would pull in, the image cache path (and free space), the VM disk storage, the bridge, and any already-cached images. Also boots the libguestfs appliance to confirm `virt-customize` works. Changes nothing. Exit code `0` = ready, `1` = action needed. |
| `-y`, `--yes` | Auto-confirm all prompts (same as `ASSUME_YES=1`). |
| `-h`, `--help` | Show usage. |

## What the script changes on your host

Nothing happens behind your back. Every change to the hypervisor is announced first:

| Change | When | Asks first? |
|---|---|---|
| `apt-get update` + `apt-get install -y libguestfs-tools` (and `wget`/`curl` if missing) | Only if something is missing | **Yes**, default **No**. Shows the package list (including dependencies) and download/disk size. If you decline, it prints the manual command and exits. |
| `update-guestfs-appliance` | Only if `virt-customize` doesn't work | **Yes** |
| Create the image cache directory | First run | Shown in the plan |
| Download the cloud image into the cache | Once per OS | Shown in the plan (URL → path) |
| Write a customized `ready-*` image into the cache | Once per OS | Shown in the plan |
| Create, import the disk into, and start a VM | Every run | Shown in the plan (VMID, name, storage, bridge, resources) |

If there's no terminal (e.g. run from cron or a pipe) and `--yes` isn't given, the script **refuses** to install or create anything rather than assuming consent.

Example plan shown before anything is downloaded:

```
==================================================================
 Deployment plan: Debian 12 (Bookworm)
==================================================================
Where things will go:
  Image cache (downloads + customized images):
    /var/lib/vz/cloud-images
    (auto-detected from Proxmox storage 'local' (content: iso))
    exists, 61.2 GiB free
  VM disks / EFI disk / cloud-init drive:
    Proxmox storage 'local-lvm' (type: lvmthin, 180.4 GiB available)
    (first active storage with 'images' content)
  Network bridge: vmbr0 (first Linux bridge)

Cloud image:
  [download] https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
          -> /var/lib/vz/cloud-images/debian-12-generic-amd64.qcow2
  [create]   customized image: /var/lib/vz/cloud-images/ready-debian-12-generic-amd64.qcow2

New VM:
  ID / name : 105 / Linux-New-1
  Resources : 2 cores, 2048 MiB RAM, 20G disk on 'local-lvm'
  Boot      : bios
  Cloud-init: drive on 'local-lvm', DHCP on vmbr0
  Login     : admin / root, password 'password123'
  Starts automatically after creation.
==================================================================
Proceed with this plan? [Y/n]
```

## Supported operating systems

| # | OS | Version / channel | Boot | Cloud-init | Notes |
|---|---|---|---|---|---|
| 1 | Ubuntu | 24.04 LTS (Noble) | BIOS | ✅ | Stable LTS. |
| 2 | Ubuntu | 26.04 daily (Resolute) | BIOS | ✅ | Development build, may break. |
| 3 | Debian | 12 (Bookworm) | BIOS | ✅ | Stable. |
| 4 | Debian | 13 (Trixie) | BIOS | ✅ | Daily build. |
| 5 | Fedora | 41 Cloud Base | BIOS | ✅ | Uses the `wheel` group. |
| 6 | Arch Linux | Latest cloud image | BIOS | ✅ | Rolling release. |
| 7 | Omarchy | Arch + bootstrap script | BIOS | ✅ | 4 GB RAM / 32 GB disk by default. See [How Omarchy works](#how-omarchy-works). |
| 8 | NixOS | Unstable (linuxcontainers.org VM image) | UEFI (OVMF) | ❌ | Declarative user injection. See [How NixOS works](#how-nixos-works). |
| 9 | Rocky Linux | 9 GenericCloud | BIOS | ✅ | RHEL-compatible. |
| 10 | Alpine Linux | 3.21 (BIOS cloud-init) | BIOS | ✅ | Very small footprint. |

## Configuration

Every variable can be set in the environment before you run the script, or edited in the config block at the top of `create-instant-vm.sh`.

| Variable | Default | Description |
|---|---|---|
| `CACHE_DIR` | *auto-detected* | Where raw and ready cloud images are cached. Setting it skips auto-detection. |
| `VM_STORAGE` | *first active `images` storage* | Proxmox storage for the VM disk, EFI disk, and cloud-init drive. |
| `BRIDGE` | *first Linux bridge*, else `vmbr0` | Network bridge for `net0`. |
| `DISK_SIZE` | `20G` (`32G` for Omarchy) | Final size of the root disk. |
| `MEMORY` | `2048` (at least `4096` for Omarchy) | RAM in MiB. |
| `CORES` | `2` | vCPU cores. CPU type is `host`. |
| `DEFAULT_USER` | `admin` | Sudo user created in the image. |
| `DEFAULT_PASS` | `password123` | Password for `DEFAULT_USER` and `root`. **Change it.** |
| `OS_CHOICE` | *(interactive)* | `1`–`10`. Skips the menu. |
| `ASSUME_YES` | `0` | `1` auto-confirms all prompts (same as `--yes`). |
| `STORAGE_CFG` | `/etc/pve/storage.cfg` | Proxmox storage config file to read (mostly useful for testing). |

## Storage auto-detection

You don't need to hardcode a path like `/mnt/nas_storage/...`. When `CACHE_DIR` is unset, the script picks one like this:

1. **Active `images` storages.** It lists them with `pvesm status -content images` and looks up each one's `path` in `/etc/pve/storage.cfg`. The first one with a real directory wins: `dir`, `nfs`, `cifs`, `cephfs`, `glusterfs`, and so on.
2. **Active `iso` storages.** Block-only storages like `lvmthin`, `zfspool`, and `rbd` have no filesystem path, so next it tries the storages that hold your ISOs (`pvesm status -content iso`). If `storage.cfg` gives no answer, it falls back to `pvesm path <storage>:iso/…`.
3. **Fallback.** If nothing is found, it uses `/var/lib/vz/template/iso/cloud-images`, the standard Proxmox `local` location.

Images are cached in a `cloud-images/` subfolder of the storage it finds. For example:

| Your setup | Resulting `CACHE_DIR` |
|---|---|
| Default install (`local` dir + `local-lvm`) | `/var/lib/vz/cloud-images` |
| NFS storage `nas` at `/mnt/pve/nas` with `images` content | `/mnt/pve/nas/cloud-images` |
| Nothing file-based detected | `/var/lib/vz/template/iso/cloud-images` |

To use a specific location:

```bash
CACHE_DIR=/mnt/pve/nas/cloud-images ./create-instant-vm.sh
```

> **Tip:** If you put the cache on shared storage (NFS/CephFS), every node in the cluster reuses the same downloaded and pre-baked images.

The VM disk storage is chosen separately. It's the first active `images` storage, or `VM_STORAGE` if you set it, so the cache can live on an NFS share while disks go to `local-lvm`.

## How NixOS works

NixOS doesn't use cloud-init the way other distros do, and changes made imperatively (like `useradd`) are lost on the next `nixos-rebuild`. So the script configures it **declaratively**:

1. It writes a NixOS module, `/etc/nixos/proxmox-user.nix`, that defines:
   - `users.users.root.initialPassword`
   - `users.users.<DEFAULT_USER>` as a normal user in `wheel` and `networkmanager`
   - `security.sudo.wheelNeedsPassword = false`
   - `services.openssh` with password and root login enabled
   - `services.qemuGuest.enable = true`
2. It uploads the module into the image with `virt-customize --upload`.
3. It patches `/etc/nixos/configuration.nix` so the module is imported: `imports = [ ./proxmox-user.nix …`.
4. It sets the root password directly in the image so you can log in on the very first boot.

The VM uses **UEFI (OVMF)** with an EFI disk (`pre-enrolled-keys=0`). No cloud-init drive is attached. Because the users are part of your configuration, they stay in place when you run `sudo nixos-rebuild switch`. Edit `/etc/nixos/proxmox-user.nix` to change them.

The newest unstable build is found by scraping the index at `images.linuxcontainers.org`.

## How Omarchy works

[Omarchy](https://omarchy.org) is an opinionated Arch Linux + Hyprland setup. Its installer is interactive and needs a running system, so it can't be baked into the image ahead of time. The script gets everything ready instead:

1. It starts from the official **Arch Linux cloud image**.
2. It creates `DEFAULT_USER` in `wheel` with **passwordless sudo** (`/etc/sudoers.d/<user>`) and enables SSH password and root login.
3. It drops `~/install-omarchy.sh` into the user's home. The script installs `git` and `curl`, then runs `wget -qO- https://omarchy.org/install | bash`.
4. It adds a reminder to `~/.bashrc` that shows on every login: *"👉 Run ./install-omarchy.sh to launch the Omarchy installer!"*
5. It gives the VM more resources by default: **4 GB RAM** and a **32 GB disk**.

After boot, log in as `DEFAULT_USER` (on the console or over SSH) and run:

```bash
./install-omarchy.sh
```

Omarchy's ready image is cached on its own (`ready-omarchy-*.qcow2`), so it never mixes with the plain Arch image.

## Troubleshooting / FAQ

<details>
<summary><b>"virt-customize is not functional"</b></summary>

libguestfs boots a small helper appliance VM. If that fails:

```bash
update-guestfs-appliance
libguestfs-test-tool          # full diagnostic output
```

Common causes: a missing kernel image in `/boot` (libguestfs needs one it can read), or `/dev/kvm` not being available. Nested setups can try `export LIBGUESTFS_BACKEND=direct`.
</details>

<details>
<summary><b>I changed DEFAULT_USER / DEFAULT_PASS but the old credentials still work</b></summary>

Ready images are cached. Delete them so they get rebuilt:

```bash
rm -f "$CACHE_DIR"/ready-*
```
</details>

<details>
<summary><b>The cache ended up in the wrong place</b></summary>

The path is shown in the deployment plan before anything happens, and by `./create-instant-vm.sh --check`. Override it with `CACHE_DIR=/your/path`. To see what the script can detect:

```bash
pvesm status -content images
pvesm status -content iso
cat /etc/pve/storage.cfg
```
</details>

<details>
<summary><b>"No active Proxmox storage with 'images' content found"</b></summary>

Enable `Disk image` content on a storage (Datacenter → Storage → Edit → Content), or pass `VM_STORAGE=<name>`.
</details>

<details>
<summary><b>The download fails (404)</b></summary>

Upstream image filenames change over time, especially Fedora, Alpine, and the daily builds. Update `IMG_NAME` / `IMG_URL` for that OS in the script and open a PR. Partial downloads are saved as `*.part` and never cached, so just run the script again.
</details>

<details>
<summary><b>The VM boots, but I can't log in over SSH</b></summary>

- Give it 30–60 seconds. Cloud-init has to finish first.
- Find the IP in the Proxmox UI (Summary tab, thanks to the guest agent) or with `qm guest cmd <vmid> network-get-interfaces`.
- Use the serial console with `qm terminal <vmid>`, or the noVNC console.
- On Alpine, `sshd_config` changes only take effect once the SSH service is running.
</details>

<details>
<summary><b>NixOS doesn't get an IP or rejects the password</b></summary>

Make sure the build was fetched successfully (the scraper exits if it can't find one). The password comes from `initialPassword`, which applies only when a user is first created. Change it later with `passwd`.
</details>

<details>
<summary><b>How do I free up disk space?</b></summary>

```bash
rm -rf "$CACHE_DIR"        # removes all cached raw and ready images
```
</details>

## Security notice

The defaults are built for **homelab and testing convenience**: a well-known password, root SSH login, and password authentication all turned on. Before a VM touches anything you care about:

- Set a strong `DEFAULT_PASS`, or change passwords right after first login.
- Switch to SSH keys and turn off `PasswordAuthentication` and `PermitRootLogin`.
- Don't expose these VMs directly to the internet.

## Contributing

PRs are welcome, especially for new distros and updated image URLs. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
