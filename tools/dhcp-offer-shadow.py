#!/usr/bin/env python3
"""dhcp-offer-shadow.py - netboot a client this server cannot hear.

WHAT IS BROKEN
--------------
This PXE server finds clients by proxy-DHCP: dnsmasq overhears a client's DHCP
DISCOVER and injects "netboot from me" alongside the LAN's real DHCP reply. It
is entirely passive, and it has one hard requirement - the server must HEAR the
DISCOVER.

On a LAN split by a router that answers DHCP itself, that requirement fails in
one direction only:

    arduino <-> switch A <-> router <-> switch B <-> client

    client -> server broadcasts   do NOT cross to switch A   (DHCP snooping:
                                  the router forwards them only to itself)
    server -> client broadcasts   DO cross                   (the router's own
                                  OFFERs are seen on switch A, and an ARP
                                  request from the Pi resolves the client)

So the client is invisible to dnsmasq, its firmware waits for boot information
nobody sends, and it eventually gives up. Nothing is misconfigured. The
discovery mechanism simply cannot reach across.

WHAT THIS DOES
--------------
It listens to the half of the conversation that DOES arrive: the router's
DHCPOFFERs. An OFFER carries the client's transaction ID and MAC - everything
needed to answer the DISCOVER that was never heard. So on seeing one, this
immediately broadcasts a matching ProxyDHCP OFFER of its own:

    yiaddr 0.0.0.0        - no address; the router is handing that out
    siaddr <this server>  - but the boot server is us
    file   ipxe-chain.efi
    opt 60 "PXEClient"    - marks it as a PXE proxy offer, not a lease
    opt 43 sub-6 = 0x08   - "the boot file is right here, skip boot server
                            discovery" (PXE 2.1 PXE_DISCOVERY_CONTROL bit 3)

A PXE client deliberately waits for the full discovery timeout collecting proxy
offers before it acts, so arriving one round-trip late is exactly on time.

The client then TFTPs ipxe-chain.efi from here - unicast, which crosses the
router perfectly well - and that binary has this server's address compiled into
it, so iPXE needs no DHCP option to know where to go next. Everything after
that point is ordinary unicast HTTP and the normal flow resumes untouched.

Nothing is written to the client, and no lease is offered: the router remains
the only DHCP server on the LAN.

USAGE
-----
    sudo -A ./dhcp-offer-shadow.py                      # until Ctrl-C
    sudo -A ./dhcp-offer-shadow.py --mac 04:7c:16:49:aa:63   # one machine only
    sudo -A ./dhcp-offer-shadow.py --dry-run --verbose  # watch, change nothing

Run it while a payload is armed, then netboot the target ("PXE IPv4"). It is
NOT a service and does not start at boot: it is for the machines that need it,
for as long as they need it. The proper fix is three lines on the router
(dhcp-boot pointing here), which makes every machine on both segments work
with nothing running here at all.
"""

import argparse
import fcntl
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time

ETH_P_IP = 0x0800
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
IFF_PROMISC = 0x100

