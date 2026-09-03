#!/bin/bash
# add-windows-boot-entry.sh - give a freshly installed Proxmox node a GRUB entry
# for the Windows install still sitting on one of its other disks.
#
# Runs ON THE NODE, as root, AFTER Proxmox is installed:
#
#     ssh -i ~/Documents/DevOps/Manhattan/<node>/id_ed25519 root@<ip> \
#         'bash -s' < tools/add-windows-boot-entry.sh
#
#     ssh ... 'bash -s' < tools/add-windows-boot-entry.sh -- --dry-run
#
# Idempotent: re-running replaces the block it wrote last time and nothing else.
#
# WHY A HAND-WRITTEN ENTRY AND NOT os-prober
# ------------------------------------------
# The usual Debian answer is to install os-prober and set
# GRUB_DISABLE_OS_PROBER=false. Do not do that on a Proxmox host. os-prober
# scans and MOUNTS every block device it can find, and on a hypervisor that
# includes the LVM volumes and disk images belonging to running guests - which
# is a good way to corrupt a VM's filesystem while merely regenerating a boot
# menu. Proxmox ships with it absent for that reason.
#
# So this finds the Windows Boot Manager once, writes one static entry naming it
# by the ESP's filesystem UUID, and never scans again. The UUID is stable across
# reboots and does not care what the kernel calls the disk that day.

set -uo pipefail

DRY_RUN=0
TITLE="Windows 11"
MARK_BEGIN="### BEGIN add-windows-boot-entry.sh ###"
MARK_END="### END add-windows-boot-entry.sh ###"
CUSTOM=/etc/grub.d/40_custom

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1; shift ;;
        --title)      TITLE="${2:?--title needs a string}"; shift 2 ;;
        -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "add-windows-boot-entry.sh: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

