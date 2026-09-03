#!/bin/bash
# disk-survey.sh - inventory a machine's disks from Linux, in the exact terms
# the Proxmox auto-installer uses to choose which one to erase.
#
#   From SystemRescue booted off this PXE server (nginx is up while a payload
#   is armed, so this fetches over the same LAN it netbooted from):
#
#       curl -s http://@@SERVER_IP@@/tools/disk-survey.sh | bash
#
#   Add --post to file the report on the PXE server as well, so it can be read
#   from there instead of off the target's monitor:
#
#       curl -s http://@@SERVER_IP@@/tools/disk-survey.sh | bash -s -- --post
#
#   Or on any already-installed Linux box:  sudo ./disk-survey.sh
#
# Reads only. It mounts nothing, writes to no block device, and touches no boot
# setting - safe to run on a machine whose contents you care about.
#
# WHY THIS AND NOT JUST `lsblk`
# -----------------------------
# The answer file names its target either by kernel device name (sda, nvme0n1)
# or by a udev property glob. Kernel names are handed out in probe order and are
# NOT stable across reboots on a multi-disk machine: the disk you are looking at
# as sdb can come up as sde on the boot that actually installs. On a box that
# still holds a Windows install, that is the difference between a spare disk and
# everything on it.
#
# So this prints the udev properties too, and hands back a ready-made
# --disk-serial flag - the one form of selection that cannot drift. And it
# prints what is ON each disk (partition labels, filesystem, used and free
# space, whether it carries NTFS or an EFI System Partition), because that is
# how a person actually recognises a disk, and being certain is the entire job.

set -uo pipefail

# Where --post sends the report: the answer server, not nginx. nginx replies to
# a POST for a static path with 405, which is the same reason that separate
# service exists in the first place.
DEFAULT_POST_URL="http://@@SERVER_IP@@:8080/survey"
POST_URL=""

usage() {
    cat <<'USAGE'
disk-survey.sh - what is in this machine, in the installer's own terms.

    disk-survey.sh                 print the report
    disk-survey.sh --post          print it and file it on the PXE server
    disk-survey.sh --post <url>    ... to somewhere else

Run as root. Reads only.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --post)
            # Optional argument: a bare --post means the default endpoint.
            case "${2-}" in
                ""|-*) POST_URL="$DEFAULT_POST_URL"; shift ;;
                *)     POST_URL="$2"; shift 2 ;;
            esac ;;
        -h|--help) usage; exit 0 ;;
        *) echo "disk-survey.sh: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "disk-survey.sh: run as root - udev properties and free space need it." >&2
    echo "                (SystemRescue already gives you a root shell.)" >&2
    exit 1
fi

command -v lsblk >/dev/null || { echo "disk-survey.sh: lsblk not found" >&2; exit 1; }

# Pull one KEY="value" out of a line of `lsblk -P` output. Pairs mode rather
# than -r columns because a disk with no LABEL prints an empty field, and a
# positional `read` silently shifts every column after it - which would attach
# one partition's label to another partition's size. Getting that wrong here is
# exactly the mistake this script exists to prevent.
#
# The key must sit at the start of the line or after a space: several lsblk
# column names END with another one (PARTTYPENAME ends with NAME, FSAVAIL with
# AVAIL), and an unanchored match happily returns the wrong column's value.
field() {
    printf '%s' "$1" \
        | grep -o "\(^\| \)$2=\"[^\"]*\"" \
        | head -1 \
        | sed "s/^ //; s/^$2=\"//; s/\"$//"
}

# udev property for a device, empty if absent or if udevadm is unavailable.
prop() {
    command -v udevadm >/dev/null || return 0
    udevadm info --query=property --name="$1" 2>/dev/null \
        | sed -n "s/^$2=//p" | head -1
}

human() {  # bytes -> "931.5GB"
    numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null \
        || printf '%s' "${1:-0}"
}

