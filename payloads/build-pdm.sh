#!/bin/bash
# build-pdm.sh - build a Proxmox Datacenter Manager PXE payload from an ISO.
#
#   sudo ./build-pdm.sh                          # download 1.1-1, build "pdm"
#   sudo ./build-pdm.sh 1.1-1
#   PDM_SHA256=<hash> sudo ./build-pdm.sh 1.1-1
#
#   # build the UNATTENDED fleet payload from an already-prepared ISO
#   sudo ./build-pdm.sh --iso /srv/pxe/iso/proxmox-datacenter-manager_1.1-1-fleet.iso \
#                       --name pdm-fleet
#
# Produces:
#   $PXE_ROOT/http/<name>/linux26   the installer kernel (~16 MB)
#   $PXE_ROOT/http/<name>/initrd    the initrd with the ISO embedded (~2.0 GB)
#
# This is the PDM sibling of build-proxmox.sh. PDM ships the same installer as
# PVE, so the mechanics are identical - only the product, ISO name, URL and
# default payload name differ. The two are kept apart on purpose: you should
# not be able to typo a version number and quietly build the wrong product onto
# a payload name the other one owns.
#
# The ISO is EMBEDDED IN THE INITRD on purpose. Proxmox's installer init looks
# for /proxmox.iso inside the initrd - the name is the same for PDM as for PVE;
# there is no "fetch the ISO from a URL" kernel parameter. Hence the 2 GB
# initrd, and hence `ramdisk_size=16777216` on the kernel cmdline in
# boot-pdm-fleet.ipxe - too small and it will not unpack, with no useful error.
#
# --iso lets the same embedding logic serve the unattended variant: an ISO that
# proxmox-auto-install-assistant has already prepared. See prepare-auto-iso.sh
# (it is product-agnostic and takes a PDM ISO fine), which needs an amd64 host.

set -euo pipefail

PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
PDM_VERSION=""
SRC_ISO=""
NAME="pdm"

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)  SRC_ISO="${2:?--iso needs a path}"; shift 2 ;;
        --name) NAME="${2:?--name needs a payload directory name}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "build-pdm.sh: unknown option '$1'" >&2; exit 1 ;;
        *)  PDM_VERSION="$1"; shift ;;
    esac
done
PDM_VERSION="${PDM_VERSION:-1.1-1}"

ISO_NAME="proxmox-datacenter-manager_${PDM_VERSION}.iso"
ISO_URL="${PDM_ISO_URL:-https://enterprise.proxmox.com/iso/${ISO_NAME}}"
# Unlike build-proxmox.sh, the checksum for the default version is baked in -
# it is published in https://enterprise.proxmox.com/iso/SHA256SUMS and an
# unverified 1.4 GB download that later fails mid-install is a slow way to find
# out. Override PDM_SHA256 (or set it empty) when building another version.
if [ "$PDM_VERSION" = "1.1-1" ]; then
    PDM_SHA256="${PDM_SHA256-11a55a069ba564220bd986241b57920a83781d40be18d6f2bf7b9b12696ae2cc}"
fi
# All source ISOs live in one place, $PXE_ROOT/iso - same as build-proxmox.sh
# and fetch-iso.sh. Built payloads go under $PXE_ROOT/http/<name>/.
ISO_PATH="${SRC_ISO:-$PXE_ROOT/iso/$ISO_NAME}"
# Build here, never /tmp - /tmp is a small tmpfs on DietPi and this needs ~4 GB.
WORK="$PXE_ROOT/work"
DEST="$PXE_ROOT/http/$NAME"
MNT="$WORK/mnt"

[ "$(id -u)" -eq 0 ] || { echo "build-pdm.sh: must run as root (use sudo)" >&2; exit 1; }

if [ -n "$SRC_ISO" ] && [ ! -f "$SRC_ISO" ]; then
    echo "build-pdm.sh: --iso '$SRC_ISO' does not exist" >&2
    exit 1
fi

echo "Proxmox Datacenter Manager $PDM_VERSION -> $DEST"
[ -n "$SRC_ISO" ] && echo "  using prepared ISO: $SRC_ISO"

