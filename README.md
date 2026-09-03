# `pxe_server` — deployable on-demand PXE boot server

Everything needed to stand up a network boot server on a fresh Debian host. This
is the **provisioning source**; the running copy lives on the target machine
(`/usr/local/sbin/pxectl`, `/etc/…`, `~/scripts/`).

The server is **image-agnostic** — it serves files over TFTP and HTTP and does
not care what they are. A payload is just a file:

```
/srv/pxe/http/boot-<name>.ipxe   ->   sudo pxectl <name>
```

Dropping that file in is the *entire* procedure for adding an image. There is no
registry in `pxectl`, in the systemd unit, or in `install.sh` to keep in sync.
Proxmox and SystemRescue ship as working examples, not as special cases.

Built for and running on a Raspberry Pi (DietPi, Debian 13), serving x86 clients
— Debian's `ipxe` package is `Architecture: all` and ships the x86 builds, so an
arm64 host serves x86 boot binaries fine. Nothing in here is Pi-specific; any
Debian host on the same LAN as the targets will do.

## Deploying to a brand new system

Requirements: Debian 12/13 (or DietPi), wired to the same LAN as the target
machines, ~10 GB free, and a **stable IP address** — it gets baked into the
dnsmasq and iPXE configs, so a DHCP change silently breaks stage 2.

```bash
scp -r pxe_server/ user@newhost:~/
ssh user@newhost

cd ~/pxe_server
sudo ./install.sh --dry-run          # review what it will do
sudo ./install.sh                    # apply

sudo ./payloads/build-proxmox.sh     # ~1.7 GB ISO -> 2.0 GB initrd
sudo ./payloads/build-rescue.sh      # optional, ~1.4 GB ISO -> 1.3 GB tree
sudo ./payloads/prepare-iso.sh NAME ISO_OR_URL    # anything else

sudo pxectl list                     # what is installed
~/scripts/pxe.sh proxmox
sudo pxectl status
```

`install.sh` auto-detects the interface, address and LAN from the default route.
Override any of it with `pxe.env` (see `pxe.env.example`). It is idempotent —
re-run it to push template changes.

Then set the target machine to boot from the network (**UEFI PXE / IPv4**) and
watch the handshake with `sudo pxectl log`.

## Usage once installed

```bash
~/scripts/pxe.sh             # list the installed images
~/scripts/pxe.sh <name>      # serve one of them
~/scripts/pxe-stop.sh        # stop everything

sudo pxectl list             # payload / state / size / description
sudo pxectl status           # services + ports + firewall rules in one view
sudo pxectl log              # follow the DHCP/TFTP exchange
```

One **templated** systemd service, parameterised by the image being served:
`pxe@<name>`. The instance name is the payload, and `ExecStartPre` points
`/srv/pxe/http/boot.ipxe` at that payload's boot script — failing the start if
the name is not installed, so a typo cannot leave the symlink on the previous
image. Nothing starts at boot.

`pxectl off` is the real off switch: it stops the payload *and* dnsmasq/nginx.
Plain `systemctl stop pxe@<name>` closes the firewall but deliberately leaves
the workers running — see the last section for why.

## What is in here

| Path | What |
|---|---|
| `install.sh` | idempotent installer, `--dry-run` supported |
| `uninstall.sh` | removes the machinery; `--purge-payloads` also deletes `/srv/pxe` |
| `pxe.env.example` | optional overrides for the auto-detected settings |
| `nodes.env.example` | defaults for `new-node.sh` (address range, gateway, domain) |
| `payloads/new-node.py` | provision nodes from prompts, flags or YAML: pick an IP, generate + save the password, emit the answer file |
| `nodes.yaml.example` | declarative node definitions for `new-node.py --file` |
| `payloads/prepare-auto-iso.sh` | bake an answer file into an ISO (runs the amd64-only assistant in Docker) |
| `payloads/answer.toml.example` | annotated answer file, validated against 9.2.7 |
| `payloads/prepare-iso.sh` | **generic**: take any ISO (file or URL), detect its family, unpack it and write a working `boot-<name>.ipxe` |
| `payloads/fetch-iso.sh` | the manual version: download any ISO and unpack it, writing no boot script |
| `payloads/build-proxmox.sh` | example: fetch the ISO, build the initrd with the ISO embedded |
| `payloads/build-rescue.sh` | example: fetch the ISO, unpack the archiso tree |
| `templates/` | every config file, with `@@PLACEHOLDER@@` values |
| `templates/srv/pxe/http/boot-EXAMPLE.ipxe` | starting point for a new image, with cmdline recipes |
| `templates/usr/local/sbin/pxectl` | the control script |
| `scripts/` | the `~/scripts` wrappers installed for the operator |
| `tools/disk-survey.sh` | run on a TARGET (SystemRescue or any Linux): every disk with serial, labels, free space, and a verdict on which are safe to wipe |
| `tools/disk-survey.ps1` | the same report from an elevated PowerShell, for a target still running Windows |
| `tools/add-windows-boot-entry.sh` | run on a node AFTER install: adds a Windows entry to its GRUB menu, without os-prober |

