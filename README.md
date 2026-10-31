# proxmox-linux-quick-deploy

> Instantly deploy pre-configured Linux VMs on Proxmox with one script. Supports Ubuntu, Debian, Fedora, Arch, NixOS, Rocky, Alpine, and Omarchy, and always offers the **newest release** of each, discovered at runtime.

`create-instant-vm.sh` turns "I need a fresh Linux VM" into a single menu choice. No ISO installers, no clicking through wizards: the VM boots straight into a working system with a user account, a password, and SSH you can log in to right away.

<table><tr>
<td><img src=".github/donate-bitcoin-qr.png" width="96" alt="Bitcoin donation QR code"></td>
<td><sub>💛 If you find this project useful, I'd be grateful for any donation. Thank you!<br>
<b>Bitcoin:</b> <code>bc1qu6dkcchurnutgc40y6n53s3zm588z9nnkm2ygq</code></sub></td>
</tr></table>

## 🚀 One-line install

Run this as root in your Proxmox VE shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/proxmox-linux-quick-deploy/main/create-instant-vm.sh)
```

It asks before installing anything on the host and shows the full plan before anything is downloaded or created. Add `--check` to the end for a dry run that changes nothing, or `--list` to see which versions it would deploy right now. More options are in [Quick start](#quick-start).

---

## Table of Contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [What the script changes on your host](#what-the-script-changes-on-your-host)
- [Supported operating systems](#supported-operating-systems)
- [Automatic version discovery](#automatic-version-discovery)
- [Configuration](#configuration)
- [Storage auto-detection](#storage-auto-detection)
- [Preloaded dotfiles command](#preloaded-dotfiles-command)
- [How NixOS works](#how-nixos-works)
- [How Omarchy works](#how-omarchy-works)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [Security notice](#security-notice)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

1. **Finds a cache directory** for cloud images by asking Proxmox (`pvesm`) where your file-based storage lives. See [Storage auto-detection](#storage-auto-detection).
2. **Checks for host software** (`libguestfs-tools`, `wget`, `curl`, `openssl`). If any is missing it shows exactly what `apt-get` would install, including dependencies and disk usage, and **asks before installing**. After installing, it boots the libguestfs appliance once to prove `virt-customize` really works. If it doesn't, it **asks** before running `update-guestfs-appliance`.
3. **Shows the full deployment plan** and asks you to confirm: where images will be downloaded and cached, which Proxmox storage will hold the VM disks (with free space), the bridge, VMID, name and resources. See [What the script changes on your host](#what-the-script-changes-on-your-host).
4. **Finds the newest release** of the OS you pick on its official mirror (see [Automatic version discovery](#automatic-version-discovery)), then **downloads the cloud image and verifies its checksum**. This happens once per release and is cached.
5. **Bakes credentials into a copy** of the image (`ready-*.qcow2`) with `virt-customize` (or `guestfish` for NixOS): root password, a sudo user, SSH password login enabled, and your [dotfiles command preloaded](#preloaded-dotfiles-command) in shell history. This also happens once per release and is cached.
6. **Creates the VM** with the next free VMID and a unique name (`Linux-New-1`, `Linux-New-2`, …), VirtIO SCSI + iothread, QEMU guest agent (except NixOS), serial console, and cloud-init (except NixOS).
7. **Imports and resizes the disk**, then **starts the VM**.

Once both images are cached, a new VM is usually ready in seconds.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Prerequisites

| Requirement | Notes |
|---|---|
| **Proxmox VE 7.2+** (8.x recommended) | `import-from` disk import needs 7.2 or later. |
| **Root shell on a PVE node** | The script runs `qm`, `pvesm`, `pvesh`, and `apt-get`. |
| **Internet access** | Used to download cloud images and `libguestfs-tools`. |
| **An active storage with `images` content** | Holds the VM disks (e.g. `local-lvm`, `local-zfs`, Ceph RBD, NFS). |
| **A Linux bridge** | Detected automatically, falls back to `vmbr0`. |
| **Free disk space** | About 1 GB per cached OS (raw + ready image). |

<sub>[↑ Back to contents](#table-of-contents)</sub>

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
| `-c`, `--check` | Dry run. Reports Proxmox/root status, which host packages are present or missing, the exact `apt-get` command and what it would pull in, the image cache path (and free space), the VM disk storage, the bridge, the newest image for every OS (looked up live), and any already-cached images. Also boots the libguestfs appliance to confirm `virt-customize` works. Changes nothing. Exit code `0` = ready, `1` = action needed. |
| `-l`, `--list` | Looks up the newest image for every menu entry, live from the official mirrors, and prints version + download URL. Needs only `curl`, no root and no Proxmox. Changes nothing. |
| `-y`, `--yes` | Auto-confirm all prompts (same as `ASSUME_YES=1`). |
| `-h`, `--help` | Show usage. |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## What the script changes on your host

Nothing happens behind your back. Every change to the hypervisor is announced first:

| Change | When | Asks first? |
|---|---|---|
| `apt-get update` + `apt-get install -y libguestfs-tools` (and `wget`/`curl`/`openssl` if missing) | Only if something is missing | **Yes**, default **No**. Shows the package list (including dependencies) and download/disk size. If you decline, it prints the manual command and exits. |
| `update-guestfs-appliance` | Only if `virt-customize` doesn't work | **Yes** |
| Create the image cache directory | First run | Shown in the plan |
| Download the cloud image into the cache and verify its checksum | Once per release | Shown in the plan (URL → path, checksum source) |
| Write a customized `ready-*` image into the cache | Once per release | Shown in the plan |
| Create, import the disk into, and start a VM | Every run | Shown in the plan (VMID, name, storage, bridge, resources) |

If there's no terminal (e.g. run from cron or a pipe) and `--yes` isn't given, the script **refuses** to install or create anything rather than assuming consent.

Example plan shown before anything is downloaded:

```
==================================================================
 Deployment plan: Debian 13 (Trixie, stable, build 20261021-2638)
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
  [download] https://cloud.debian.org/images/cloud/trixie/20261021-2638/debian-13-generic-amd64-20261021-2638.qcow2
          -> /var/lib/vz/cloud-images/debian-13-trixie-20261021-2638.qcow2
             verified against https://cloud.debian.org/images/cloud/trixie/20261021-2638/SHA512SUMS
  [create]   customized image: /var/lib/vz/cloud-images/ready-b81f3836-debian-13-trixie-20261021-2638.qcow2
             (copy of the cloud image with credentials/SSH baked in via virt-customize)
             + dotfiles command preloaded in shell history and ~/install-dotfiles.sh

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

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Supported operating systems

