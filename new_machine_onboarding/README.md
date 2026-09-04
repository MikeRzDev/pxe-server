# Enrolling a new machine over network boot

End-to-end: from a bare PC on the LAN to a running Proxmox node, unattended.

> **This erases the target machine's disk with no confirmation.** The payload
> that does it (`proxmox-auto`) is deliberately separate from the interactive
> one (`proxmox`), and you have to select it on purpose.

## Two ways to do this

| | **Baked** (`proxmox-auto`) | **Fleet** (`proxmox-fleet`) |
|---|---|---|
| Answer file | baked into the ISO | fetched over HTTP at install time |
| Cost per machine | 1.7 GB ISO + 2 GB initrd, ~4 min build | one small text file |
| Machines at once | one | as many as you like |
| Targeting | the image *is* the machine's config | by MAC, or `default.toml` for any |
| Good for | a one-off | onboarding several PCs |

Both wipe the target. Both are built from the same stock ISO. **Fleet mode is
the one to use for more than a single machine** — the image is built once and
never again, and enrolling a PC becomes writing a file.

The rest of this document covers the baked path. Fleet mode is below it.

## What's in here

| File | What |
|---|---|
| `new-node.py` | pick an address, generate + save the root password, emit a validated answer file |
| `prepare-auto-iso.sh` | bake that answer file into a Proxmox ISO (runs the amd64-only assistant in Docker) |
| `nodes.env.example` | defaults: address range, gateway, DNS, domain |
| `nodes.yaml.example` | declarative definitions for several machines at once |
| `answer.toml.example` | annotated answer file, if you'd rather hand-write one |
| `secrets/<name>/` | **gitignored**, 0700 — that node's `credentials.env` (cleartext root password) and its own `id_ed25519` keypair |
| `nodes/` | **gitignored** — generated `<name>.answer.toml` files |

## One-time setup

```bash
cp nodes.env.example nodes.env && $EDITOR nodes.env
```

Set `NODE_IP_START`/`NODE_IP_END` to a range **outside your router's DHCP pool**,
plus the gateway, DNS and domain. This is the file that makes every later step a
one-liner.

## Enrolling a machine

### 1. Describe it

Any of these — they do the same thing:

```bash
./new-node.py                                  # interactive prompts
./new-node.py pve01                            # next free address in the range
./new-node.py pve01 --ip 192.0.2.35            # pin a static address
./new-node.py --file nodes.yaml                # several machines at once
```

Add `--dry-run` to see exactly what it would write, first.

Every address is checked **before anything is created**: a static address that
already answers a ping, one already claimed in `secrets/`, a malformed range, or
a pool with fewer free addresses than there are machines all fail immediately,
having written nothing.

It then generates a 32-character root password **and that machine's own SSH
keypair**, saving both to `secrets/<name>/` before anything else — a random
password that exists only as a hash is a password you have lost, along with the
node. The public half goes into the answer file as `root-ssh-keys`, so the node
accepts your key the moment it boots:

```
secrets/fermi/
  credentials.env     root password (clear + hash), address, ready-made ssh command
  id_ed25519          private key, 0600
  id_ed25519.pub      installed for root on that node
```

One key per machine rather than a shared one: the private half never leaves its
directory, and decommissioning a node is deleting its folder rather than
rotating a credential every node shares.

```bash
ssh -i secrets/fermi/id_ed25519 root@192.0.2.31
```

### 2. Bake the ISO

```bash
./prepare-auto-iso.sh nodes/pve01.answer.toml /path/to/proxmox-ve_9.2-1.iso
```

Needs Docker. `proxmox-auto-install-assistant` is published for **amd64 only**,
so on an arm64 host this runs it in a `--platform linux/amd64` container. It
does not have to run on the PXE server.

Confirm the answer file really landed in the image:

```bash
docker run --rm --platform linux/amd64 -v "$PWD:/work" pve-autoinstall:9.2 \
  proxmox-auto-install-assistant inspect-iso /work/proxmox-ve_9.2-1-auto.iso
```

