# Contributing

Thanks for helping improve **proxmox-linux-quick-deploy**! The most valuable contributions are new OS options, fixes for upstream image URLs that have moved, and bug fixes.

## Adding a new OS option

All OS definitions are in the `case "$OS_CHOICE" in` block of `create-instant-vm.sh`.

1. **Add a menu entry** with the next free number:
   ```bash
   echo "  [11] openSUSE Leap 15.6"
   ```
   Then update the prompt range (`Select OS (1-11)`).

2. **Add a `case` branch** that sets at least `IMG_NAME` and `IMG_URL`:
   ```bash
   11)
       IMG_NAME="openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2"
       IMG_URL="https://download.opensuse.org/distribution/leap/15.6/appliances/${IMG_NAME}"
       ;;
   ```
   Optional variables:

   | Variable | Values | When to set it |
   |---|---|---|
   | `BOOT_TYPE` | `bios` (default) / `uefi` | The image only boots with UEFI. |
   | `OS_TYPE` | `standard` (default) / `nixos` / `omarchy` / *new* | The OS needs its own customization path. |
   | `MEMORY`, `DISK_SIZE` | e.g. `4096`, `32G` | The OS needs more than the defaults. Only raise values the user didn't override (see the Omarchy branch). |

3. **Pick a stable image URL.** Prefer official mirrors and "latest" or "current" symlinks over date-stamped files. If the filename has to be discovered at runtime (see NixOS), fail with a clear error when discovery returns nothing.

4. **Customization.** The `standard` path creates the user (falling back from `sudo,adm` to `wheel`), sets passwords, and enables SSH password login. That's enough for most cloud images. If your OS needs something different, add a new `OS_TYPE` branch in the "Baking credentials" section. Keep the changes **idempotent**, and remember that `virt-customize --run-command` runs inside the guest image.

5. **Cloud-init.** If the image doesn't support cloud-init (like NixOS), exclude it in the `if [[ "$OS_TYPE" != "nixos" ]]` block.

6. **Docs.** Add a row to the *Supported operating systems* table in `README.md`. Add a "How X works" section if it behaves differently.

## Testing locally

You need a **Proxmox VE test node**, ideally a nested PVE VM or a spare host. Don't test on production.

```bash
# 1. Static checks (required, CI-equivalent)
bash -n create-instant-vm.sh
shellcheck create-instant-vm.sh

# 2. Use a throwaway cache so you start fresh
CACHE_DIR=/tmp/qd-test OS_CHOICE=11 ./create-instant-vm.sh

# 3. Verify the VM
qm terminal <vmid>                         # serial console login
qm guest cmd <vmid> network-get-interfaces # guest agent + IP
ssh admin@<ip>                             # password login

# 4. Clean up
qm stop <vmid> && qm destroy <vmid> --purge
rm -rf /tmp/qd-test
```

Checklist before you open a PR:

- [ ] `shellcheck` passes with no new warnings.
- [ ] A fresh run (empty cache) and a cached run both work.
- [ ] You can log in as both `DEFAULT_USER` and `root`, on the console and over SSH.
- [ ] `CACHE_DIR` auto-detection still works when it's unset (check the "Image cache" line from `--check`).
- [ ] Nothing is installed, downloaded or created before the user confirms. Anything new that changes the host must appear in the `--check` report and the deployment plan.
- [ ] Existing OS options are unaffected. Re-test at least one, such as Debian 12.

## Testing storage detection without Proxmox

The detection logic reads `pvesm` and `STORAGE_CFG`, so you can try it on any Linux box with stub commands:

```bash
mkdir -p /tmp/mock/bin
printf '#!/bin/bash\nexit 0\n' | tee /tmp/mock/bin/{qm,pvesh,virt-customize,libguestfs-test-tool} >/dev/null
cat > /tmp/mock/bin/pvesm <<'EOF'
#!/bin/bash
[[ $1 == status ]] && printf 'Name Type Status\nlocal dir active\n'
EOF
chmod +x /tmp/mock/bin/*
printf 'dir: local\n\tpath /tmp/mock\n\tcontent iso,images\n' > /tmp/mock/storage.cfg
sudo env PATH=/tmp/mock/bin:$PATH STORAGE_CFG=/tmp/mock/storage.cfg ./create-instant-vm.sh --check
# -> Image cache (downloads + customized images):
#      /tmp/mock/cloud-images
```

## Submitting a pull request

1. Fork the repo and create a branch: `git checkout -b add-opensuse`.
2. Keep each PR focused on one OS or one fix.
3. Write commit messages in the imperative mood, e.g. `Add openSUSE Leap 15.6 option`.
4. In the PR description, include your PVE version, the storage type you tested on, and the console output of a successful run.
5. Be ready to update URLs if reviewers find a more stable mirror.

## Code style

- Bash, `set -e`, and quote every variable expansion.
- Every setting can be overridden from the environment (`VAR="${VAR:-default}"`).
- Send user-facing messages to stdout as `[*] …`, and errors to stderr as `[!] …`.
- Never commit downloaded images. `.gitignore` covers `*.qcow2`, `*.img`, `ready-*`, and `cloud-images/`.