| # | Id (`OS_CHOICE`) | OS | Channel (resolved at runtime) | Boot | Cloud-init | Notes |
|---|---|---|---|---|---|---|
| 1 | `ubuntu-lts` | Ubuntu | Newest LTS | BIOS | ✅ | Stable LTS. |
| 2 | `ubuntu-dev` | Ubuntu | Next release, daily build | BIOS | ✅ | Development build, may break. |
| 3 | `debian-stable` | Debian | Current stable | BIOS | ✅ | |
| 4 | `debian-testing` | Debian | Testing, daily build | BIOS | ✅ | Next Debian release. |
| 5 | `fedora` | Fedora | Newest release with a Cloud image | BIOS | ✅ | Uses the `wheel` group. |
| 6 | `arch` | Arch Linux | Newest dated cloud image | BIOS | ✅ | Rolling release. |
| 7 | `omarchy` | Omarchy | Arch + bootstrap script | BIOS | ✅ | 4 GB RAM / 32 GB disk by default. See [How Omarchy works](#how-omarchy-works). |
| 8 | `nixos` | NixOS | Newest unstable build (linuxcontainers.org) | UEFI (OVMF) | ❌ | See [How NixOS works](#how-nixos-works). |
| 9 | `rocky` | Rocky Linux | Newest major + point release | BIOS | ✅ | RHEL-compatible. |
| 10 | `alpine` | Alpine Linux | Newest stable (BIOS cloud-init) | BIOS | ✅ | Very small footprint. |
| 11 | `ubuntu-latest` | Ubuntu | Newest release, incl. interim (non-LTS) | BIOS | ✅ | Same as LTS when the newest release is an LTS. |
| 12 | `debian-oldstable` | Debian | Previous stable | BIOS | ✅ | |

Run `./create-instant-vm.sh --list` to see the exact versions these resolve to today. Example output from October 2026: Ubuntu 26.04 LTS, Ubuntu 26.10 daily, Debian 13 and 14 (testing), Fedora 44, Rocky 10.2, Alpine 3.24.1.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Automatic version discovery

The script contains **no hard-coded version numbers**, so it doesn't go stale when distros ship new releases. When you pick an OS, a small resolver function looks up the newest release on that distro's official servers:

| OS | Where the version comes from |
|---|---|
| Ubuntu | Canonical's release metadata (`changelogs.ubuntu.com/meta-release[-development]`), then the newest dated build in `cloud-images.ubuntu.com/<codename>/` |
| Debian | The suite alias in the archive (`deb.debian.org/debian/dists/stable/Release` → codename), then the newest dated build on `cloud.debian.org` |
| Fedora | The release list on `dl.fedoraproject.org`, newest first, skipping releases that don't ship a Cloud image yet |
| Rocky | The major-version list on `dl.rockylinux.org`, then the newest versioned GenericCloud image |
| Alpine | The `latest-stable` branch on `dl-cdn.alpinelinux.org` |
| Arch | The dated image in `geo.mirror.pkgbuild.com/images/latest/` |
| NixOS | The newest build directory on `images.linuxcontainers.org` |

What this gives you:

- **New releases show up automatically.** When Ubuntu 28.04 LTS, Debian 14 or Fedora 45 ships with cloud images, the menu entries pick it up without a script update.
- **Gaps are skipped.** If the newest release has no cloud image yet (Fedora 42, for example, never shipped one), the resolver falls back to the newest release that does.
- **Every download is pinned and verified.** The script downloads a dated or versioned file, not a moving alias, and checks it against the distro's published SHA256/SHA512 checksum. A mismatch deletes the file and aborts.
- **The cache refreshes itself.** Cached files carry the version in their name (e.g. `fedora-44-1.7.qcow2`, `ubuntu-26.04-resolute-20261016.qcow2`), so a new build is downloaded fresh while existing VMs and images are left alone. Old versions stay in the cache until you delete them.

To pin a specific image instead, pass its URL. Discovery is skipped, and `OS_CHOICE` only chooses how the image is customized:

```bash
IMG_URL=https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img \
OS_CHOICE=ubuntu-lts ./create-instant-vm.sh
```

<sub>[↑ Back to contents](#table-of-contents)</sub>

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
| `OS_CHOICE` | *(interactive)* | Menu number (`1`–`12`) or id (e.g. `fedora`, `debian-stable`). Skips the menu. |
| `IMG_URL` | *(discovered)* | Use this image instead of the newest one. `OS_CHOICE` still picks the customization. |
| `DOTFILES_CMD` | *the dotfiles-nixish one-liner* | Command preloaded into every VM's shell history and `~/install-dotfiles.sh`. `DOTFILES_CMD=""` turns it off. See [Preloaded dotfiles command](#preloaded-dotfiles-command). |
| `ASSUME_YES` | `0` | `1` auto-confirms all prompts (same as `--yes`). |
| `STORAGE_CFG` | `/etc/pve/storage.cfg` | Proxmox storage config file to read (mostly useful for testing). |

<sub>[↑ Back to contents](#table-of-contents)</sub>

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

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Preloaded dotfiles command

VMs without the QEMU guest agent (NixOS, or any VM before the agent is installed) have no clipboard in the Proxmox console, so long commands have to be typed by hand. To avoid that, every VM comes with the [dotfiles-nixish](https://github.com/entropytwo-ai/dotfiles-nixish) installer ready to run, for both `DEFAULT_USER` and `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/dotfiles-nixish/main/install.sh)
```

- **Shell history:** log in, press **↑**, then **Enter**.
- **Script:** `./install-dotfiles.sh` runs the same command. Arguments are passed through, e.g. `./install-dotfiles.sh --zsh`.

How it gets there:

- **cloud-init distros:** the two files go into `/etc/skel`, so the user that cloud-init creates on first boot gets them, and they are also copied into `/root` and any user home that already exists in the image.
- **NixOS:** written straight into `/root` and `/home/$DEFAULT_USER` with `guestfish`. NixOS already ships `bash` and `curl`.
- **Missing `bash` or `curl`** (Alpine ships neither) are installed into the image with its package manager. This step is best effort and never fails the build.

Use a different command, or turn it off:

```bash
DOTFILES_CMD='bash <(curl -fsSL https://example.com/my-setup.sh)' ./create-instant-vm.sh
DOTFILES_CMD='' ./create-instant-vm.sh
```

The cached `ready-*` image name contains a short fingerprint of the user, password and `DOTFILES_CMD` (`ready-<fingerprint>-<image>`). If you change any of them, a new ready image is built automatically instead of reusing an old one.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## How NixOS works

The NixOS image from linuxcontainers.org is not a normal cloud image. It boots a unified kernel image (UKI) from the EFI partition, and its root filesystem holds **only `/nix/store`**, with no `/etc` at all. `/etc` is generated on first boot. That's why `virt-customize` fails on it with *"no operating systems were found in the guest image"*: there's nothing for its OS detection to find.

So the script uses `guestfish` and writes plain files instead:

1. It finds the root partition (the one that contains `/nix/store`).
2. It writes `/etc/passwd`, `/etc/group` and `/etc/shadow` with `root` and `DEFAULT_USER` (in `wheel`), with SHA-512 password hashes made by `openssl passwd -6`. NixOS runs with `mutableUsers = true`, so on first boot its activation script **keeps these accounts** and merges in its own system users.
3. It adds `/etc/systemd/network/90-proxmox-dhcp.network`, which turns on DHCP for any `en*`/`eth*` NIC. The upstream image only configures Incus' interface name (`enp5s0`), which a Proxmox VM doesn't have.
4. It reads `/etc/shadow` back out of the image and refuses to cache it if the accounts aren't there.

The VM uses **UEFI (OVMF)** with an EFI disk (`pre-enrolled-keys=0`). It has no cloud-init drive and no QEMU guest agent (the image doesn't include one, so the agent option is left off and shutdown uses ACPI).

Logging in:

- **SSH:** `ssh <DEFAULT_USER>@<ip>` with the password. `sudo` asks for the same password.
- **Root:** the password works on the console (`qm terminal <vmid>` or noVNC) and through `sudo -i`. The image's SSH config allows root by key only (`PermitRootLogin prohibit-password`), so root password logins over SSH are refused.

The accounts are ordinary mutable users. To manage them declaratively, add them to your own `/etc/nixos/configuration.nix` before running `nixos-rebuild switch`.

This approach was tested by booting the customized image under QEMU with OVMF: it got a DHCP address, SSH password login worked, `sudo` worked, and the root partition grew to fill the disk.

<sub>[↑ Back to contents](#table-of-contents)</sub>

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

<sub>[↑ Back to contents](#table-of-contents)</sub>

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

Versions are discovered at runtime, so renamed files and new releases are handled automatically. If a download still fails, the mirror may be temporarily broken. Run `./create-instant-vm.sh --list` to see what each entry resolves to, or pin a known-good image with `IMG_URL=<url> OS_CHOICE=<id>`. If a distro has changed its directory layout, its `resolve_<id>` function needs an update, so please open an issue or PR. Partial downloads are saved as `*.part` and never cached, so just run the script again.
</details>

<details>
<summary><b>The VM boots, but I can't log in over SSH</b></summary>

- Give it 30–60 seconds. Cloud-init has to finish first.
- Find the IP in the Proxmox UI (Summary tab, thanks to the guest agent) or with `qm guest cmd <vmid> network-get-interfaces`.
- Use the serial console with `qm terminal <vmid>`, or the noVNC console.
- On Alpine, `sshd_config` changes only take effect once the SSH service is running.
</details>

<details>
<summary><b>NixOS: "no operating systems were found in the guest image", no IP, or password rejected</b></summary>

- The `virt-customize` error came from older versions of this script. Update the script and run it again. NixOS is now customized with `guestfish` (see [How NixOS works](#how-nixos-works)).
- Root password logins over SSH are refused by design. Use `ssh <DEFAULT_USER>@<ip>` and `sudo`, or log in as root on the console.
- No IP: check `networkctl` on the console. The script adds a DHCP rule for every `en*`/`eth*` interface.
- An old `ready-nixos-*` image left over from a failed run is never reused, because ready images are only cached after they pass verification.
</details>

<details>
<summary><b>How do I free up disk space?</b></summary>

```bash
rm -rf "$CACHE_DIR"        # removes all cached raw and ready images
```

Cached files are versioned, so when a new release comes out the old files stay behind. List them with `--check` and delete the ones you no longer need.
</details>

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Security notice

The defaults are built for **homelab and testing convenience**: a well-known password, root SSH login, and password authentication all turned on. Before a VM touches anything you care about:

- Set a strong `DEFAULT_PASS`, or change passwords right after first login.
- Switch to SSH keys and turn off `PasswordAuthentication` and `PermitRootLogin`.
- Don't expose these VMs directly to the internet.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Contributing

PRs are welcome, especially for new distros and updated image URLs. See [CONTRIBUTING.md](CONTRIBUTING.md).

<sub>[↑ Back to contents](#table-of-contents)</sub>

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-or-later).

<sub>[↑ Back to contents](#table-of-contents)</sub>