Look for `Auto-install: enabled` and `Fetch mode: iso`.

### 3. Build the payload on the PXE server

```bash
scp proxmox-ve_9.2-1-auto.iso <user>@<pxe>:/srv/pxe/iso/
ssh <user>@<pxe>
sudo ~/pxe-server/payloads/build-proxmox.sh \
     --iso /srv/pxe/iso/proxmox-ve_9.2-1-auto.iso --name pve-auto
```

Takes a few minutes — it decompresses the installer initrd and appends the
1.7 GB ISO into it, producing ~2 GB.

### 4. Serve it

```bash
sudo pxectl proxmox-auto
sudo pxectl status          # confirm: serving : proxmox-auto
```

### 5. Boot the target

Set the machine to boot from the network — **UEFI PXE / IPv4**. Legacy BIOS
hits memory ceilings loading a 2 GB image and fails with `0x2a818006`.

What happens:

1. The firmware broadcasts DHCP. Your **router** answers with an address as
   usual; dnsmasq is in proxy-DHCP mode and only adds the boot information, so
   turning this on cannot disturb the LAN.
2. It fetches `ipxe.efi` over TFTP and runs it.
3. iPXE DHCPs again, this time tagged with option 175, so it gets
   `boot.ipxe` over HTTP instead of chainloading itself forever.
4. A menu appears saying the disk will be erased, defaulting to install
   after 15 s. There's an abort entry.
5. Kernel + 2 GB initrd over HTTP (~20 s on gigabit), then the installer runs
   unattended and reboots into Proxmox.

Watch the whole exchange:

```bash
sudo pxectl log
```

The thing to look for is that **second** DHCP request arriving tagged as iPXE.

### 6. Afterwards

```bash
~/scripts/pxe-stop.sh       # or: sudo pxectl proxmox   (back to interactive)
```

Do this. While `proxmox-auto` is being served, anything that netboots gets
wiped.

The node is at `https://<its address>:8006`, user `root@pam`, password in
`secrets/<name>.env`.

## Fleet mode: one image, many machines

Build the image **once**:

```bash
./prepare-auto-iso.sh --http http://<pxe-server>:8080/answer /path/to/proxmox-ve_9.2-1.iso
scp proxmox-ve_9.2-1-fleet.iso <user>@<pxe>:/srv/pxe/iso/
ssh <user>@<pxe> 'sudo ~/pxe-server/payloads/build-proxmox.sh \
     --iso /srv/pxe/iso/proxmox-ve_9.2-1-fleet.iso --name pve-fleet'
```

Confirm it carries no answer file and knows where to ask:

```
Auto-install:  enabled
Fetch mode:    http
HTTP URL:      http://<pxe-server>:8080/answer
```

Then enrol each machine — **no rebuild**:

```bash
ssh <user>@<pxe>                       # run it here and it publishes directly
cd ~/pxe-server/new_machine_onboarding
./new-node.py pve02 --serve --mac aa:bb:cc:dd:ee:ff
sudo -A pxectl proxmox-fleet
```

Run from anywhere else it writes locally and tells you to copy the file to
`/srv/pxe/answers/` yourself.

### How the machine is identified

The installer POSTs a description of itself — DMI data plus every NIC's MAC —
and the server matches those MACs against `/srv/pxe/answers/`:

```
aa:bb:cc:dd:ee:ff.toml     any spelling: colons, dashes or bare hex
aabbccddeeff.toml
default.toml               used when no MAC matches
```

A multi-NIC machine matches on **any** of its NICs.

> **Without `--mac` the answer is written as `default.toml`, which every
> machine matches.** That is fine when you are onboarding one PC at a time, and
> dangerous if several could netboot at once — they would all install the same
> hostname and IP. Pass `--mac` as soon as you have more than one.

Don't know the MAC yet? Either read it off the NIC/BIOS, or boot the machine
once against `proxmox-fleet` with no answer present: the request is refused
with a 404 and the MAC is logged, which is a harmless way to learn it.