Payloads are **not** in here — a 2 GB initrd and a 1.7 GB ISO do not belong in
version control. `payloads/` rebuilds them from upstream instead.

### Placeholders

`install.sh` substitutes these into everything under `templates/`, and aborts if
any survive rendering:

| Placeholder | Default | Used by |
|---|---|---|
| `@@SERVER_IP@@` | detected | dnsmasq `dhcp-boot`, both `boot-*.ipxe` |
| `@@LAN_CIDR@@` | detected | `pxectl` firewall rules (TFTP/HTTP scope) |
| `@@LAN_NET@@` | from CIDR | dnsmasq `dhcp-range=…,proxy` |
| `@@IFACE@@` | detected | dnsmasq `interface=` |
| `@@SERVER_NAME@@` | `hostname -s` | cosmetic, iPXE menu titles |
| `@@ANSWER_DIR@@` | `/srv/pxe/answers` | the answer server's store |
| `@@SURVEY_DIR@@` | `/srv/pxe/surveys` | where `POST /survey` files disk inventories |
| `@@ANSWER_PORT@@` | `8080` | the answer server's port |

## Adding another image

Point `prepare-iso.sh` at an ISO — a local file or a URL — and it does the
whole thing: works out the installer family, copies only what that family
needs, and **writes a working `boot-<name>.ipxe`**.

```bash
sudo ./payloads/prepare-iso.sh rocky10 https://.../Rocky-10-x86_64-dvd.iso
sudo ./payloads/prepare-iso.sh arch    /srv/pxe/iso/archlinux.iso --start
```

| Family | Detected by | Command line it writes |
|---|---|---|
| `archiso` | `<dir>/x86_64/airootfs.sfs` | `archisobasedir=` + `archiso_http_srv=` |
| `anaconda` | `.treeinfo`, `images/pxeboot/` | `inst.repo=` |
| `casper` | `casper/` | `url=<the ISO>` — serves the ISO, does not unpack it |
| `alpine` | `apks/` | `alpine_repo=` + `modloop=` |
| `live` | `live/` | `boot=live fetch=<squashfs>` |
| `debian-netboot` | a `netboot.tar.gz` | `ip=dhcp` — the reliable Debian path |
| `debian-installer` | `install.amd/` | `ip=dhcp`, and warns that this initrd wants media |
| `proxmox` | `boot/linux26` | refused — see below |

Useful flags: `--dry-run` prints the boot script without changing anything,
`--start` serves it immediately, `--family` overrides detection, and
`--emit-template` also writes the `@@SERVER_IP@@` form into
`templates/srv/pxe/http/` so `install.sh` recreates it on a rebuild.

It **refuses Proxmox ISOs** on purpose and points at `build-proxmox.sh`: that
payload needs the ISO embedded in the initrd, which is surgery, not a cmdline.

An image it does not recognise still gets unpacked and still gets a
`boot-<name>.ipxe`, but with the command line left **blank**, every kernel and
initrd in the image listed in the file as comments, and `NOT BOOTABLE` in its
`pxectl list` description. It exits `3` to say so. Guessing a command line is
how you get a boot that fails confusingly, so it does not guess — fill in the
blank using `boot-EXAMPLE.ipxe`, which lists what each family expects.

`fetch-iso.sh` is still there for the same job done by hand: it unpacks an ISO
from a URL, prints the kernels and initrds it found, and writes no boot script.

Two optional header comments are the only metadata `pxectl` reads:

```
# pxe-description: Debian 13 netboot installer
# pxe-payload-dir: debian13
```

## Unattended Proxmox installs

Clicking through the Proxmox installer gets old fast. Proxmox supports a fully
automated install driven by an `answer.toml`, and this repo wires it up as its
own payload so the interactive one stays the default.

> **The unattended payload wipes the target's disk with no confirmation.** It is
> deliberately a separate payload (`proxmox-auto`) that you have to select — it
> is never what `pxectl proxmox` serves.

Two halves are required, and it silently falls back to the normal interactive
installer if either is missing:

