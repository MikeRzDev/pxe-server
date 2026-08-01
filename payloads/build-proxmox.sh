#!/bin/bash
# build-proxmox.sh - fetch a Proxmox VE ISO and build the PXE payload from it.
#
#   sudo ./build-proxmox.sh                 # default version below
#   sudo ./build-proxmox.sh 9.2-1
#   PVE_SHA256=<hash> sudo ./build-proxmox.sh 9.2-1
#
# Produces:
#   $PXE_ROOT/http/pve/linux26   the installer kernel (~16 MB)
#   $PXE_ROOT/http/pve/initrd    the initrd with the ISO embedded (~2.0 GB)
#
# The ISO is EMBEDDED IN THE INITRD on purpose. Proxmox's installer init looks
# for /proxmox.iso inside the initrd; there is no "fetch the ISO from a URL"
# kernel parameter. Hence the 2 GB initrd, and hence `ramdisk_size=16777216`
# on the kernel cmdline in boot-proxmox.ipxe - too small and it will not
# unpack, with no useful error.

set -euo pipefail

PVE_VERSION="${1:-9.2-1}"
PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
ISO_NAME="proxmox-ve_${PVE_VERSION}.iso"
ISO_URL="${PVE_ISO_URL:-https://enterprise.proxmox.com/iso/${ISO_NAME}}"
ISO_PATH="$PXE_ROOT/pve/$ISO_NAME"
# Build here, never /tmp - /tmp is a small tmpfs on DietPi and this needs ~4 GB.
WORK="$PXE_ROOT/work"
DEST="$PXE_ROOT/http/pve"
MNT="$WORK/mnt"

[ "$(id -u)" -eq 0 ] || { echo "build-proxmox.sh: must run as root (use sudo)" >&2; exit 1; }

echo "Proxmox VE $PVE_VERSION -> $DEST"

need_free_gb=7
avail_gb=$(df -BG --output=avail "$PXE_ROOT" | tail -1 | tr -dc '0-9')
if [ "${avail_gb:-0}" -lt "$need_free_gb" ]; then
    echo "build-proxmox.sh: need ~${need_free_gb}G free under $PXE_ROOT, have ${avail_gb}G" >&2
    exit 1
fi

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

install -d "$PXE_ROOT/pve" "$DEST" "$MNT"

# ------------------------------------------------------------------ fetch ---
if [ -f "$ISO_PATH" ]; then
    echo "==> ISO already present: $ISO_PATH"
else
    echo "==> downloading $ISO_URL"
    wget -c -O "$ISO_PATH" "$ISO_URL"
fi

if [ -n "${PVE_SHA256:-}" ]; then
    echo "==> verifying sha256"
    echo "$PVE_SHA256  $ISO_PATH" | sha256sum -c -
else
    echo "==> sha256 not checked (set PVE_SHA256 to verify against the downloads page)"
fi

# ----------------------------------------------------------------- extract --
echo "==> mounting ISO"
mount -o loop,ro "$ISO_PATH" "$MNT"

echo "==> kernel -> $DEST/linux26"
install -m 0644 "$MNT/boot/linux26" "$DEST/linux26"

echo "==> copying initrd out of the ISO"
cp "$MNT/boot/initrd.img" "$WORK/initrd.img"
umount "$MNT"

# ------------------------------------------------------------- decompress ---
# 9.2 ships a zstd initrd, older releases used gzip/xz. Detect by magic bytes
# rather than assuming - guessing wrong produces a confusing cpio error.
magic=$(head -c4 "$WORK/initrd.img" | od -An -tx1 | tr -d ' \n')
case "$magic" in
    28b52ffd*) echo "==> initrd is zstd"; zstd -q -d "$WORK/initrd.img" -o "$WORK/initrd" ;;
    1f8b*)     echo "==> initrd is gzip"; gzip  -dc "$WORK/initrd.img" > "$WORK/initrd" ;;
    fd377a58*) echo "==> initrd is xz";   xz    -dc "$WORK/initrd.img" > "$WORK/initrd" ;;
    *)         echo "build-proxmox.sh: unknown initrd compression (magic $magic)" >&2; exit 1 ;;
esac
chmod u+w "$WORK/initrd"

# ---------------------------------------------------------- embed the ISO ---
# Hardlink so this does not cost another 1.7 GB. The archive member must be
# named exactly "proxmox.iso" - that is the path the installer init looks for.
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