```bash
sudo -A journalctl -u pxe-answer -f
# POST /answer from 192.168.1.87 macs=[a4bf01d2ee90] -> ... 
```

Nothing is installed on a 404, so this is safe.

### Checking it works

```bash
curl http://<pxe-server>:8080/health          # answer count
sudo -A journalctl -u pxe-answer -f              # one line per request
```

## The admin node: Proxmox Datacenter Manager

PDM is the management product for a PVE fleet. It is a **whole-disk install
like PVE**, so it needs its own machine — you cannot add it to an existing
node. It installs through exactly the same fleet machinery: its ISO carries the
same `auto-installer-capable` marker, the same `boot/linux26` + zstd
`boot/initrd.img` layout, and the same `initrdisoimage="/proxmox.iso"`
convention, and it uses the same `[global]`/`[network]`/`[disk-setup]` answer
schema. Only three things differ:

| | Proxmox VE | Datacenter Manager |
|---|---|---|
| payload | `proxmox-fleet` (dir `pve-fleet`) | `pdm-fleet` |
| builder | `payloads/build-proxmox.sh` | `payloads/build-pdm.sh` |
| web UI | `https://<ip>:8006` | `https://<ip>:8443` |

Build the payload once, from the Mac (the auto-install assistant is amd64-only,
so `prepare-auto-iso.sh` runs it in Docker — it takes a PDM ISO unchanged):

```bash
./prepare-auto-iso.sh --http http://<pxe-server>:8080/answer \
    proxmox-datacenter-manager_1.1-1.iso
# on the PXE server:
sudo ~/pxe-server/payloads/build-pdm.sh \
     --iso /srv/pxe/iso/proxmox-datacenter-manager_1.1-1-fleet.iso --name pdm-fleet
```

Then enrol the machine with the PDM wrapper, which arms `pdm-fleet` and passes
`--product pdm` through to `new-node.py`. Unlike `onboard-node.sh`, this one
puts the answer file in place **before** the target boots, so a single power-on
installs — no second reboot:

```bash
~/scripts/onboard-admin.sh <name> --ip <address>
```

One power-on, and the MAC does not need to be known: a netbooting machine shows
up in dnsmasq's log about 90 seconds before the installer asks for its answer
file, so the MAC is caught from that DHCP request and the answer written into
the same boot. The modes are shared with `onboard-node.sh` — both wrappers are
a few lines over `scripts/onboard-lib.sh`, which documents `--mac` (skip the
race), `--two-pass` (the old 404-discovery flow) and `--any-mac` (a wildcard
that is rarely the right answer now).

`--product pdm` only selects the product name and the web UI port; it records
`NODE_PRODUCT=pdm` and `NODE_URL=https://<ip>:8443` in `credentials.env` so the
Manhattan README links to the right port.

The answer server is shared and keys purely on MAC, so PDM and PVE answer files
coexist in `/srv/pxe/answers/` without conflict. But only **one payload is
served at a time** — while `pdm-fleet` is armed, a PVE node that netboots gets
the PDM installer paired with its own PVE answer file. Stop PXE as soon as the
admin node is in.

## The credential store, and why it is guarded

`secrets/<node>/` holds the **only** copy of each node's root password and SSH
key. `new-node.py` mints them once from a CSPRNG; the answer file keeps only a
hash. Lose the directory and the node is unreachable — there is no
regeneration path, only a console password reset or a reinstall.

On 2026-09-02 exactly that happened: the private keys and `credentials.env`
for fermi, dirac and lawrence disappeared from this store (only
`id_ed25519.pub` survived), and the Mac's mirror was then overwritten with the
same emptiness by its `sync-from-pi.sh`, which built files with `base64 -w0`
of a missing file — an empty string that `base64 -d` happily wrote as a
0-byte key while every command still exited 0. All three were recovered the
same day from an unrelated copy the operator happened to keep — nothing in
this repo would have brought them back, which is the whole reason for the
guard described here.

`scripts/secrets-guard.sh` exists so that cannot recur:

```bash
~/scripts/secrets-guard.sh verify        # does every stored key parse + match its .pub?
~/scripts/secrets-guard.sh backup        # snapshot -> /var/backups/pxe-secrets/<utc>/
~/scripts/secrets-guard.sh restore       # refill gaps from the newest good snapshot
~/scripts/secrets-guard.sh list          # which snapshots hold a good copy of what
sudo -A ~/scripts/secrets-guard.sh unprotect fermi   # before a deliberate rotation
```

Four properties, and each one is load-bearing:

- **Snapshots live outside this repo** (`/var/backups/pxe-secrets`), so a
  re-clone, `uninstall.sh`, or `rm -rf ~/pxe-server` cannot take them along.
- **Last-good copies are pinned.** Retention keeps the newest `KEEP=60`
  snapshots *plus* the newest snapshot holding a good copy of each node ever
  seen — including nodes no longer in the store. The copy you need after a
  loss is exactly the one a dumb retention policy would delete.
- **Everything is `chattr +i`.** Live secrets and snapshots are immutable, so
  a stray `rm -rf` fails instead of succeeding. A real rotation has to say
  `unprotect` first, on purpose.
- **`new-node.py` snapshots the moment credentials hit disk**, and
  `pxe-secrets-guard.timer` re-verifies hourly and silently restores anything
  that vanished. A failed unit means a genuinely unrecoverable loss.

The Mac mirror (`Manhattan/`) runs the same four rules under
`credentials-guard.sh`, and `Manhattan/restore-to-pi.sh` pushes back the other
way when this store is the one with the gap.

Snapshots are cleartext credentials, exactly like the originals: `0700`, this
host only, never in git.

## Requirements on the target

- **UEFI**, not legacy BIOS.
- **RAM**: the whole ISO lands in a ramdisk. 8 GB is comfortable, 16 GB roomy,
  4 GB will likely fail.
- **Disks**: the default `disk: auto` emits `filter.DEVNAME = "*"`, resolved on
  the machine — so a single-disk PC installs correctly whether its disk is
  `sda` or `nvme0n1`, with no need to inspect it first.
  **On a machine with more than one disk that is ambiguous**, and which one ext4
  picks is undocumented. See the next section.

## Choosing the disk on a multi-disk machine

`auto` is wrong here, and so, more subtly, is naming the device. Kernel names
are assigned in probe order: the disk you looked at as `sdb` can come up as
`sde` on the boot that actually installs. On a machine that still holds another
OS, that is the difference between wiping a spare disk and wiping everything.

**Select by serial instead.** It is the same on every boot.

**1. Look at what is in the machine — headlessly.** On the PXE server:

```bash
~/scripts/survey-node.sh
```

Then power the target on via its UEFI **PXE IPv4** entry and walk away. It
netboots SystemRescue into RAM, inventories every disk, POSTs the report back
and **reboots** (not powers off - that would need someone to press the button
again); `survey-node.sh` prints the report and disarms PXE.
**Nothing is written to the target** — SystemRescue runs entirely from RAM and
the survey only reads block-device metadata. Reports are kept at
`/srv/pxe/surveys/<mac>.txt`.

The report gives every disk's size, model, serial, partition labels, used and
free space, and flags any disk carrying NTFS or an EFI System Partition as one
to keep rather than install to. It leads with the machine's MACs, so the
enrolment that follows can pass `--mac` and skip the discovery race entirely.

Used and free space are read straight from each filesystem's own metadata
(`ntfsinfo`, `dumpe2fs`, `fsck.fat -n`, `xfs_db -r`) rather than by mounting
anything — `lsblk`'s `FSUSED`/`FSAVAIL` only ever report on a *mounted*
filesystem, so on a survey they would all be blank. Reading metadata also works
on an NTFS volume left dirty by Windows fast startup, which a read-only mount
would refuse outright.

**2. Pick from a menu rather than retyping a serial.**

```bash
~/scripts/pick-disk.sh <name>
```

