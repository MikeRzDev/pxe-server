# Spec: enrolment over SSH, from a small Linux image

Status: **proposed**, not implemented.
Date: 2026-09-04.
Supersedes: the survey / hold / release machinery in `autorun/survey/`,
`scripts/onboard-lib.sh` and `tools/dhcp-offer-shadow.py`.

## The requirement

> A solution that works for any two machines that can see each other on a
> network, physical or virtual.

"See each other" means one can open a TCP connection to the other. Not the same
broadcast domain, not the same subnet, not the same site. Over the VPN counts.

That single sentence rules out most of what the current design depends on.

## Why the current design cannot meet it

Enrolment today needs the PXE server to **overhear** the target's DHCP
DISCOVER, because dnsmasq runs in proxy-DHCP mode (`dhcp-range=<lan>,proxy`).
It hands out no addresses; it only shouts "…and boot from me" alongside the real
DHCP server's reply. That is passive, and it needs the two machines on one
broadcast domain.

They are not:

```
arduino ── switch A ── ISP router ── switch B ── target

client → server DHCP   does NOT cross   (the router forwards it only to itself)
server → client DHCP   DOES cross
Pi broadcasts          DO cross         (an ARP from the Pi resolves the target)
```

Measured on 2026-09-03/04 while enrolling oppenheimer, not inferred.

`tools/dhcp-offer-shadow.py` works around this by answering the DISCOVER it
never heard, reconstructing it from the router's OFFER (which does arrive, and
carries the client's xid and MAC). It works — three consecutive surveys — but it
is a workaround for a property of the network, it needs promiscuous mode, and it
still only functions where the server can hear *the router*. Move the target one
more hop away and it fails again.

The router's own `dhcp-boot` would be the correct fix. **The router is
ISP-supplied and cannot be logged into.** So that door is closed permanently,
and the design has to stop depending on DHCP.

## The constraint that shapes everything

A cold machine's firmware can only locate a boot server via DHCP, which is a
broadcast protocol. **There is no way to netboot a powered-off, empty machine
using unicast IP alone.** No amount of software fixes that.

So the first hop needs either DHCP cooperation (ruled out) or *something already
on the machine*. Accept that once, and everything above it becomes pure unicast
and works anywhere.

## Architecture

Bootstrap once per machine; every enrolment after that is unicast HTTP + SSH.

```
one-time:   place ipxe-chain.efi on the target (or attach it as virtual media)

every run:  set BootNext ──► firmware loads iPXE from LOCAL disk
                         ──► iPXE runs its embedded script
                         ──► dhcp                 (an ADDRESS only; any router does this)
                         ──► chain https://<server>/boot.ipxe    ← unicast, routable
                         ──► rescue image boots into RAM
                         ──► sshd up, key already installed
                         ──► operator SSHes in and drives the install
```

No proxy-DHCP. No TFTP. No shadow. No promiscuous mode. No L2 adjacency. No
router cooperation. The only network requirement is a TCP connection from target
to server.

iPXE's embedded-script behaviour is confirmed by its own documentation: an
`EMBED=` script replaces the normal autoboot, and iPXE does **not** perform DHCP
before running it — the script must call `dhcp` itself. See
<https://ipxe.org/embed>.

### Bootstrapping, per target type

| target | how the artifact arrives | physical touch |
|---|---|---|
| running Windows | `tools/pxe-boot-from-windows.ps1` writes it to the ESP and adds a firmware boot entry | none — remote |
| running Linux | same, via `efibootmgr` over SSH | none — remote |
| VM (Proxmox, libvirt, cloud) | attach the iPXE ISO as boot media through the hypervisor API | none — API call |
| bare metal, nothing installed | USB stick: `ipxe-chain.efi` → `/EFI/BOOT/BOOTX64.EFI` | one, unavoidable |
| server board with BMC | Redfish / IPMI virtual media | none — API call |

Only row four needs a person, and only once. The consumer MSI boards in this
fleet have no BMC, so there is no remote escape hatch for a genuinely blank one.

### The artifact should be addressed by name, not by IP

`payloads/build-ipxe-chain.sh` currently compiles `192.168.1.229` into the
binary, which makes it site-specific. Bake in a **hostname** instead. The build
already enables `NSLOOKUP_CMD` and `DOWNLOAD_PROTO_HTTPS`, so one binary can
work at any site and DNS decides which server it reaches — including through the
VPS relay, from anywhere.

If the chain URL is ever reachable from the public internet, the answer file
needs protecting: it carries the root password hash. Either keep answer delivery
on the VPN side only, or use HTTPS with a per-machine token in the path.

### The rescue image

