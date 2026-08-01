#!/bin/bash
# build-rescue.sh - fetch a SystemRescue ISO and unpack the PXE payload from it.
#
#   sudo ./build-rescue.sh                  # default version below
#   sudo ./build-rescue.sh 13.01
#
# Produces $PXE_ROOT/http/sysresccd/ - the archiso tree, served over HTTP.
#
# Unlike Proxmox this needs no initrd surgery: SystemRescue's archiso boots
# with archiso_http_srv=<url> and pulls its own squashfs over HTTP, which is
# what boot-rescue.ipxe passes on the kernel cmdline.

set -euo pipefail

SRC_VERSION="${1:-13.01}"
PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
ISO_NAME="systemrescue-${SRC_VERSION}-amd64.iso"
MAJOR="${SRC_VERSION%%.*}"
ISO_URL="${SRC_ISO_URL:-https://fastly-cdn.system-rescue.org/releases/${SRC_VERSION}/${ISO_NAME}}"
ISO_PATH="$PXE_ROOT/iso/$ISO_NAME"
WORK="$PXE_ROOT/work-rescue"
DEST="$PXE_ROOT/http/sysresccd"
MNT="$WORK/mnt"

[ "$(id -u)" -eq 0 ] || { echo "build-rescue.sh: must run as root (use sudo)" >&2; exit 1; }

echo "SystemRescue $SRC_VERSION -> $DEST"

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

install -d "$PXE_ROOT/iso" "$MNT"

if [ -f "$ISO_PATH" ]; then
    echo "==> ISO already present: $ISO_PATH"
else
    echo "==> downloading $ISO_URL"
    wget -c -O "$ISO_PATH" "$ISO_URL"
fi

if [ -n "${SRC_SHA256:-}" ]; then
    echo "==> verifying sha256"
    echo "$SRC_SHA256  $ISO_PATH" | sha256sum -c -
fi

echo "==> mounting ISO"
mount -o loop,ro "$ISO_PATH" "$MNT"

if [ ! -d "$MNT/sysresccd" ]; then
    echo "build-rescue.sh: no /sysresccd directory in the ISO - unexpected layout" >&2
    exit 1
fi

echo "==> copying the sysresccd tree (~1.3 GB, takes a minute)"
rm -rf "$DEST"
install -d "$DEST"
cp -a "$MNT/sysresccd/." "$DEST/"
umount "$MNT"

chmod -R a+rX "$DEST"

echo
echo "Done."
du -sh "$DEST"
echo
echo "boot-rescue.ipxe expects these to exist:"
for f in boot/x86_64/vmlinuz boot/x86_64/sysresccd.img boot/intel_ucode.img boot/amd_ucode.img; do
    if [ -f "$DEST/$f" ]; then echo "    ok      $f"; else echo "    MISSING $f"; fi
done
