# Standing up a new PXE server host

For a Raspberry Pi (DietPi or Raspberry Pi OS) or any Debian-family box that
will provision Proxmox machines. Debian's `ipxe` package is `Architecture: all`
and ships `ipxe-amd64.efi`, so an **arm64 Pi serves x86 clients perfectly well**.

## Prerequisites

- Debian 12/13, DietPi, or Raspberry Pi OS, freshly installed
- Wired to the same LAN as the targets — or at least reachable from them; see
  the shadow discussion in [enrol-node.md](enrol-node.md)
- ~10 GB free for payloads
- **A static address.** This is the one that bites: the address is baked into
  `dnsmasq`'s config and into the iPXE scripts at install time, so a DHCP lease
  that changes later silently breaks stage 2 — TFTP still hands out iPXE and then
  the kernel and initrd 404.
- A normal user with sudo. Do not run any of this as root directly: the
  checkout, `~/scripts` and the secrets store all belong to the operator user.

## The one command

```bash
# on the new host
sudo ./bootstrap-pxe-pi.sh --dry-run          # look first
sudo ./bootstrap-pxe-pi.sh \
     --server-ip 192.0.2.10 \
     --domain lan --gateway 192.0.2.1 --dns 9.9.9.9 \
     --ip-range 192.0.2.31-192.0.2.54
```

or from a workstation, without copying it over:

```bash
ssh newpi 'bash -s -- --dry-run' < scripts/bootstrap-pxe-pi.sh
```

It is idempotent — re-run it to update the checkout and re-apply the install.

## What it does, and why each step exists

1. **Preflight.** Detects the interface and address, warns if the address is a
   DHCP lease (the kernel flags those `dynamic`), and checks free space.

2. **Clones to `$HOME/pxe-server`** — with a hyphen. `onboard-lib.sh`,
   `survey-node.sh`, `fleet-status.sh` and `secrets-guard.sh` all hardcode that
   path, while the repo README's `scp -r pxe_server/` line does not match it. A
   checkout under any other name leaves those four resolving paths that do not
   exist, and the failures are indirect. Fixing that mismatch is a good part of
   why this script exists.

3. **Writes `pxe.env`** (gitignored) if you gave it network flags; otherwise
   `install.sh` auto-detects from the default route, which is usually right.

4. **Writes `new_machine_onboarding/nodes.env`** (gitignored). Mandatory for
   `new-node.py` and documented nowhere else. It reads *only* this file for the
   defaults handed to new nodes, and only the keys its `load_env_file()` knows:

   ```
   NODE_DOMAIN  NODE_GATEWAY  NODE_DNS  NODE_TIMEZONE  NODE_COUNTRY
   NODE_KEYBOARD  NODE_MAILTO  NODE_CIDR_BITS  NODE_DISKS  NODE_FS
   NODE_SSH_KEY  NODE_DISK_FILTER  NODE_FILTER_MATCH
   NODE_IP_START + NODE_IP_END  ->  the address pool
   ```

   **Any other key in that file is silently ignored**, so a typo costs you a
   default without saying so.

5. **Grants NOPASSWD sudo** to the operator user, via a `visudo -c`-validated
   fragment in `/etc/sudoers.d/`. This is the single biggest undocumented
   prerequisite: the operator scripts call `sudo -A` in 46 places, and without
   NOPASSWD or a `$SUDO_ASKPASS` helper they all fail with `sudo: no askpass
   program specified`. If you would rather not grant it, set `SUDO_ASKPASS` in
   the operator's profile instead and pass `--skip-install`... then run
   `install.sh` yourself.

6. **Runs `install.sh`**, which is the authoritative folder-structure spec:

   | Path | Owner | Mode |
   |---|---|---|
   | `/srv/pxe/{tftp,http,iso}` | `user:user` | 0755 |
   | `/srv/pxe/answers` | `user:www-data` | **0750** |
   | `/srv/pxe/surveys` | `www-data:user` | **0775** |
   | `/srv/pxe/http/go` | `www-data:user` | **0775** |
   | `/var/backups/pxe-secrets` | `user:user` | **0700** |
   | `$HOME/scripts` | `user:user` | 0755 |

   plus `/etc/dnsmasq.d/pxe.conf`, the nginx site, `pxe@.service`,
   `pxe-answer.service`, `pxe-secrets-guard.{service,timer}`,
   `/usr/local/sbin/{pxectl,pxe-answer-server}`, and the
   `nginx.service.d/logdir.conf` drop-in that recreates `/var/log/nginx` on a
   host where `/var/log` is a tmpfs.

   It also installs the packages (`dnsmasq nginx ipxe zstd cpio wget ufw`) and
   **disables dnsmasq, nginx and pxe-answer at boot** — this server is on-demand
   by design.

7. **Verifies** every path, owner and mode above, that `pxectl` and the units
   landed, that `pxe-secrets-guard.timer` is enabled, and that nothing
   PXE-related is enabled at boot.

8. **Prints the payload builds it deliberately did not run.**

## What it does not do

- **No ISOs, no payloads.** Those are multi-GB and slow on a Pi:

  ```bash
  sudo ~/pxe-server/payloads/build-proxmox.sh      # ~2.0 GB payload
  sudo ~/pxe-server/payloads/build-rescue.sh       # ~1.3 GB, also gives you `survey`
  sudo ~/pxe-server/payloads/build-ipxe-chain.sh   # only if you need --shadow
  ```

  The fleet payloads need an ISO prepared by `prepare-auto-iso.sh` first, which
  is amd64-only and runs in Docker — do that on a workstation and copy the ISO
  over the LAN. A payload is just a `/srv/pxe/http/boot-<name>.ipxe` file
  discovered at runtime, so adding an image means dropping a file in; there is no
  list to edit. `prepare-iso.sh NAME ISO` writes that file for you for most Linux
  families.

- **No credentials.** If this host replaces an existing server, the per-node
  secrets store must be moved across deliberately — it cannot be regenerated,
  and it is the one thing on the old machine that matters. Copy it, verify with
  `secrets-guard.sh verify` on the new host, and only then retire the old one.

## After it finishes

```bash
sudo pxectl list                # what is installed
sudo pxectl status              # everything should read inactive / disabled
~/scripts/pxe.sh <payload>      # arm one
~/scripts/pxe-stop.sh           # turn it off
```

Then enrol something: [enrol-node.md](enrol-node.md).

## Updating an existing server

Same script, or by hand — `install.sh` is idempotent and is the upgrade path:

```bash
cd ~/pxe-server && git pull && sudo ./install.sh
```

Two things to remember:

- **Never do this while a payload is armed.** `install.sh` disables the workers
  while `pxe@<payload>` stays `active`, so `pxectl status` keeps claiming to
  serve while nothing answers. Re-arm afterwards.
- **`~/scripts/*.sh` are copies, not symlinks.** Any edit to the repo's
  `scripts/` needs an `install.sh` re-run to take effect.