1. an ISO with the answer file baked in, and
2. `proxmox-start-auto-installer` on the kernel command line
   (that's what `boot-proxmox-auto.ipxe` adds).

```bash
# 1. describe the target - generates a 32-char root password, saves it to
#    secrets/<name>.env FIRST, then writes and validates the answer file
cp nodes.env.example nodes.env && $EDITOR nodes.env    # your LAN, gitignored
./payloads/new-node.sh pve01                          # or --ip / --disk / --fs

# 2. bake it in  (needs Docker; see the amd64 note below)
./prepare-auto-iso.sh nodes/pve01.answer.toml /path/to/proxmox-ve_9.2-1.iso

# 3. build the payload on the PXE server
scp proxmox-ve_9.2-1-auto.iso user@pxe:/srv/pxe/iso/
sudo ./payloads/build-proxmox.sh --iso /srv/pxe/iso/proxmox-ve_9.2-1-auto.iso --name pve-auto

# 4. serve it
sudo pxectl proxmox-auto
```

**`proxmox-auto-install-assistant` is amd64-only** — Proxmox publishes no arm64
index at all, so on an arm64 PXE server or an Apple Silicon Mac it cannot be
installed. `new_machine_onboarding/prepare-auto-iso.sh` therefore runs it inside a
`--platform linux/amd64` container. It's emulated and takes a few minutes, but
it's a one-off, and it does not have to run on the PXE server.

`new-node.py` takes its input three ways — **interactive prompts**, **flags**, or
a **YAML/JSON file** (`nodes.yaml.example`) describing many nodes at once.
Settings resolve CLI > per-node > file defaults > `nodes.env` > built-in, and
`--dry-run` prints what it would write without touching anything.

Each node's address is either **static** (`ip: 192.0.2.31`) or **allocated**
(`ip: auto`) from a range you set — the first address that neither answers a
ping nor is already claimed in `secrets/`.

Every address is resolved in a **preflight pass before anything is created**, so
a static address that is already in use, an unusable range, or a pool with fewer
free addresses than there are nodes fails immediately and writes nothing. Doing
it inside the provisioning loop instead would leave a half-provisioned batch —
and since the password is written first, that is real state to clean up. It generates the password and
**writes it to `secrets/<name>.env` before doing anything else** —
a random 32-character password that exists only as a hash is a password you
have lost, along with the node it installs. `new_machine_onboarding/secrets/`,
`nodes/`, `nodes.env` and `nodes.yaml` are all gitignored.

The full walkthrough — from a bare PC to a running node, and what to check when
it does not boot — is in
[`new_machine_onboarding/README.md`](new_machine_onboarding/README.md).

The YAML reader is a **documented subset** parsed with the stdlib, not PyYAML —
which is absent from a stock macOS and DietPi Python, and on 3.14 needs a venv
to install. It handles nested mappings, `- ` lists, quoted scalars and comments,
and **raises on anything else** (flow style, anchors, tabs) rather than
misparsing it. A `.json` file works too.

**Use `root-password-hashed`, not `root-password`.** The answer file ends up
inside the ISO *and* inside the 2 GB initrd that this server hands out over
plain HTTP to the whole LAN. `new-node.sh` always emits the hashed form.

**Picking the disk without inspecting the machine.** ext4 and xfs accept
exactly one disk, and `disk-list = ["sda","nvme0n1"]` is rejected outright — so
you cannot list both names and let the absent one be skipped. A UDEV filter is
resolved on the target instead, so the default `filter.DEVNAME = "*"` installs
to whatever the single disk is called. On a machine with **more than one** disk
that is ambiguous and undocumented; pin those with `--disk nvme0n1`.

**`validate-answer` always exits 0**, even when it prints
`Error: Found issues in the answer file.` Its exit status is useless, so
`prepare-auto-iso.sh` matches its output instead — a script that trusts `$?`
here will happily bake a broken answer file.

If you would rather change the answer file without rebuilding a 2 GB initrd
each time, `prepare-iso --fetch-from http` makes the installer fetch it at
install time instead. Note it issues a **POST**, so a static-file nginx replies
`405` — you need `error_page 405 =200 $uri;` in the location block.

## Things that will bite you

These are the reason the bundle looks the way it does. Each one cost real
debugging time; none of them fail in a way that points at the cause.

- **Never stop dnsmasq/nginx from `pxe@.service`'s `ExecStop`.** It is the
  obvious way to make the workers follow the payload, and it fails two
  different ways. A *blocking* `systemctl stop` there **deadlocks** — this
  unit's stop job is running, the stop jobs it asks for sit `waiting` because
  systemd will not run them until the current job finishes, and the current job
  is blocked on exactly those. Adding `--no-block` trades that for a **race**:
  `systemctl restart pxe@<name>` then puts the restart's start jobs and the
  unblocked stop jobs in one transaction, the stops win, and the unit comes
  back `active` with both workers dead — PXE silently broken. So `ExecStop`
  closes the firewall only (which already makes the server unreachable), and
  `pxectl off` does the teardown from outside any unit lifecycle. Both failures
  were reproduced on 2026-08-01; recover a wedged one with
  `systemctl cancel <job-id>`.

- **`PartOf=` cannot express a discovered payload set.** It only names concrete
  instances, so it cannot follow `boot-*.ipxe` files that appear at runtime —
  which is why the drop-ins were removed. `install.sh` deletes stale copies on
  upgrade.

- **The DHCP firewall rules must not be scoped to the LAN.** A PXE client has no
  address when it sends `DHCPDISCOVER`, so ports 67 and 4011 must be open to
  `any`. `ufw` block logging is rate-limited and will often log *nothing*, so
  never conclude "no packet arrived" from an empty log — use `tcpdump`.

- **`/var/log` is a tmpfs on DietPi.** `/var/log/nginx` vanishes on every boot
  and nginx then fails its own config test, which looks like a PXE fault but is
  really an HTTP one. `nginx.service.d/logdir.conf` recreates it; it resets
  `ExecStartPre=` first because drop-ins *append* to that list, and appending
  alone would still run the failing test first.

## License

MIT — see [LICENSE](LICENSE).
