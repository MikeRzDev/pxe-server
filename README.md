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
| `payloads/fetch-iso.sh` | **generic**: download any ISO and unpack it into the HTTP root |
| `payloads/build-proxmox.sh` | example: fetch the ISO, build the initrd with the ISO embedded |
| `payloads/build-rescue.sh` | example: fetch the ISO, unpack the archiso tree |
| `templates/` | every config file, with `@@PLACEHOLDER@@` values |
| `templates/srv/pxe/http/boot-EXAMPLE.ipxe` | starting point for a new image, with cmdline recipes |
| `templates/usr/local/sbin/pxectl` | the control script |
| `scripts/` | the `~/scripts` wrappers installed for the operator |

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

## Adding another image

```bash
# 1. get the files
sudo ./payloads/fetch-iso.sh debian13 https://.../debian-13-netinst.iso
#    it prints the kernels and initrds it found

# 2. describe how to boot them
sudo cp /srv/pxe/http/boot-EXAMPLE.ipxe /srv/pxe/http/boot-debian13.ipxe
sudo $EDITOR /srv/pxe/http/boot-debian13.ipxe

# 3. that's it
sudo pxectl list
sudo pxectl debian13
```

To make it survive a rebuild, drop the same `boot-debian13.ipxe` into
`templates/srv/pxe/http/` here and re-run `install.sh` — it renders every
`boot-*.ipxe` it finds.

The only genuinely image-specific part is the **kernel command line**;
`boot-EXAMPLE.ipxe` lists the patterns for the Debian/Ubuntu, archiso,
anaconda and boot-the-whole-ISO-from-a-ramdisk families. `fetch-iso.sh`
deliberately does not guess it — a wrong guess fails confusingly at boot.

Two optional header comments are the only metadata `pxectl` reads:

```
# pxe-description: Debian 13 netboot installer
# pxe-payload-dir: debian13
```

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