die() { echo "add-windows-boot-entry.sh: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# ------------------------------------------------------------- 1 firmware --
if [ ! -d /sys/firmware/efi ]; then
    die "this host booted in legacy BIOS mode, but Windows 11 requires UEFI.
       The two cannot chainload each other across that boundary. Check the
       firmware setting - the node was probably installed in the wrong mode."
fi

# ------------------------------------------------- 2 which bootloader is it --
# Proxmox uses GRUB for an ext4/LVM root and systemd-boot for a ZFS one. Only
# the first reads 40_custom, so say plainly when this cannot work rather than
# writing a file that will never be looked at.
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    if proxmox-boot-tool status 2>/dev/null | grep -qi 'uefi.*systemd-boot\|systemd-boot'; then
        die "this node boots via systemd-boot (proxmox-boot-tool), which does not
       read $CUSTOM. Add the Windows entry from the firmware's own boot menu,
       or reinstall with an ext4/LVM root, which uses GRUB."
    fi
fi
command -v update-grub >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1 \
    || die "neither update-grub nor grub-mkconfig is installed - is this a GRUB system?"

# ------------------------------------------------------ 3 find the Windows --
# Every EFI System Partition on the machine, by GUID. Proxmox's own is in here
# too; it is told apart below by simply not containing a Windows Boot Manager.
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
mapfile -t ESPS < <(lsblk -rno NAME,PARTTYPE 2>/dev/null \
                    | awk -v g="$ESP_GUID" 'tolower($2)==g{print "/dev/"$1}')

[ "${#ESPS[@]}" -gt 0 ] || die "no EFI System Partition found on any disk"

MNT="$(mktemp -d)"
cleanup() { mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

WIN_DEV=""; WIN_UUID=""; WIN_PATH=""
say "==> looking for a Windows Boot Manager on ${#ESPS[@]} EFI partition(s)"
for esp in "${ESPS[@]}"; do
    # Read-only, so a half-shut-down Windows (fast startup leaves NTFS dirty,
    # and the ESP with it) cannot be damaged by looking at it.
    if ! mount -o ro "$esp" "$MNT" 2>/dev/null; then
        say "    $esp - could not mount, skipping"
        continue
    fi
    found=""
    for p in /EFI/Microsoft/Boot/bootmgfw.efi /efi/Microsoft/Boot/bootmgfw.efi; do
        [ -f "$MNT$p" ] && { found="$p"; break; }
    done
    if [ -n "$found" ]; then
        WIN_DEV="$esp"
        WIN_PATH="$found"
        WIN_UUID="$(blkid -s UUID -o value "$esp" 2>/dev/null)"
        say "    $esp - FOUND $found  (UUID $WIN_UUID)"
    else
        say "    $esp - no Windows Boot Manager (this is probably Proxmox's own)"
    fi
    umount "$MNT"
    [ -n "$WIN_DEV" ] && break
done

if [ -z "$WIN_DEV" ]; then
    die "no Windows Boot Manager found on any ESP.
       Either the Windows disk is not attached, or its ESP was erased. Check
       with:  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME"
fi
[ -n "$WIN_UUID" ] || die "$WIN_DEV holds Windows but reports no filesystem UUID
       - blkid could not read it, and an entry without a UUID cannot find it"

# The disk it lives on, purely so the menu entry says something a human can
# match against what they saw in disk-survey.sh.
WIN_DISK="$(lsblk -no PKNAME "$WIN_DEV" 2>/dev/null | head -1 | tr -d ' ')"

# ------------------------------------------------------- 4 the menu entry --
read -r -d '' BLOCK <<EOF
$MARK_BEGIN
# Written by add-windows-boot-entry.sh. Everything between these markers is
# replaced wholesale on the next run; edits here do not survive.
# Windows Boot Manager found on ${WIN_DEV}${WIN_DISK:+ (disk /dev/$WIN_DISK)}.
menuentry '$TITLE' --class windows --class os {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $WIN_UUID
    chainloader $WIN_PATH
}
$MARK_END
EOF

if [ "$DRY_RUN" -eq 1 ]; then
    say ""
    say "--- would append to $CUSTOM ---"
    printf '%s\n' "$BLOCK"
    say "--- then run update-grub ---"
    exit 0
fi

# ------------------------------------------------------------- 5 write it --
[ -f "$CUSTOM" ] || { printf '#!/bin/sh\nexec tail -n +3 $0\n' > "$CUSTOM"; chmod 0755 "$CUSTOM"; }

BACKUP="$CUSTOM.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CUSTOM" "$BACKUP"
say "==> backed up $CUSTOM -> $BACKUP"

# Drop any block a previous run left, then append the current one. sed rather
# than a rewrite-from-scratch so anything else in 40_custom is untouched.
TMP="$(mktemp)"
sed "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$CUSTOM" > "$TMP"
printf '%s\n' "$BLOCK" >> "$TMP"
cat "$TMP" > "$CUSTOM"
rm -f "$TMP"
chmod 0755 "$CUSTOM"
say "==> wrote the '$TITLE' entry into $CUSTOM"

# GRUB hides the menu entirely when it thinks it is the only OS on the machine,
# which would make the new entry unreachable without knowing to hold Shift.
if grep -qE '^[[:space:]]*GRUB_TIMEOUT_STYLE=hidden' /etc/default/grub 2>/dev/null; then
    say ""
    say "    NOTE: /etc/default/grub sets GRUB_TIMEOUT_STYLE=hidden, so the menu"
    say "          does not appear on its own. Set it to 'menu' (and GRUB_TIMEOUT"
    say "          to a few seconds) if you want to pick Windows without holding Shift."
fi

say "==> regenerating the boot menu"
if command -v update-grub >/dev/null 2>&1; then
    update-grub || die "update-grub failed - $CUSTOM has been restored from $BACKUP"
else
    grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"
fi

say ""
say "Done. '$TITLE' is now in the GRUB menu, chainloading:"
say "    $WIN_PATH  on  $WIN_DEV  (fs-uuid $WIN_UUID)"
say ""
say "Proxmox still boots by default. Verify the entry is listed with:"
say "    grep -c \"menuentry '\" /boot/grub/grub.cfg && grep \"$TITLE\" /boot/grub/grub.cfg"
say ""
say "If Windows then asks for a BitLocker recovery key on its first boot, that is"
say "the TPM noticing the boot path changed - it is expected, not damage. Have the"
say "key to hand before rebooting into it."
