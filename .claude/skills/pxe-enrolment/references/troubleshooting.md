# Troubleshooting

## First, the meta-rule: silence is not evidence

The dominant failure here is a target that never boots and leaves **nothing in
any log** — no TFTP, no HTTP, no `pxectl log` line, no `pxe-answer` entry. That
looks identical to a machine that was never switched on, and it has at least
four distinct causes. Diagnose it with a packet capture, not with logs:

```bash
sudo -A tcpdump -i eth0 -n -e 'port 67 or port 68 or port 69 or port 4011'
```

`tcpdump` sees packets before the firewall does, and it is the only reliable
answer. In particular:

- **`ufw` block logging is rate-limited** (`3/min`, burst 10), so a dropped
  packet often leaves no line at all. Never conclude "nothing arrived" from an
  empty ufw log.
- **The PXE nginx site logs to `/var/log/nginx/pxe-access.log`**, not
  `access.log`. Any conclusion drawn from an empty `access.log` is unsupported.
- **`journalctl --since "23:40"` means *today* at 23:40.** If that is in the
  future you get an empty result that reads exactly like "no events". Use
  relative times: `--since -30min`.
- **`pgrep -f <pattern>` matches your own shell**, so a `pkill -f` cleanup can
  kill the ssh session running it (exit 255). Skip `$$` when iterating.

## Nothing happens at all — four causes

| # | Cause | Tell | Fix |
|---|---|---|---|
| 1 | Wrong boot entry: **HTTP IPv4** picked instead of **PXE IPv4** | `journalctl -u dnsmasq` shows the vendor-class line `HTTPClient:Arch:00016` with no reply sent | reboot, pick `PXE IPv4` from the one-time menu |
| 2 | **The server cannot hear the target** — it is behind another router | tcpdump shows the router's OFFERs arriving but *zero* packets from the client | re-run with `--shadow` |
| 3 | **Secure Boot is on** | firmware rejects the unsigned binary, often with no message | turn Secure Boot off |
| 4 | No payload is armed, or the wrong one | `sudo pxectl status` | `~/scripts/pxe.sh <payload>` |

Causes 1 and 2 produce byte-identical symptoms from the server's side. Check the
boot menu entry first — it costs one reboot and no setup.

### Why the shadow is needed, concretely

```
PXE server ── switch A ── router ── switch B ── target

client -> server DHCP    does NOT cross   (the router forwards it only to itself)
server -> client DHCP    DOES cross
server broadcasts        DO cross         (an ARP from the server resolves the target)
```

The block is one-directional, and the half that arrives is enough: an OFFER
carries the client's transaction ID and MAC, which is everything needed to answer
a DISCOVER that was never heard. That is all `dhcp-offer-shadow.py` does. A PXE
client waits out its full discovery timeout collecting proxy offers, so arriving
a round-trip late is still on time.

**Broadcast alone does not work** across the router — that was measured. The
shadow's unicast delivery is what makes it function.

Shadow flags: `--interface` (default `eth0`), `--server-ip`, `--bootfile`
(default `ipxe-chain.efi`), `--mac` (repeatable), `--timeout <minutes>`,
`--once`, `--dry-run`, `--verbose`. Its log is `/tmp/dhcp-offer-shadow.log`.

If the shadow appears to run but nothing is ever offered, check that any `--mac`
filter is comparing **hex-only** forms — a filter written `aa:bb:cc:dd:ee:ff`
against a bare-hex `aabbccddeeff` matches nothing and skips every offer
silently. That bug shipped once.

## It TFTPs, then the kernel and initrd 404

`/var/log` is a tmpfs on DietPi, so `/var/log/nginx/` — created once by the
package postinst — is gone after each reboot. nginx then fails its own
`ExecStartPre` config test and never starts, while TFTP still hands out iPXE
happily. `install.sh` fixes this permanently with
`/etc/systemd/system/nginx.service.d/logdir.conf`; if you are seeing it, that
drop-in is missing or `install.sh` has not been re-run.

## iPXE chainloads itself forever

The `dhcp-match=set:ipxe,175` tag is what stops this: without it, iPXE DHCPs
again, is handed the binary again, and loops. Check `/etc/dnsmasq.d/pxe.conf`
rendered cleanly.

`autoexec.ipxe not found` in the iPXE output is **normal** and appears in every
successful boot. It is not the problem.

## `pxectl status` says it is serving, but nothing answers

Almost always: **`install.sh` was re-run while a payload was armed.** The
installer does `systemctl disable --now dnsmasq nginx pxe-answer`, so the workers
stop while `pxe@<payload>` stays `active`. Re-arm:

```bash
~/scripts/pxe-stop.sh && ~/scripts/pxe.sh <payload>
```

A typo'd payload name leaves the workers running for the same reason — `Wants=`
has already pulled them up before `ExecStartPre` fails. `pxectl off` stops them
unconditionally.

## The machine boots the survey over and over

A stale release file in `/srv/pxe/http/go/` that was never consumed: the machine
surveys, holds, sees the old release, reboots, repeats — roughly every two
minutes. The answer server clears stale release files when a machine surveys
again; if you are hand-dropping release files, clear them yourself.

## The survey reported, but re-running surveys again

A report under 90 minutes old is reused deliberately, because **a held machine
never netboots on its own**. If you genuinely want a fresh look, pass
`--resurvey`. If several machines have recent reports, disambiguate with
`--mac`.

Past 90 minutes the machine has stopped holding, and `pick-disk.sh` warns about
it — at that point the target needs powering on again.

## The answer file was served but never collected

The script deliberately **leaves PXE armed** and tells you to reboot the target
once. Disarming there would leave that reboot with nothing to boot into. Do not
"tidy up" by stopping PXE.

## Installed to the wrong disk

There is no recovery, only prevention: select by serial. The same physical disk
was `nvme1n1`, `nvme2n1` and `nvme3n1` across three consecutive boots of one
machine, so a device name you read in one survey may name a different disk on the
boot that installs.

## The iPXE chainloader will not build

`libc6-dev` is only a **Recommends** of `gcc`, so an install done with
`--no-install-recommends` produces:

```
include/stdint.h:17: fatal error: bits/stdint.h: No such file or directory
```

This is not an architecture problem — it reproduces identically on amd64. Install
`build-essential`. The binary must be **x86-64**, so on an ARM Pi it
cross-compiles.

## Disk space

Build on `/srv/pxe`, never `/tmp` — on a Pi `/tmp` is a small RAM-backed tmpfs,
and filling it makes `install.sh` fail with
`sed: couldn't flush stdout: No space left on device`. Packet captures belong on
real disk too.

## Things that look like fixes and are not

- **`Conflicts=` between payload instances** — combined with the `PartOf=`
  drop-ins it makes systemd reject the job outright: `Transaction contains
  conflicting jobs`. Mutual exclusion lives in the `pxectl <payload>` verb.
- **Stopping the workers from `ExecStop`** — blocking deadlocks the stop job;
  `--no-block` introduces a race where the unit comes back `active` with dnsmasq
  and nginx dead. `ExecStop` closes the firewall and nothing else.
- **Scoping the DHCP firewall rules to the LAN subnet** — a PXE client has no IP
  yet, so its DISCOVER is `0.0.0.0 -> 255.255.255.255` and matches no
  subnet-scoped rule. Ports 67 and 4011 must be open to `any`.
- **Putting the answer server behind nginx** — the installer fetches its answer
  with a POST, and nginx answers a POST for a static file with 405.
