---
name: pxe-enrolment
description: >-
  Install Proxmox VE or Proxmox Datacenter Manager onto a bare-metal x86 machine
  over the network, unattended, using this repo's on-demand PXE server — and
  stand up a new PXE server host (Raspberry Pi, DietPi, Debian) from a clean OS.
  Use this whenever the user wants to enroll, onboard, provision, image or
  reinstall a Proxmox node or a PDM admin node; netboot or PXE-boot a machine;
  pick which disk an installer may erase on a multi-disk or dual-boot box;
  survey a machine's disks and NICs without writing to it; reach a target that
  sits behind a different router or switch from the boot server; or build a
  second/replacement PXE provisioning server. Covers proxy-DHCP, iPXE
  chainloading, answer files, disk selection by serial, and the DHCP-offer
  shadow for targets on another network segment.
---

# Network-installing a Proxmox node, and building the server that does it

This repo is an **on-demand** PXE server: a templated systemd service, disabled
at boot, that serves one *payload* (an image) at a time over TFTP and HTTP. In
fleet mode the installer fetches a per-machine answer file keyed on its MAC, so
a target is enrolled with **one power-on** and nobody goes back to the machine.

Enrolment mints a root password and an SSH key that exist in exactly two places
and **cannot be regenerated**. Read *Rules that will bite* before running
anything.

## Roles and placeholders

Used verbatim in every command below.

| Placeholder | Means |
|---|---|
| `PXE_HOST` | ssh alias of the machine running this repo (the Pi) |
| `PXE_IP` | its static LAN address, e.g. `192.0.2.10` |
| `NODE` | the name the new machine will get, e.g. `pve07` |
| `TARGET_MAC` | the target's boot NIC MAC — you never have to know it in advance |
| `SECRET_STORE` | the operator workstation's mirror of the credentials |

The repo lives at **`$HOME/pxe-server`** on the server (hyphen — several scripts
hardcode it), and `install.sh` copies `scripts/*.sh` into `$HOME/scripts/`.

## Which flow

| Enrolling | Command | Detail |
|---|---|---|
| A Proxmox VE node | `~/scripts/onboard-node.sh NODE` | [references/enrol-node.md](references/enrol-node.md) |
| A PDM admin node | `~/scripts/onboard-admin.sh NODE --ip <addr>` | same file — same engine, `pdm-fleet` payload, UI on **8443** not 8006 |
| A new PXE server host | `scripts/bootstrap-pxe-pi.sh` | [references/pi-bootstrap.md](references/pi-bootstrap.md) |

`onboard-node.sh` and `onboard-admin.sh` are three-line wrappers over one engine
(`scripts/onboard-lib.sh`), so every flag below works identically on both.

## Before starting: where does the target sit?

**Ask the user.** Proxy-DHCP is passive — dnsmasq only ever speaks because it
*overheard* the target's DHCP DISCOVER. A target the server cannot hear gets no
answer, and **nothing appears in any log**. This one fact decides the command:

| Answer | Use |
|---|---|
| Same switch / same segment as the PXE server | nothing extra |
| Behind another router or network device | `--shadow` |
| Don't know / no answer | run **plain first**; if it times out with no TFTP, retry with `--shadow` |

Say up front that the unknown case may cost one wasted boot. Do not silently
guess.

`--shadow` starts `tools/dhcp-offer-shadow.py`, which watches for the *router's*
DHCP OFFER (which does cross a router) and immediately sends a matching ProxyDHCP
offer — `yiaddr 0.0.0.0`, so it is not a lease and the router stays the only DHCP
server. It is **never harmful**, only sometimes unnecessary: if both mechanisms
answer, the client takes either and lands on the same iPXE. It stays opt-in only
because it puts the NIC in promiscuous mode.

`--shadow` needs `ipxe-chain.efi`, which carries the server address compiled in.
Build it once per server: `sudo ~/pxe-server/payloads/build-ipxe-chain.sh`.

## Procedure

### 0. Preflight

```bash
ssh PXE_HOST 'sudo pxectl status; ~/scripts/fleet-status.sh --no-write'
```

Confirm nothing is already armed. If a payload is active, finish or stop that
job first — two payloads cannot be served at once, and a machine that netboots
during the wrong window gets the wrong installer.

### 1. Enrol — one command, survey first

```bash
ssh PXE_HOST
~/scripts/onboard-node.sh NODE                 # add --shadow if decided above
```

The default is **survey first**: the target netboots a read-only SystemRescue,
reports its NICs and every disk, and then *holds*. That hands over the MAC
exactly (no DHCP race) and the disk list exactly (no `auto` guess).

Power the target on and pick its **`PXE IPv4`** entry from the firmware's
one-time boot menu (F11/F12/Esc at POST). Then walk away — the release, the
reboot and the install are all automatic.

