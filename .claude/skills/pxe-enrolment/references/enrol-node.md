# Enrolling a node — every mode and flag

Read [../SKILL.md](../SKILL.md) first. This file is the full surface, for when
the default path does not fit.

## The two wrappers

Both are three-line shims over `scripts/onboard-lib.sh`, so the flag list is
identical:

```bash
~/scripts/onboard-node.sh  NODE            # -> payload proxmox-fleet, product pve, UI 8006
~/scripts/onboard-admin.sh NODE --ip ADDR  # -> payload pdm-fleet,     product pdm, UI 8443
```

PDM is a **whole-disk install like PVE**, so it gets its own machine, not a slot
on an existing node. There is normally exactly one on a fleet.

**While `pdm-fleet` is armed it is the only payload served.** `boot.ipxe` is a
symlink pointing at one payload at a time, so a PVE node that netboots during
that window would get the PDM installer paired with its own PVE answer file.
Both scripts disarm themselves; if you ever arm one by hand, run
`~/scripts/pxe-stop.sh` when you are done.

## Flags

| Flag | Effect |
|---|---|
| `NODE` | positional, required, first |
| `--shadow` | run `tools/dhcp-offer-shadow.py` for the wait — for a target behind another router |
| `--mac MAC` | you already know it; removes the DHCP race entirely |
| `--disk-serial SERIAL` | select the install disk by serial; validated against the survey report before use |
| `--resurvey` | force a fresh survey instead of reusing a report under 90 min old |
| `--chain` | drop the release file for a machine already held by a survey; requires a MAC |
| `--no-survey` (= `--watch`) | skip to the installer: MAC caught from DHCP mid-boot, disk left to `auto`. ~2 min faster and blind about disks |
| `--two-pass` | old 404-discovery flow; costs a second manual reboot |
| `--any-mac` | wildcard `default.toml` — **wipes anything that netboots.** The default mode gets the same result without it |
| `--keep-armed` | skip the automatic disarm; for enrolling several machines back to back |
| anything else | forwarded verbatim to `new-node.py` |

Useful pass-throughs: `--ip`, `--fs ext4|xfs|zfs|btrfs`, `--disk-filter
KEY=GLOB[,KEY=GLOB]`, `--filter-match any|all`, `--mailto`. `--disk` and
`--disk-filter` are mutually exclusive; `--disk-serial` is shorthand for
`--disk-filter ID_SERIAL_SHORT=<S>`. For `ext4`/`xfs` the selection must resolve
to **exactly one** disk. Note the installer's own default is `--filter-match
any`, which is the dangerous direction — this tooling defaults to `all`.

Environment: `PXE_WAIT_SECS` (default 900), `PXE_SHADOW`, `PXE_ANSWER_DIR`,
`PXE_SURVEY_DIR`, `PXE_GO_DIR`.

## What the default run actually does

1. Starts the shadow, if asked.
2. **Survey** — arms the read-only `survey` payload and waits. The target
   netboots SystemRescue into RAM, inventories every disk, POSTs a report and
   then *holds*, polling `http://PXE_IP/go/<mac>.txt` for its release.
   A report younger than 90 minutes is reused rather than re-surveyed, because a
   held machine never netboots again on its own. Several recent reports and no
   `--mac` is an error: name one.
3. **Disk** — exactly one disk selects itself by serial. Two or more returns
   rc 2, prints the table, and stops **without disarming**.
4. **Serve** — `sudo ./new-node.py NODE --mac <mac> --product <pve|pdm> --serve`,
   which mints the password and key, writes the answer file, and copies it to
   `/srv/pxe/answers/<mac>.toml`.
5. **Arm and release** — arms the install payload, then writes
   `/srv/pxe/http/go/<mac>.txt` containing `install NODE`. The held machine sees
   it, sets UEFI **BootNext** to its own PXE entry and reboots straight into the
   installer. One power-on, start to finish.
6. **Wait** for `pxe-answer` to log `-> <mac>.toml`, then remove the release
   file and disarm.

## Surveying on its own

Safe to point at a machine whose contents matter — **nothing is written to the
target**. This is what runs *before* deciding which disk may be erased.

```bash
~/scripts/survey-node.sh                 # --wait MINUTES (default 20), --shadow
```

It prints the report and hands you the follow-up command with `--mac` and
`--disk-serial` already filled in. It **does not disarm on success** — the
machine is holding and needs the payload up to collect its release. It does
disarm on timeout.

Reports live at `/srv/pxe/surveys/<mac>.txt`, and carry a machine-readable block
between `### SURVEY-DATA v<N>` and `### END SURVEY-DATA`: tab-separated `DISK`
rows of device, serial, size, model, verdict (`empty`/`data`/`windows`/`inuse`)
and used/free bytes. Used and free come from reading filesystem superblocks
(`ntfsinfo`, `dumpe2fs`, `fsck.fat`, `xfs_db`) rather than mounting, because
`lsblk` only populates `FSUSED`/`FSAVAIL` for *mounted* filesystems.

Two variants exist when a headless boot is not wanted:

```bash
# on a target still running Windows, elevated PowerShell:
irm http://PXE_IP/tools/disk-survey.ps1 | iex
# from any Linux shell, including a plain rescue boot:
curl -s http://PXE_IP/tools/disk-survey.sh | bash -s -- --post
```

## Reaching a target the server cannot hear

Three routes, in order of preference:

1. **`--shadow`** — answers the DISCOVER it never heard, reconstructed from the
   router's OFFER (which carries the client's transaction ID and MAC, and does
   cross the router). Needs the **unicast** delivery: broadcast alone does not
   reach across a router. This was measured, not assumed.
2. **Point the firmware's HTTP Boot URI** at `http://PXE_IP/ipxe-chain.efi`.
3. **From the target itself, if it still runs Windows** — no trip to the machine:
   ```powershell
   irm http://PXE_IP/tools/pxe-boot-from-windows.ps1 | iex   # -DryRun first
   ```
   Installs `ipxe-chain.efi` on the machine's own ESP and sets a one-shot
   BootNext. Refuses if Secure Boot is on.

The real fix is three lines on the router (`dhcp-boot` pointing at `PXE_IP`),
which makes every machine on every segment work with nothing extra running. That
needs router credentials, which are not always available.

## Dual-boot: keeping Windows on a node

Installing to a second disk leaves the Windows disk untouched, but Proxmox's
GRUB will not offer it. After the install:

```bash
ssh -i SECRET_STORE/NODE/id_ed25519 root@ADDR 'bash -s' \
    < tools/add-windows-boot-entry.sh        # --dry-run first
```

It finds the Windows Boot Manager on whichever ESP has one and writes a single
static `menuentry` keyed on that partition's filesystem UUID. **Never install
`os-prober`** to do this — see SKILL.md. If Windows then demands a BitLocker
recovery key, that is the TPM noticing the boot path changed: expected, not
damage. Make sure the user has the key **before** rebooting into it.

## Credentials

`new-node.py` mints them once from a CSPRNG and writes, all before serving:

```
new_machine_onboarding/secrets/NODE/            0700  (refuses to overwrite)
                              /credentials.env  0600  O_EXCL
                              /id_ed25519       0600
                              /id_ed25519.pub   0644
new_machine_onboarding/nodes/NODE.answer.toml   0600
```

`credentials.env` keys: `NODE_NAME`, `NODE_FQDN`, `NODE_IP`, `NODE_PRODUCT`,
`NODE_URL`, `NODE_USER`, `NODE_PASSWORD`, `NODE_PASSWORD_HASH`, `NODE_SSH_KEY`,
`NODE_DISK`, `NODE_FS`. The answer file keeps only the hash.

A snapshot to `/var/backups/pxe-secrets/<utc>/` runs automatically on write, and
`pxe-secrets-guard.timer` verifies hourly and self-heals from snapshots. A failed
unit means a real loss — check `journalctl -u pxe-secrets-guard` and
`sudo -A ~/scripts/secrets-guard.sh verify` before assuming it is noise.

```bash
sudo -A -A ~/scripts/secrets-guard.sh verify     # needs sudo: the store is root-owned
```

Verbs: `verify`, `backup [--reason TEXT]`, `restore [node...]`, `list [node]`,
`protect`, `unprotect [node...]`, `forget NODE`, `autoheal`. Live secrets and
snapshots are immutable (`chattr +i`); a deliberate rotation says `unprotect`
first. **If `rm` fails on a credential, that is the design working.** A node
that is genuinely unrecoverable gets `forget`, so the hourly alarm means a *new*
loss rather than the old one.

**Never retype a password or key into chat, or into any file outside the
credential store and its snapshot folder.**

## Checking the fleet

```bash
~/scripts/fleet-status.sh              # print + refresh FLEET.md
~/scripts/fleet-status.sh --no-write
```

Lists every node with a real answer file (skipping `default.toml`, a wildcard),
pings it, and compares the MAC in the ARP table against the MAC it was enrolled
under. That confirms the node is alive and nothing else has taken its IP — it
does **not** confirm Proxmox itself is healthy.

## Rebuilding a payload for a new release

```bash
sudo -A ~/pxe-server/payloads/build-proxmox.sh 9.3-1
sudo -A ~/pxe-server/payloads/build-rescue.sh
```

PDM needs the answer-fetching variant built first, and the auto-install
assistant is amd64-only, so it runs in Docker on an x86 workstation:

```bash
./new_machine_onboarding/prepare-auto-iso.sh --http http://PXE_IP:8080/answer \
    iso-work/proxmox-datacenter-manager_<ver>.iso
scp iso-work/...-fleet.iso PXE_HOST:/tmp/          # over the LAN, not an ssh relay
sudo -A ~/pxe-server/payloads/build-pdm.sh --iso /srv/pxe/iso/...-fleet.iso --name pdm-fleet
```

Note the payload *name* (`pdm-fleet`, what `pxectl` takes) and the build
`--name` (the directory, which must match the boot script's `pxe-payload-dir`
header) are separate things that happen to coincide here. For PVE they do not:
payload `proxmox-fleet`, directory `pve-fleet`.
