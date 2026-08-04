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

## Requirements on the target

- **UEFI**, not legacy BIOS.
- **RAM**: the whole ISO lands in a ramdisk. 8 GB is comfortable, 16 GB roomy,
  4 GB will likely fail.
- **Disks**: the default `disk: auto` emits `filter.DEVNAME = "*"`, resolved on
  the machine — so a single-disk PC installs correctly whether its disk is
  `sda` or `nvme0n1`, with no need to inspect it first.
  **On a machine with more than one disk that is ambiguous** and which one ext4
  picks is undocumented. Identify it first and pin it:

  ```bash
  sudo pxectl rescue        # netboot the target, then run: lsblk
  ./new-node.py pve01 --disk nvme0n1
  ```

## If it doesn't boot

| Symptom | Cause |
|---|---|
| Nothing happens, no TFTP in `pxectl log` | Firewall. Ports 67 and 4011 must be open to `any` — a PXE client has no address yet, so its `DHCPDISCOVER` is `0.0.0.0 -> 255.255.255.255` and never matches a subnet-scoped rule. `ufw` block logging is rate-limited and often logs *nothing*; use `tcpdump -i eth0 -n "port 67 or port 69"`. |
| iPXE loads, then loads iPXE again, forever | The second DHCP request isn't being tagged. Check `dhcp-match=set:ipxe,175` in `/etc/dnsmasq.d/pxe.conf`. |
| iPXE starts but the kernel/initrd 404 | nginx is down. On DietPi `/var/log` is a tmpfs, so `/var/log/nginx` vanishes each boot and nginx fails its own config test. `logdir.conf` handles it — check `systemctl status nginx`. |
| Loads, then fails unpacking the initrd | `ramdisk_size=16777216` missing from the cmdline, or the target hasn't enough RAM. |
| Installs, but interactively | The auto half is missing. Both are required: an ISO with the answer file baked in **and** `proxmox-start-auto-installer` on the cmdline. Confirm with `inspect-iso`, and that you're serving `proxmox-auto` rather than `proxmox`. |