# The whole report is built in one function so it can be both printed and, with
# --post, sent verbatim. Re-deriving it server-side from raw JSON would mean
# writing the same judgements twice; this way what was read is what gets filed.
report() {
    echo ""
    echo "======================================================================"
    echo " DISK SURVEY  -  $(hostname 2>/dev/null || echo unknown)  -  $(date '+%Y-%m-%d %H:%M:%S')"
    echo " kernel $(uname -r)  -  this is what the Proxmox installer will see"
    echo "======================================================================"

    # The MACs, because enrolling this machine afterwards wants one and this is
    # the moment it is known for free - no second boot to discover it.
    local nic mac
    for nic in /sys/class/net/*; do
        [ -e "$nic/address" ] || continue
        case "$(basename "$nic")" in lo) continue ;; esac
        mac="$(cat "$nic/address" 2>/dev/null)"
        [ "$mac" = "00:00:00:00:00:00" ] && continue
        printf ' NIC %-10s %s%s\n' "$(basename "$nic")" "$mac" \
               "$([ "$(cat "$nic/carrier" 2>/dev/null)" = "1" ] && echo "   (link up)")"
    done

    # The disk the running system booted from is never a candidate. Under
    # SystemRescue that is the ramdisk, so this usually finds nothing - which is
    # correct, and why it is only one of several signals below.
    local root_src root_disk=""
    root_src="$(findmnt -no SOURCE / 2>/dev/null)"
    [ -n "$root_src" ] && root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 | tr -d ' ')"

    local disks summary="" d
    mapfile -t disks < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

    if [ "${#disks[@]}" -eq 0 ]; then
        echo ""
        echo "  NO DISKS FOUND. On an NVMe or hardware-RAID box this usually means the"
        echo "  controller driver is not loaded - which would stop the Proxmox installer"
        echo "  just as dead. Fix that before enrolling this machine."
        return 1
    fi

    for d in "${disks[@]}"; do
        local dev="/dev/$d"
        local size_b model tran rota ptt serial wwn bus
        size_b="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
        model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/  */ /g;s/^ *//;s/ *$//')"
        tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null | tr -d ' ')"
        rota="$(lsblk -dn -o ROTA "$dev" 2>/dev/null | tr -d ' ')"
        ptt="$(lsblk -dn -o PTTYPE "$dev" 2>/dev/null | tr -d ' ')"

        # ID_SERIAL_SHORT first: that is the property the answer file's
        # filter.ID_SERIAL_SHORT is compared against, so reading it from the
        # same source the installer will means no translation step.
        serial="$(prop "$dev" ID_SERIAL_SHORT)"
        [ -z "$serial" ] && serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | tr -d ' ')"
        wwn="$(prop "$dev" ID_WWN)"
        bus="$(prop "$dev" ID_BUS)"

        echo ""
        echo "----------------------------------------------------------------------"
        echo "  $dev    ${model:-(no model reported)}"
        echo "    size        : $(human "$size_b")   ($size_b bytes)"
        echo "    serial      : ${serial:-(none reported)}"
        [ -n "$wwn" ] && echo "    wwn         : $wwn"
        echo "    bus         : ${tran:-?}${bus:+  (udev ID_BUS=$bus)}   $([ "$rota" = "0" ] && echo "SSD/NVMe" || echo "rotational")"
        echo "    part table  : ${ptt:-none}"

        local part_count=0 has_ntfs=0 has_esp=0 labels="" line
        local out=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local pname psize pfs plabel ptype pused pavail pmnt
            pname="$(field "$line" NAME)"
            [ "$pname" = "$d" ] && continue          # the disk itself
            part_count=$((part_count + 1))
            psize="$(field "$line" SIZE)"
            pfs="$(field "$line" FSTYPE)"
            plabel="$(field "$line" LABEL)"
            ptype="$(field "$line" PARTTYPENAME)"
            pused="$(field "$line" FSUSED)"
            pavail="$(field "$line" FSAVAIL)"
            pmnt="$(field "$line" MOUNTPOINT)"

            case "$pfs" in ntfs|ntfs3) has_ntfs=1 ;; esac
            case "$ptype" in *"EFI System"*) has_esp=1 ;; esac
            case "$plabel" in [Ww]indows*|WINRE*|[Rr]ecovery*|SYSTEM) has_ntfs=1 ;; esac
            [ -n "$plabel" ] && labels="${labels:+$labels, }$plabel"

            # An unlabelled partition shows its partition TYPE in angle
            # brackets instead, so the column is never blank and a type is
            # never mistaken for a name somebody chose.
            out="$out$(printf '      %-12s %-8s %-8s %-20s %-8s %-8s %s' \
                "$pname" "${psize:--}" "${pfs:--}" \
                "${plabel:-${ptype:+<$ptype>}}" \
                "${pused:--}" "${pavail:--}" "${pmnt:--}")
