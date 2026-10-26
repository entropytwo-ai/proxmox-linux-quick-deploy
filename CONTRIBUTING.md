# Contributing

Thanks for helping improve **proxmox-linux-quick-deploy**! The most valuable contributions are new OS options, fixes for resolvers whose upstream layout has changed, and bug fixes.

## Adding a new OS option

OS options are discovered at runtime, not hard-coded. Each one is a **resolver function** plus a line in the `OS_MENU` array, both in the "Image discovery" section of `create-instant-vm.sh`.

1. **Add a menu entry** at the **end** of `OS_MENU`. The menu number is the array position, so adding to the end keeps every existing `OS_CHOICE` number working:
   ```bash
   OS_MENU=(
       ...
       "mydistro|MyDistro (newest)"
   )
   ```

2. **Write `resolve_<id>()`**, with dashes in the id replaced by underscores (`debian-stable` → `resolve_debian_stable`). It must find the **newest** release from the distro's own metadata or directory listing, and set:

   | Variable | Required | Meaning |
   |---|---|---|
   | `IMG_URL` | yes | Direct URL of a **dated/versioned** file. Avoid moving aliases like `latest`, so the checksum and cache name match what was downloaded. |
   | `IMG_NAME` | yes | Versioned cache filename, e.g. `fedora-44-1.7.qcow2`. A new release then gets a new name and is downloaded fresh. |
   | `OS_LABEL` | yes | Human-readable name including the resolved version. |
   | `SUM_URL` | strongly recommended | The checksum file for `IMG_URL`. GNU (`hash  name`), BSD (`SHA256 (name) = hash`) and bare-hash formats are parsed automatically, SHA256 or SHA512. |
   | `BOOT_TYPE` | optional | `bios` (default) / `uefi`. |
   | `OS_TYPE` | optional | `standard` (default) / `nixos` / `omarchy` / *new*. |

   Use the helpers `fetch` (curl with timeouts and retries), `url_ok` (does the URL really serve a file?), `hrefs '<regex>'` (links from a directory listing) and `newest` (version sort). Return non-zero when nothing is found. `resolve_fedora` and `resolve_rocky` are good, tested templates. The shape is:

   ```bash
   # Template: replace the URL and regexes with the distro's real layout.
   resolve_mydistro() {
       local base="https://mirror.example.org/mydistro/" v file
       # Walk from the newest version down until one actually has a cloud image.
       while read -r v; do
           [[ -z "$v" ]] && continue
           file=$(fetch "${base}${v}/cloud/" 2>/dev/null \
               | grep -oE "mydistro-${v}-[0-9.]+-x86_64\.qcow2" | newest)
           [[ -z "$file" ]] && continue
           IMG_URL="${base}${v}/cloud/${file}"
           SUM_URL="${base}${v}/cloud/SHA256SUMS"
           IMG_NAME="${file}"
           OS_LABEL="MyDistro ${v}"
           return 0
       done < <(fetch "$base" | hrefs '[0-9]+/' | tr -d / | sort -rn | sed -n '1,3p')
       return 1
   }
   ```

   Check what your mirror's listing really looks like first (`curl -s <dir> | grep -o 'href="[^"]*"'`). Some use `href="./16.0/"` instead of `href="16.0/"`, and legacy version numbers can sort above the current one.

   Rules of thumb:
   - **Walk down, don't assume.** The newest release dir often exists before its cloud image does (Fedora 42 never had one). Try the newest few candidates and take the first that has an image.
   - **No version numbers in code.** If you find yourself typing `44` or `trixie`, read it from upstream metadata instead.
   - **Keep it quick.** A resolver should take a few HTTP requests. `--list` and `--check` run every resolver.
   - Prefer listings via `sed -n '1,Np'` over `head -n N` when reading from `curl`, so curl doesn't print "Failure writing output" errors.

3. **Customization.** The `standard` path creates the user (falling back from `sudo,adm` to `wheel`), sets passwords, and enables SSH password login. That's enough for most cloud images. If your OS needs something different, add a new `OS_TYPE` branch in the "Baking credentials" section. Keep the changes **idempotent**. `virt-customize --run-command` runs inside the guest image and needs an image that libguestfs' OS inspection recognises. If it doesn't (like NixOS, which has no `/etc` until first boot), use `guestfish` the way `customize_nixos` does, and read the result back before caching it.

4. **Cloud-init.** If the image doesn't support cloud-init (like NixOS), exclude it in the `if [[ "$OS_TYPE" != "nixos" ]]` block.

5. **Docs.** Add rows to the *Supported operating systems* and *Automatic version discovery* tables in `README.md`. Add a "How X works" section if it behaves differently.

## Testing locally

You need a **Proxmox VE test node**, ideally a nested PVE VM or a spare host. Don't test on production.

```bash
# 1. Static checks (required, CI-equivalent)
bash -n create-instant-vm.sh
shellcheck create-instant-vm.sh

# 2. Check every resolver finds an image (no root/Proxmox needed)
./create-instant-vm.sh --list

# 3. Use a throwaway cache so you start fresh
CACHE_DIR=/tmp/qd-test OS_CHOICE=<your-id> ./create-instant-vm.sh

# 4. Verify the VM
qm terminal <vmid>                         # serial console login
qm guest cmd <vmid> network-get-interfaces # guest agent + IP
ssh admin@<ip>                             # password login

# 5. Clean up
qm stop <vmid> && qm destroy <vmid> --purge
rm -rf /tmp/qd-test
```

Checklist before you open a PR:

- [ ] `shellcheck` passes with no new warnings.
- [ ] A fresh run (empty cache) and a cached run both work.
- [ ] You can log in as both `DEFAULT_USER` and `root`, on the console and over SSH (NixOS: root by console only).
- [ ] `CACHE_DIR` auto-detection still works when it's unset (check the "Image cache" line from `--check`).
- [ ] Nothing is installed, downloaded or created before the user confirms. Anything new that changes the host must appear in the `--check` report and the deployment plan.
- [ ] `./create-instant-vm.sh --list` resolves every entry, and the new image's checksum is verified on download (`[ok] SHA… checksum verified`).
- [ ] Existing OS options are unaffected. Re-test at least one, such as `debian-stable`.

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