### 2. Disk selection

- **One disk** — chosen automatically, by serial, saying what was on it. Nothing
  is asked.
- **Several disks** — the script refuses, prints the table and stops with rc 2.
  Nothing is written, no credentials are minted, and the machine is **still
  holding**, so naming a disk releases it.

Show the user the table and let them choose. Then either:

```bash
~/scripts/pick-disk.sh NODE                          # numbered menu, on a terminal
~/scripts/onboard-node.sh NODE --disk-serial <S>     # or name the serial
```

`pick-disk.sh` is the better option when a human is at a terminal: it prints
used/free per disk, takes a number, and requires the node name typed back — so a
20-character serial is never retyped by hand, which is its own way of erasing the
wrong disk. **It requires a TTY and cannot be driven over a non-interactive
ssh** — hand the user the two lines to run rather than trying to pipe into it.

### 3. Verify, then save the credentials

The script disarms PXE itself once the answer has been collected. Serving an
answer file and the node actually finishing its install are **two different
events**:

```bash
ssh -i SECRET_STORE/NODE/id_ed25519 root@<addr> pveversion
```

Then mirror the credentials to the operator workstation — immediately after the
answer is served, and again once the node is up. On this fleet that is
`sync-from-pi.sh`; see the private fleet skill or `CLAUDE.md` for the exact path.

### 4. Turn PXE off

```bash
ssh PXE_HOST '~/scripts/pxe-stop.sh'
```

Nothing PXE-related runs at boot by design, but while a payload is armed,
anything that netboots on this LAN against the wrong menu entry could hit it.

## Rules that will bite

- **`PXE IPv4`, never `HTTP IPv4`.** Some boards offer both. This server answers
  only classic PXE (vendor class `PXEClient`); UEFI's native HTTP Boot is
  `HTTPClient:Arch:00016` and matches no rule here, so dnsmasq never replies at
  all — the firmware retries forever with nothing in any log. (Step 1.)
- **Secure Boot must be off** on any netbooted target. iPXE, the SystemRescue
  kernel and the Proxmox installer are all unsigned. (Step 1.)
- **Never select a disk by device name.** Kernel names are handed out in probe
  order: one machine reported the same physical disk as `nvme1n1`, `nvme2n1` and
  `nvme3n1` on three consecutive boots. `--disk auto` is undefined with more than
  one disk. Only `--disk-serial` is stable. (Step 2.)
- **Two paths deliberately leave PXE armed — do not "fix" them.** The multi-disk
  return (the machine is still holding) and the answer-served-but-not-collected
  timeout (disarming would leave that reboot with nothing to boot into). Both say
  so on stdout. (Steps 2, 3.)
- **Don't ask about disk count or MAC.** The survey answers both. And serve the
  answer file with default settings — no dry-run, no y/N confirmation. (Step 1.)
- **Credentials cannot be regenerated.** `secrets/NODE/` on the server and
  `SECRET_STORE/NODE/` on the workstation are the only two copies; the answer
  file keeps only a hash. Lose both and the node needs a console password reset
  or a reinstall. Snapshot before any destructive step, never overwrite a good
  file with a bad one, and never treat "can't read it" as "it's empty". (Step 3.)
- **Never re-run `install.sh` while a payload is armed.** It disables the workers
  while `pxe@<payload>` stays `active`, so `pxectl status` still claims to be
  serving while nothing answers. Recover with `pxe-stop.sh` then
  `pxe.sh <payload>`.
- **`~/scripts/*.sh` are copies, not symlinks.** Re-run `install.sh` after
  editing anything under the repo's `scripts/`.
- **Never install `os-prober` on a Proxmox host** to add a Windows boot entry —
  it mounts every block device it finds, guests' LVM volumes and disk images
  included, and can corrupt a running VM while merely regenerating a boot menu.
  Use `tools/add-windows-boot-entry.sh`, which writes one static `menuentry`.
- **Build on `/srv/pxe`, never `/tmp`** — `/tmp` is a small tmpfs on a Pi and
  filling it breaks `install.sh` in confusing ways.

## When it does not work

Read [references/troubleshooting.md](references/troubleshooting.md) **before**
forming a theory. The dominant failure mode here is silence, and silence has at
least four distinct causes that look identical from the server.

Two rules that belong in your head rather than in a file, because they make you
draw wrong conclusions from real evidence:

- **The PXE site logs to `/var/log/nginx/pxe-access.log`**, not `access.log`.
- **`journalctl --since "23:40"` means *today* at 23:40** — a future time returns
  nothing at all, which reads exactly like "no events".

## Also here

- `docs/specs/rescue-ssh-enrolment.md` — a proposed redesign that would replace
  the survey/hold/release machinery and the shadow with SSH into a small rescue
  image. **Status: proposed, not implemented.** Do not build against it.