"
        done < <(lsblk -P -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME,FSUSED,FSAVAIL,MOUNTPOINT "$dev" 2>/dev/null)

        if [ "$part_count" -gt 0 ]; then
            echo "    partitions  :"
            printf '      %-12s %-8s %-8s %-20s %-8s %-8s %s\n' \
                   NAME SIZE FSTYPE LABEL USED FREE MOUNT
            printf '%s' "$out"
        else
            echo "    partitions  : none (raw / uninitialised disk)"
        fi

        # ------------------------------------------------------- verdict --
        local verdict
        echo ""
        if [ -n "$root_disk" ] && [ "$root_disk" = "$d" ]; then
            verdict="IN USE (booted from)"
            echo "    >>> DO NOT INSTALL HERE - the running system booted from this disk. <<<"
        elif [ "$has_ntfs" -eq 1 ] || [ "$has_esp" -eq 1 ]; then
            local what=""
            [ "$has_ntfs" -eq 1 ] && what="an NTFS/Windows filesystem"
            [ "$has_esp" -eq 1 ] && what="${what:+$what and }an EFI System Partition"
            verdict="WINDOWS/BOOT - keep"
            echo "    >>> CAREFUL - this disk carries $what."
            echo "        On a dual-boot build this is the one to KEEP, not the one to install to."
            echo "        Wiping it takes Windows and its boot manager with it. <<<"
        elif [ "$part_count" -eq 0 ]; then
            verdict="empty - safe"
            echo "    EMPTY / uninitialised - nothing here to lose."
        else
            verdict="has data"
            echo "    Has partitions but no Windows or EFI marker. Read the labels above"
            echo "    (${labels:-no labels}) - installing here destroys whatever they are."
        fi

        echo ""
        if [ -n "$serial" ]; then
            echo "    to install HERE:   --disk-serial $serial"
        else
            echo "    no serial reported - fall back to  --disk $d  and accept that the"
            echo "    name can move if this machine's disks are probed in another order."
        fi

        summary="$summary$(printf '  %-12s %-10s %-24s %-20s %s' \
            "$dev" "$(human "$size_b")" "${serial:-?}" "${model:0:20}" "$verdict")
"
    done

    echo ""
    echo "======================================================================"
    echo " SUMMARY"
    echo "======================================================================"
    echo ""
    printf '  %-12s %-10s %-24s %-20s %s\n' DEVICE SIZE SERIAL MODEL VERDICT
    printf '%s' "$summary"
    echo ""
    echo "  On the PXE server (arduino):"
    echo ""
    echo "      ~/scripts/onboard-node.sh <name> --disk-serial <SERIAL>"
    echo ""
    echo "  The serial goes into the answer file as filter.ID_SERIAL_SHORT and is"
    echo "  resolved on the target, so it selects the same physical disk no matter"
    echo "  what the kernel calls it on the boot that actually installs."
    echo ""
}

REPORT="$(report)"
rc=$?
printf '%s\n' "$REPORT"
[ "$rc" -ne 0 ] && exit "$rc"

if [ -n "$POST_URL" ]; then
    if command -v curl >/dev/null; then
        # Name the stored file after a MAC where there is one, so the survey
        # lines up with the answer file this machine is later given.
        mac="$(cat /sys/class/net/*/address 2>/dev/null \
               | grep -v '^00:00:00:00:00:00$' | head -1)"
        if printf '%s\n' "$REPORT" | curl -sf -X POST --data-binary @- \
                -H 'Content-Type: text/plain' \
                ${mac:+-H "X-Survey-Mac: $mac"} "$POST_URL" >/dev/null; then
            echo "  report filed on the PXE server${mac:+ as ${mac//:/}.txt}"
            echo "  read it there with:  cat /srv/pxe/surveys/*.txt"
        else
            echo "  POST to $POST_URL failed - is a payload armed, so the server is up?"
            echo "  (the report above is complete either way)"
        fi
        echo ""
    else
        echo "  --post given but curl is not installed here."
    fi
fi
