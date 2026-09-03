#!/bin/bash
# build-ipxe-chain.sh - build an iPXE binary that knows where this server is.
#
#   sudo ./build-ipxe-chain.sh                     # uses SERVER_IP from pxe.env / autodetect
#   sudo ./build-ipxe-chain.sh --server 192.0.2.10
#
# Produces $PXE_ROOT/http/ipxe-chain.efi (and .kpxe for legacy BIOS), served
# over plain HTTP so a machine can be pointed straight at it.
#
# WHY THIS EXISTS
# ---------------
# The normal boot path is proxy-DHCP: dnsmasq overhears a client's DHCP
# broadcast and injects "fetch ipxe.efi from <this server>" alongside the real
# DHCP server's reply. That is passive, and it has one hard requirement - the
# server has to HEAR the broadcast.
#
# On a LAN where the client sits behind a router that answers DHCP itself and
# does not flood the request onward, the PXE server never hears it, never
# speaks, and the client waits for boot information nobody sends. Nothing is
# misconfigured; the discovery mechanism simply cannot reach across.
#
# Everything AFTER discovery is ordinary unicast and crosses such a router
# without complaint - TFTP, the 2 GB initrd over HTTP, the answer-file POST.
# So the fix is to stop needing discovery: bake the server's address into iPXE
# itself. Then the client only has to be told, once and statically, where to
# fetch this file from, and the whole normal flow resumes behind it.
#
# Three ways to use the result, all of which skip proxy-DHCP:
#
#   1. UEFI HTTP Boot with a manually entered URI, if the firmware offers the
#      field:   http://<server>/ipxe-chain.efi
#   2. A FAT32 USB stick with it copied to /EFI/BOOT/BOOTX64.EFI - no imaging
#      tool needed, just a file copy.
#   3. The router's own DHCP, if it can be given option 66/67 - then it is
#      handed out to everyone and nothing manual is needed at all.
#
# The build needs an x86_64 compiler. On an arm64 host (a Pi) that means the
# cross toolchain, which this installs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
SERVER_IP="${SERVER_IP:-}"
WORK=/tmp/ipxe-chain-build

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER_IP="${2:?--server needs an address}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-ipxe-chain.sh: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "build-ipxe-chain.sh: must run as root (use sudo)" >&2; exit 1; }

# Same resolution order install.sh uses, so both agree on which address this
# server answers on.
if [ -z "$SERVER_IP" ]; then
    [ -f "$REPO/pxe.env" ] && . "$REPO/pxe.env"
fi
if [ -z "$SERVER_IP" ]; then
    IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    SERVER_IP="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[ -n "$SERVER_IP" ] || { echo "build-ipxe-chain.sh: could not determine SERVER_IP - pass --server" >&2; exit 1; }

echo "iPXE chainloader for $SERVER_IP"

# ------------------------------------------------------------ toolchain ----
# build-essential, not just the cross compiler. iPXE builds its own host-side
# tool (elf2efi64) with the NATIVE compiler, and both ways of getting that
# wrong fail late and misleadingly, after several minutes of successful
# cross-compiling:
#
#   no gcc at all   ->  "make: gcc: No such file or directory"
#   gcc but no libc6-dev ->
#       include/stdint.h:17: fatal error: bits/stdint.h: No such file
#
# The second one is the trap. gcc's own <stdint.h> ends in #include_next; with
# no /usr/include/stdint.h to find, the search falls through to iPXE's OWN
# stdint.h (on the -idirafter path), which then asks for a target header the
# host arch does not have. It reads exactly like "iPXE cannot be built on this
# architecture" and is nothing of the sort - libc6-dev is merely a *Recommends*
# of the gcc metapackage, so any --no-install-recommends install omits it.
# build-essential depends on it outright, which is why it is named here.
NEED=(git make perl gcc)
command -v x86_64-linux-gnu-gcc >/dev/null || NEED+=(gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu)
MISSING=()
for p in "${NEED[@]}"; do
    case "$p" in
        git|make|perl|gcc) command -v "$p" >/dev/null || MISSING+=("$p") ;;
        *) dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p") ;;
    esac