DHCP_MAGIC = b'\x63\x82\x53\x63'
BOOTREPLY = 2
DHCPOFFER = 2
BROADCAST_FLAG = 0x8000


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Promiscuous:
    """Put the interface into promiscuous mode, and take it back out.

    Binding a packet socket is not enough on its own: a switch only floods
    broadcast and unknown-unicast to this port, so an OFFER unicast to a client
    on the far segment is seen only while promiscuous. Restored on exit so this
    leaves the interface as it found it.
    """

    def __init__(self, iface):
        self.iface = iface
        self.was_on = False
        self.sock = None

    def _flags(self, sock, set_to=None):
        ifreq = struct.pack('16sh', self.iface.encode(), 0)
        cur = struct.unpack('16sh', fcntl.ioctl(sock, SIOCGIFFLAGS, ifreq))[1]
        if set_to is not None:
            fcntl.ioctl(sock, SIOCSIFFLAGS,
                        struct.pack('16sh', self.iface.encode(), set_to))
        return cur

    def on(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        flags = self._flags(self.sock)
        self.was_on = bool(flags & IFF_PROMISC)
        if not self.was_on:
            self._flags(self.sock, flags | IFF_PROMISC)

    def off(self):
        if self.sock is None or self.was_on:
            return
        try:
            flags = self._flags(self.sock)
            self._flags(self.sock, flags & ~IFF_PROMISC)
        except OSError:
            pass


def udp_payload(frame):
    """Strip Ethernet/IP/UDP off a captured frame; None if it is not DHCP."""
    if len(frame) < 14 + 20 + 8:
        return None
    if struct.unpack('!H', frame[12:14])[0] != ETH_P_IP:
        return None                                  # not IPv4 (VLAN, ARP, v6)
    ip = frame[14:]
    if (ip[0] >> 4) != 4:
        return None
    ihl = (ip[0] & 0x0F) * 4
    if ip[9] != socket.IPPROTO_UDP or len(ip) < ihl + 8:
        return None
    sport, dport = struct.unpack('!HH', ip[ihl:ihl + 4])
    if 67 not in (sport, dport) and 68 not in (sport, dport):
        return None
    udp_len = struct.unpack('!H', ip[ihl + 4:ihl + 6])[0]
    return ip[ihl + 8:ihl + max(8, udp_len)]


# ------------------------------------------------------------------ parse ----
def parse_dhcp(data):
    """Return a dict for a BOOTP/DHCP packet, or None if it is not one."""
    if len(data) < 240 or data[236:240] != DHCP_MAGIC:
        return None
    pkt = {
        'op': data[0],
        'xid': data[4:8],
        'secs': data[8:10],
        'flags': struct.unpack('!H', data[10:12])[0],
        'ciaddr': data[12:16],
        'yiaddr': data[16:20],
        'giaddr': data[24:28],
        'chaddr': data[28:44],
        'options': {},
    }
    i = 240
    while i < len(data):
        code = data[i]
        if code == 0:          # pad
            i += 1
            continue
        if code == 255:        # end
            break
        if i + 1 >= len(data):
            break
        length = data[i + 1]
        pkt['options'][code] = data[i + 2:i + 2 + length]
        i += 2 + length
    return pkt


def mac_str(chaddr):
    return ':'.join(f'{b:02x}' for b in chaddr[:6])


def mac_key(mac):
    """Hex only, so 04:7c:16:49:aa:63 and 047c1649aa63 compare equal.

    Both spellings are in circulation: this prints the colonned form, while
    onboard-lib.sh and the survey filenames use the bare one. Comparing the two
    directly never matches, and the failure is silent - every offer is skipped,
    no error is logged, and the target simply never gets an answer. Cost one
    enrolment on oppenheimer before it was spotted.
    """
    return re.sub(r'[^0-9a-f]', '', mac.lower())


# ------------------------------------------------------------------ build ----
def build_proxy_offer(req, server_ip, bootfile):
    """A ProxyDHCP OFFER that answers the DISCOVER we never saw.

    It borrows the client's xid/secs/flags/chaddr from the router's OFFER,
    which is the whole trick: those are the fields the client matches on, and
    they are identical in the DISCOVER it actually sent.
    """
    packet = b''.join([
        struct.pack('!BBBB', BOOTREPLY, 1, 6, 0),
        req['xid'],
        req['secs'],
        struct.pack('!H', req['flags']),
        b'\x00' * 4,                             # ciaddr
        b'\x00' * 4,                             # yiaddr - NOT a lease
        socket.inet_aton(server_ip),             # siaddr - the boot server
        req['giaddr'],
        req['chaddr'],
        b'\x00' * 64,                            # sname
        bootfile.encode()[:127].ljust(128, b'\x00'),
        DHCP_MAGIC,
    ])

    def opt(code, payload):
        return bytes([code, len(payload)]) + payload

    # sub-option 6 = PXE_DISCOVERY_CONTROL. Bit 3 means "if the boot file name
    # is present in this offer, download it immediately and skip boot server
    # discovery" - which is what lets a single broadcast finish the job, with
    # no follow-up exchange on port 4011.
    vendor = bytes([6, 1, 0x08]) + b'\xff'

    packet += b''.join([
        opt(53, bytes([DHCPOFFER])),
        opt(54, socket.inet_aton(server_ip)),
        opt(60, b'PXEClient'),
        opt(43, vendor),
        b'\xff',
    ])
    # Some PXE ROMs discard anything shorter than the 300-byte BOOTP minimum.
    return packet.ljust(300, b'\x00')


def ip_checksum(header):
    if len(header) % 2:
        header += b'\x00'
    total = 0
    for i in range(0, len(header), 2):
        total += (header[i] << 8) + header[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def build_frame(payload, src_ip, dst_ip='255.255.255.255'):
    """IP+UDP from port 67, built by hand.

    dnsmasq already holds 0.0.0.0:67, so this cannot use an ordinary socket to
    send from that port - and it must be port 67, because a PXE client will not
    look at a reply from anywhere else. The UDP checksum is left zero, which
    IPv4 explicitly permits.
    """
    udp_len = 8 + len(payload)
    udp = struct.pack('!HHHH', 67, 68, udp_len, 0) + payload

    total_len = 20 + udp_len
    ip = struct.pack('!BBHHHBBH4s4s',
                     0x45, 0, total_len,
                     0, 0,
                     64, socket.IPPROTO_UDP, 0,
                     socket.inet_aton(src_ip), socket.inet_aton(dst_ip))
    ip = ip[:10] + struct.pack('!H', ip_checksum(ip)) + ip[12:]
    return ip + udp


def eth_frame(dst_mac, src_mac, ip_packet):
    return dst_mac + src_mac + struct.pack('!H', ETH_P_IP) + ip_packet


def delivery_variants(req, server_ip, server_mac, payload):
    """Every way of putting this offer in front of the client, cheapest first.

    Broadcast alone is not enough in practice. Plenty of consumer routers drop
    DHCP *server* traffic (source port 67) arriving from a LAN port - rogue-DHCP
    protection - which kills the broadcast while leaving ARP and ordinary
    unicast untouched. Since unicast demonstrably crosses this LAN's router
    (ssh, TFTP and HTTP all work), the same offer is also sent as unicast:

      1. L2 broadcast, IP 255.255.255.255 - what a DHCP server normally does
      2. L2 unicast to the client's MAC, IP still 255.255.255.255 - the client's
         IP stack accepts it exactly as in (1), but the frame is not a broadcast
         and so is not subject to broadcast flooding rules
      3. L2 unicast, IP = the address the router just offered it - what a server
         does for a client that did not set the broadcast flag

    A PXE client matches on xid and chaddr and ignores duplicates, so sending
    all three costs nothing but three small frames.
    """
    bcast = b'\xff' * 6
    client_mac = req['chaddr'][:6]
    offered = socket.inet_ntoa(req['yiaddr'])
    out = [
        ('L2 broadcast', bcast,
         build_frame(payload, server_ip, '255.255.255.255')),
        ('unicast/255.255.255.255', client_mac,
         build_frame(payload, server_ip, '255.255.255.255')),
    ]
    if offered != '0.0.0.0':
        out.append((f'unicast/{offered}', client_mac,
                    build_frame(payload, server_ip, offered)))
    return [(label, eth_frame(dst, server_mac, ip)) for label, dst, ip in out]


# ------------------------------------------------------------------- main ----
def detect_server_ip(iface):
    out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'dev', iface],
                         capture_output=True, text=True).stdout
    m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)/', out)
    return m.group(1) if m else None


