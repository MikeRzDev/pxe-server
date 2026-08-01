#!/bin/bash
# fetch-iso.sh - generic payload fetcher: download an ISO and unpack it into
# the HTTP root so an iPXE script can boot it.
#
#   sudo ./fetch-iso.sh <name> <iso-url> [--whole]
#
#   <name>      payload name; files land in $PXE_ROOT/http/<name>/
#   --whole     copy the ENTIRE ISO contents, not just the boot bits
#               (needed by anaconda's inst.repo=, archiso, subiquity, etc.)
#
# Examples:
#   sudo ./fetch-iso.sh debian13 https://.../debian-13-netinst.iso
#   sudo ./fetch-iso.sh rocky10  https://.../Rocky-10-dvd.iso --whole
#
# Afterwards, write $PXE_ROOT/http/boot-<name>.ipxe - copy boot-EXAMPLE.ipxe
# and point it at the files this printed. Then `sudo pxectl <name>`.
#
# This does NOT try to guess kernel command lines. Every distro differs, and a
# wrong guess fails in confusing ways at boot; the example script lists the
# common patterns. Proxmox specifically needs its ISO embedded in the initrd -
# use build-proxmox.sh for that, not this.

set -euo pipefail

NAME="${1:-}"
URL="${2:-}"
WHOLE=0
[ "${3:-}" = "--whole" ] && WHOLE=1

if [ -z "$NAME" ] || [ -z "$URL" ]; then
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 1
fi
case "$NAME" in
    *[!a-zA-Z0-9_-]*) echo "fetch-iso.sh: '$NAME' - use only letters, digits, - and _" >&2; exit 1 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "fetch-iso.sh: must run as root (use sudo)" >&2; exit 1; }

PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
ISO_PATH="$PXE_ROOT/iso/${NAME}.iso"
DEST="$PXE_ROOT/http/$NAME"
MNT="$PXE_ROOT/work-$NAME/mnt"

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$PXE_ROOT/work-$NAME"
}
trap cleanup EXIT

install -d "$PXE_ROOT/iso" "$MNT"

if [ -f "$ISO_PATH" ]; then
    echo "==> ISO already present: $ISO_PATH"
else
    echo "==> downloading $URL"
    wget -c -O "$ISO_PATH" "$URL"
fi

[ -n "${ISO_SHA256:-}" ] && { echo "==> verifying sha256"; echo "$ISO_SHA256  $ISO_PATH" | sha256sum -c -; }

echo "==> mounting"
mount -o loop,ro "$ISO_PATH" "$MNT"

install -d "$DEST"
if [ "$WHOLE" -eq 1 ]; then
    echo "==> copying the whole ISO tree (this can take a while)"
    cp -a "$MNT/." "$DEST/"
else
    echo "==> copying boot files only (pass --whole for the full tree)"
    for d in boot isolinux images casper live install.amd install; do
        [ -d "$MNT/$d" ] || continue
        echo "    $d/"
        cp -a "$MNT/$d" "$DEST/"
    done
fi
umount "$MNT"
chmod -R a+rX "$DEST"

echo
echo "Unpacked to $DEST ($(du -sh "$DEST" | cut -f1))"
echo
echo "Kernels and initrds found - use these paths in boot-$NAME.ipxe:"
find "$DEST" \( -name 'vmlinuz*' -o -name 'linux' -o -name 'initrd*' -o -name '*.img' \) \
     -type f -printf '    http://<server>/%P\n' 2>/dev/null | sort | head -30
cat <<EOF

Next:
    cp $PXE_ROOT/http/boot-EXAMPLE.ipxe $PXE_ROOT/http/boot-$NAME.ipxe
    \$EDITOR $PXE_ROOT/http/boot-$NAME.ipxe     # set kernel/initrd + cmdline
    sudo pxectl list
    sudo pxectl $NAME
EOF