It prints the reported disks numbered, with how full each one is and a verdict,
takes a number, asks for the node name typed back to confirm, and passes the
serial straight through to `onboard-node.sh --chain`. The serial is never
retyped by a human — a mistyped or stale one names the wrong disk, which is the
exact failure this whole path exists to prevent. It refuses when stdin is not a
terminal, warns when the report is older than the 90-minute hold, and refuses a
disk that reports no serial rather than falling back to a kernel name.

**If the target is not on the same switch as the PXE server**, add `--shadow` to
`survey-node.sh` and `onboard-node.sh`. Proxy-DHCP is passive and only answers a
DISCOVER it hears; a target behind another network device is invisible to it and
will hang with nothing in any log. See "Reaching the target" in `../README.md`.

Two manual variants, when a headless boot is not what you want:

```bash
# target still running Windows, must not be rebooted - elevated PowerShell:
#     tools/disk-survey.ps1

# any Linux shell, including a plain `pxectl rescue` boot:
curl -s http://<pxe-server>/tools/disk-survey.sh | bash -s -- --post
```

**2. Enrol with the serial the survey printed:**

```bash
~/scripts/onboard-node.sh pve01 --disk-serial S3Z9NB0M123456
```

which emits

```toml
[disk-setup]
filesystem = "ext4"
filter.ID_SERIAL_SHORT = "S3Z9NB0M123456"
filter-match = "all"
```

`--disk-filter KEY=GLOB[,KEY=GLOB]` takes any udev property when a serial is not
enough (`--disk-filter ID_MODEL=Samsung*,ID_BUS=nvme --filter-match all`), and
`--disk <name>` still works when you have just looked and are installing right
away. `--disk` and `--disk-filter` are mutually exclusive — the installer
accepts `disk-list` or `filter.*`, never both — and for `ext4`/`xfs` the
selection must resolve to **exactly one** disk.

The choice is recorded as `NODE_DISK=` in `secrets/<name>/credentials.env`,
because after the fact nothing else on the machine can tell you which disk was
erased.

### Dual-booting: keeping Windows

Installing to a second disk leaves the Windows one untouched, but Proxmox's
GRUB will not offer it. Afterwards, from the Mac:

```bash
ssh -i ~/Documents/DevOps/Manhattan/<node>/id_ed25519 root@<ip> \
    'bash -s' < tools/add-windows-boot-entry.sh
```

It finds the Windows Boot Manager on whichever ESP has one, writes a single
static `menuentry` into `/etc/grub.d/40_custom` keyed on that partition's
filesystem UUID, and runs `update-grub`. Pass `--dry-run` to see it first.

**Do not use `os-prober` for this on a Proxmox host.** It mounts every block
device it can find, guests' LVM volumes and disk images included, which is a way
to corrupt a running VM while regenerating a boot menu. Proxmox ships without it
deliberately.

## If it doesn't boot

| Symptom | Cause |
|---|---|
| Nothing happens, no TFTP in `pxectl log` | Firewall. Ports 67 and 4011 must be open to `any` — a PXE client has no address yet, so its `DHCPDISCOVER` is `0.0.0.0 -> 255.255.255.255` and never matches a subnet-scoped rule. `ufw` block logging is rate-limited and often logs *nothing*; use `tcpdump -i eth0 -n "port 67 or port 69"`. |
| iPXE loads, then loads iPXE again, forever | The second DHCP request isn't being tagged. Check `dhcp-match=set:ipxe,175` in `/etc/dnsmasq.d/pxe.conf`. |
| iPXE starts but the kernel/initrd 404 | nginx is down. On DietPi `/var/log` is a tmpfs, so `/var/log/nginx` vanishes each boot and nginx fails its own config test. `logdir.conf` handles it — check `systemctl status nginx`. |
| Loads, then fails unpacking the initrd | `ramdisk_size=16777216` missing from the cmdline, or the target hasn't enough RAM. |
| Installs, but interactively | The auto half is missing. Both are required: an ISO with the answer file baked in **and** `proxmox-start-auto-installer` on the cmdline. Confirm with `inspect-iso`, and that you're serving `proxmox-auto` rather than `proxmox`. |