def detect_server_mac(iface):
    with open(f'/sys/class/net/{iface}/address') as fh:
        return bytes.fromhex(fh.read().strip().replace(':', ''))


def main():
    ap = argparse.ArgumentParser(
        description='Answer PXE clients this server cannot hear, by shadowing '
                    "the LAN router's DHCP offers.")
    ap.add_argument('--interface', default='eth0')
    ap.add_argument('--server-ip', default=None,
                    help='this server (default: the address on --interface)')
    ap.add_argument('--bootfile', default='ipxe-chain.efi',
                    help='TFTP file to hand out; use ipxe-chain.kpxe for '
                         'legacy BIOS clients (default: %(default)s)')
    ap.add_argument('--mac', action='append', default=[],
                    help='only shadow offers to this MAC; repeatable')
    ap.add_argument('--timeout', type=int, default=0,
                    help='give up after N minutes (default: run until Ctrl-C)')
    ap.add_argument('--once', action='store_true',
                    help='exit after shadowing one client')
    ap.add_argument('--any-flags', action='store_true',
                    help='also shadow offers to clients that did not set the '
                         'broadcast flag (they are usually ordinary machines '
                         'getting an ordinary lease, not PXE clients)')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit('dhcp-offer-shadow.py: must run as root (raw sockets)')

    server_ip = args.server_ip or detect_server_ip(args.interface)
    if not server_ip:
        sys.exit(f'could not find an IPv4 address on {args.interface}')

    wanted = {mac_key(m) for m in args.mac}

    # A packet socket in promiscuous mode, not a UDP socket bound to port 68.
    # Two reasons, and the second is the one that matters:
    #   - dnsmasq already owns 0.0.0.0:67, and port 68 may be held by a DHCP
    #     client on this host;
    #   - a DHCPOFFER is only broadcast when the client asked for that. If the
    #     router unicasts it to the client instead, no socket on this machine
    #     would ever be handed a copy - but the frame still arrives on the
    #     wire, and this sees it. tcpdump saw these offers; so must we.
    rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
    rx.bind((args.interface, 0))
    rx.settimeout(1.0)
    promisc = Promiscuous(args.interface)
    promisc.on()

    # AF_PACKET to send too, so the destination MAC can be chosen rather than
    # left to the kernel's ARP - see delivery_variants().
    tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
    tx.bind((args.interface, 0))
    server_mac = detect_server_mac(args.interface)

    print(f"""
======================================================================
 DHCP OFFER SHADOW   {args.interface}  ->  {server_ip}
======================================================================
  bootfile : {args.bootfile}   (TFTP from {server_ip})
  clients  : {', '.join(sorted(wanted)) if wanted else 'any that netboots'}
  mode     : {'DRY RUN - watching only' if args.dry_run else 'active'}

  Netboot the target now via its UEFI 'PXE IPv4' entry. Nothing is written
  to it, and no address is offered - the router still owns DHCP.
  Ctrl-C to stop.
""", flush=True)

    def _bye(*_):
        promisc.off()
        sys.exit('\nstopped.')

    signal.signal(signal.SIGINT, _bye)
    signal.signal(signal.SIGTERM, _bye)
    deadline = time.time() + args.timeout * 60 if args.timeout else None
    seen = {}
    shadowed = 0

    while True:
        if deadline and time.time() > deadline:
            log(f'timed out after {args.timeout} min; shadowed {shadowed}.')
            promisc.off()
            return 1 if shadowed == 0 else 0
        try:
            frame_in = rx.recv(2048)
        except socket.timeout:
            continue

        data = udp_payload(frame_in)
        if data is None:
            continue

        pkt = parse_dhcp(data)
        if not pkt or pkt['op'] != BOOTREPLY:
            continue
        if pkt['options'].get(53, b'\x00')[0] != DHCPOFFER:
            continue

        # Our own offer, echoed back by the broadcast we just sent.
        if pkt['options'].get(54) == socket.inet_aton(server_ip):
            continue

        mac = mac_str(pkt['chaddr'])
        offered = socket.inet_ntoa(pkt['yiaddr'])

        if wanted and mac_key(mac) not in wanted:
            if args.verbose:
                log(f'ignoring offer to {mac} ({offered}) - not in --mac')
            continue

        # PXE firmware has no address yet and asks to be answered by broadcast.
        # An ordinary machine renewing a lease does not, so this is the cheapest
        # way to avoid shouting at the whole LAN.
        if not args.any_flags and not (pkt['flags'] & BROADCAST_FLAG):
            if args.verbose:
                log(f'ignoring offer to {mac} ({offered}) - no broadcast flag')
            continue

        n = seen.get(mac, 0) + 1
        seen[mac] = n
        log(f'router offered {offered} to {mac}  (round {n}) '
            f'xid={pkt["xid"].hex()}')

        if args.dry_run:
            log('  dry run - not answering')
            continue

        offer = build_proxy_offer(pkt, server_ip, args.bootfile)
        sent = []
        for label, frame in delivery_variants(pkt, server_ip, server_mac, offer):
            try:
                tx.send(frame)
                sent.append(label)
            except OSError as e:
                log(f'  !! could not send ({label}): {e}')
        if not sent:
            continue

        shadowed += 1
        log(f'  -> proxy offer sent: boot {args.bootfile} from {server_ip}')
        log(f'     as: {", ".join(sent)}')
        if args.once and n >= 1:
            log('shadowed one client (--once). The target should be '
                'TFTPing now; watch it with:  sudo pxectl log')
            promisc.off()
            return 0


if __name__ == '__main__':
    sys.exit(main())