need_free_gb=7
avail_gb=$(df -BG --output=avail "$PXE_ROOT" | tail -1 | tr -dc '0-9')
if [ "${avail_gb:-0}" -lt "$need_free_gb" ]; then
    echo "build-pdm.sh: need ~${need_free_gb}G free under $PXE_ROOT, have ${avail_gb}G" >&2
    exit 1
fi

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

install -d "$PXE_ROOT/iso" "$DEST" "$MNT"

# ------------------------------------------------------------------ fetch ---
if [ -f "$ISO_PATH" ]; then
    echo "==> ISO already present: $ISO_PATH"
elif [ -n "$SRC_ISO" ]; then
    echo "build-pdm.sh: prepared ISO '$SRC_ISO' vanished" >&2; exit 1
else
    echo "==> downloading $ISO_URL"
    wget -c -O "$ISO_PATH" "$ISO_URL"
fi

# A prepared ISO has had an answer-fetch URL written into it, so its hash no
# longer matches the published one - only check when we fetched the stock ISO.
if [ -n "$SRC_ISO" ]; then
    echo "==> sha256 not checked (a prepared ISO differs from the published one)"
elif [ -n "${PDM_SHA256:-}" ]; then
    echo "==> verifying sha256"
    echo "$PDM_SHA256  $ISO_PATH" | sha256sum -c -
else
    echo "==> sha256 not checked (set PDM_SHA256 to verify against the downloads page)"
fi

# ----------------------------------------------------------------- extract --
echo "==> mounting ISO"
mount -o loop,ro "$ISO_PATH" "$MNT"

[ -f "$MNT/boot/linux26" ] || {
    echo "build-pdm.sh: $ISO_PATH has no boot/linux26 - is this really a Proxmox installer ISO?" >&2
    exit 1
}

echo "==> kernel -> $DEST/linux26"
install -m 0644 "$MNT/boot/linux26" "$DEST/linux26"

echo "==> copying initrd out of the ISO"
cp "$MNT/boot/initrd.img" "$WORK/initrd.img"
umount "$MNT"

# ------------------------------------------------------------- decompress ---
# PDM 1.1 ships a zstd initrd, as PVE 9.2 does. Detect by magic bytes rather
# than assuming - guessing wrong produces a confusing cpio error.
magic=$(head -c4 "$WORK/initrd.img" | od -An -tx1 | tr -d ' \n')
case "$magic" in
    28b52ffd*) echo "==> initrd is zstd"; zstd -q -d "$WORK/initrd.img" -o "$WORK/initrd" ;;
    1f8b*)     echo "==> initrd is gzip"; gzip  -dc "$WORK/initrd.img" > "$WORK/initrd" ;;
    fd377a58*) echo "==> initrd is xz";   xz    -dc "$WORK/initrd.img" > "$WORK/initrd" ;;
    *)         echo "build-pdm.sh: unknown initrd compression (magic $magic)" >&2; exit 1 ;;
esac
chmod u+w "$WORK/initrd"

# ---------------------------------------------------------- embed the ISO ---
# Hardlink so this does not cost another 1.4 GB. The archive member must be
# named exactly "proxmox.iso" - that is the path the installer init looks for,
# for PDM as much as for PVE.
echo "==> embedding the ISO into the initrd (appending as /proxmox.iso)"
ln -f "$ISO_PATH" "$WORK/proxmox.iso"
( cd "$WORK" && echo proxmox.iso | cpio -H newc -o -A -F initrd --quiet )

echo "==> installing initrd"
install -m 0644 "$WORK/initrd" "$DEST/initrd"

# The initrd is left UNCOMPRESSED on purpose: the kernel unpacks it into the
# ramdisk either way, and compressing a 2 GB image costs minutes per rebuild
# and buys nothing here - the ISO inside is already compressed.

echo
echo "Done."
ls -lh "$DEST/linux26" "$DEST/initrd"
echo
echo "Verify the embedded ISO is really in there:"
echo "    cpio -itv --quiet < $DEST/initrd | grep proxmox.iso"