Reuse SystemRescue, already built as the `rescue`/`survey` payload. Two kernel
options do the work, both documented at
<https://www.system-rescue.org/manual/Booting_SystemRescue/>:

- `nofirewall` — the manual states this is what permits inbound connections
  "for example connections to sshd";
- `rootcryptpass=<hash>` — sets the root password from a hash, so no plaintext
  appears on a kernel command line that is visible in `/proc/cmdline`.

Better than a password: have a minimal `ar_source` autorun drop an
`authorized_keys` fetched from the server, and enrol with a key. The autorun
shrinks to roughly:

```sh
curl -fsS "http://${SERVER}/keys/enrol.pub" >> /root/.ssh/authorized_keys
curl -fsS -X POST "http://${SERVER}:8080/ready" -H "X-Mac: ${MAC}"   # optional: announce
```

Everything else — inventory, disk choice, install — happens in a real shell.

### The install step

Three options, in the order I would try them:

1. **Drive the existing Proxmox answer-file installer from the SSH session.**
   Keeps the fleet identical to the six nodes already built, and the answer-file
   over HTTP mechanism is Proxmox's own supported path
   (<https://pve.proxmox.com/wiki/Automated_Installation>), which their roadmap
   is actively extending with PXE/iPXE integration.
2. **`debootstrap` + the `pve-no-subscription` repo** — the officially supported
   "install Proxmox VE on Debian" route. No ISO, no 2 GB initrd, ordinary
   package management, fully visible while it runs.
3. **A golden image over SFTP, `dd`'d to the chosen disk.** Fastest to deploy,
   but the installer builds an LVM-thin layout (`pve/root`, `pve/data`,
   `pve/swap`) sized to the disk, so this needs `growpart` + `lvextend` plus
   regenerated hostname, IP, SSH host keys and SSL certificate on first boot.
   Worth building later if deploy speed matters; not first.

## What this deletes

| removed | why it existed |
|---|---|
| `tools/dhcp-offer-shadow.py` | answering a DISCOVER the server never heard |
| proxy-DHCP config, TFTP root | delivering the boot file over DHCP |
| release files, `GO_DIR`, the 10 s poll loop | telling a held machine to move on |
| `chain_via_bootnext` + `reboot -f` | getting from survey into installer |
| `POST /survey`, `SURVEY-DATA v1/v2` | shipping the disk list back to the server |
| survey → report → parse → menu → serial | choosing a disk without a shell |
| `--chain`, `--resurvey`, the 90 min hold | the timing dance around all of it |

It also removes a whole class of bug. Two of tonight's three failures lived in
this machinery: a stale release file re-triggering the same machine every two
minutes, and a `--mac` filter that compared `047c1649aa63` against
`04:7c:16:49:aa:63` and therefore silently matched nothing.

And it makes VMs first-class, which the current design handles badly.

## What it does NOT solve

- **The first hop still needs local media** on a genuinely blank machine.
- **Secure Boot must be off.** iPXE, the SystemRescue kernel and the Proxmox
  installer are all unsigned; with it on the firmware silently falls through to
  the existing OS.
- **Credentials remain the irreplaceable thing.** Nothing here changes the rule
  that `secrets/<node>/` and `Manhattan/<node>/` are the only two copies.

## Prior art

This shape is what the mature tools converged on, which is reassuring rather
than novel:

- **Foreman Discovery** boots a small image into RAM via PXE, inventories the
  hardware, reports facts, and holds as a "discovered host" until an operator
  provisions it — with `fdi.ssh=1` and `fdi.rootpw=` to enable exactly the SSH
  access proposed here.
  <https://theforeman.org/plugins/foreman_discovery/18.0/index.html>
- **MAAS** commissions machines to collect CPU/memory/storage/NIC data before
  deployment.
- **Tinkerbell** models provisioning as container-based workflows.

None were adopted, for three reasons: none of them remove the DHCP dependency
(MAAS in particular wants to *own* DHCP, which is the one thing this network
forbids); none install Proxmox VE natively; and all are far heavier than a
DietPi Pi managing seven nodes.

## Migration

1. Build `payloads/rescue-ssh` — SystemRescue + `nofirewall` + key drop.
2. Rebuild `ipxe-chain.efi` against a hostname rather than an IP.
3. Bootstrap oppenheimer's ESP from Windows; confirm it netboots with the shadow
   **stopped**. That is the proof the whole approach rests on.
4. Port one node end to end; keep the old path armed as a fallback.
5. Retire the shadow and the survey/hold machinery once a second node has gone
   through cleanly.

Step 3 is the decision point. If a machine boots to an SSH prompt with
proxy-DHCP switched off entirely, everything else here follows.