done
# Native libc headers for the host tool - see above. Checked by package, not by
# `command -v`, because there is no binary to look for.
dpkg -s libc6-dev  >/dev/null 2>&1 || MISSING+=(build-essential)
dpkg -s liblzma-dev >/dev/null 2>&1 || MISSING+=(liblzma-dev)
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "==> installing: ${MISSING[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${MISSING[@]}"
fi

# --------------------------------------------------------------- script ----
mkdir -p "$WORK"
cat > "$WORK/chain.ipxe" <<EOF
#!ipxe
# Embedded at build time. The address below is why this binary exists: it is
# the one thing a client on the far side of a DHCP-eating router cannot be told
# by the network, so it is told by the file instead.
echo
echo iPXE - PXE server $SERVER_IP
echo
# Bare "dhcp", not "dhcp net0": these boards are dual-NIC and the one with a
# cable in it is not reliably net0. This tries every interface.
dhcp || goto nodhcp
echo Address \${net0/ip} - fetching the armed payload from $SERVER_IP
chain --autofree http://$SERVER_IP/boot.ipxe || goto nochain
exit

:nodhcp
echo
echo DHCP failed on every interface. This needs only an ADDRESS from the LAN's
echo normal DHCP server; it does not need that server to know anything at all
echo about booting.
echo Type "dhcp" to retry, or "exit" to hand back to the firmware.
shell

:nochain
echo
echo Could not fetch http://$SERVER_IP/boot.ipxe
echo Nothing is armed, or this machine cannot reach $SERVER_IP.
echo Check on the server:  sudo pxectl status
echo Type "chain http://$SERVER_IP/boot.ipxe" to retry.
shell
EOF

echo "==> embedded script:"
sed 's/^/    /' "$WORK/chain.ipxe"

# ---------------------------------------------------------------- build ----
if [ -d "$WORK/ipxe/.git" ]; then
    echo "==> updating the iPXE tree"
    git -C "$WORK/ipxe" fetch --depth 1 origin master -q && git -C "$WORK/ipxe" reset --hard -q FETCH_HEAD
else
    echo "==> cloning iPXE"
    rm -rf "$WORK/ipxe"
    git clone --depth 1 -q https://github.com/ipxe/ipxe.git "$WORK/ipxe"
fi

cd "$WORK/ipxe/src"
CROSS=""
[ "$(uname -m)" != "x86_64" ] && CROSS="CROSS_COMPILE=x86_64-linux-gnu-"

echo "==> building (this takes a few minutes)"
# shellcheck disable=SC2086
make -j"$(nproc)" $CROSS bin-x86_64-efi/ipxe.efi EMBED="$WORK/chain.ipxe" >/dev/null
# shellcheck disable=SC2086
make -j"$(nproc)" $CROSS bin/undionly.kpxe     EMBED="$WORK/chain.ipxe" >/dev/null || \
    echo "    (legacy BIOS build failed - the UEFI one is what modern boards use)"

# Both roots. HTTP is how a machine fetches it to install on its own ESP
# (tools/pxe-boot-from-windows.ps1); TFTP is how tools/dhcp-offer-shadow.py
# hands it out, since a PXE ROM can only fetch its boot file over TFTP.
install -d -m 0755 "$PXE_ROOT/http" "$PXE_ROOT/tftp"
for root in "$PXE_ROOT/http" "$PXE_ROOT/tftp"; do
    install -m 0644 bin-x86_64-efi/ipxe.efi "$root/ipxe-chain.efi"
    [ -f bin/undionly.kpxe ] && install -m 0644 bin/undionly.kpxe "$root/ipxe-chain.kpxe"
done

echo
echo "Done."
ls -la "$PXE_ROOT/http/ipxe-chain."* "$PXE_ROOT/tftp/ipxe-chain."* 2>/dev/null
cat <<MSG

Point a machine at it, any of these ways:

  UEFI HTTP Boot URI (BIOS field, if the firmware has one):
      http://$SERVER_IP/ipxe-chain.efi

  USB stick (FAT32, plain file copy - no imaging tool):
      /EFI/BOOT/BOOTX64.EFI   <- ipxe-chain.efi renamed

  The LAN router's DHCP, if it can set next-server/bootfile:
      next-server $SERVER_IP   bootfile ipxe.efi

Then arm a payload as usual (~/scripts/onboard-node.sh <name>) and boot it.
MSG
