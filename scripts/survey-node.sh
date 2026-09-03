#!/bin/bash
# survey-node.sh - find out what disks are in a machine, without touching it.
#
#     ~/scripts/survey-node.sh
#     ~/scripts/survey-node.sh --wait 30      # minutes to wait (default 20)
#     ~/scripts/survey-node.sh --keep-armed   # surveying several machines
#
# Arms the read-only `survey` payload, waits for a machine to netboot and
# report, prints the report, and disarms. Then power the target on, set to boot
# from the network via its UEFI **"PXE IPv4"** entry - not "HTTP IPv4", which
# this server has no DHCP rules for and never answers.
#
# NOTHING IS WRITTEN TO THE TARGET. SystemRescue runs entirely from RAM, the
# survey only reads block-device metadata, and the machine REBOOTS once the
# report has been delivered - it does not power off, because a machine that
# powers itself down needs someone to go and press the button, and these boards
# cannot be woken from S5. This is the one payload that is safe to
# point at a machine whose contents you care about - which is the whole point,
# because it is what you run BEFORE deciding which disk the installer may erase.
#
# WHY THIS EXISTS
# ---------------
# The Proxmox installer POSTs a description of itself to the answer server, but
# that description covers DMI and NICs only - there is nothing about disks in it
# (checked in the 9.2-1 proxmox-fetch-answer binary). So the server cannot tell
# you what is in a machine, and on a multi-disk box `--disk auto` is undefined
# while naming the device is unstable across reboots. Somebody has to look
# first. This is looking, without a monitor and without a keyboard.

set -uo pipefail

SURVEY_DIR="${PXE_SURVEY_DIR:-/srv/pxe/surveys}"
WAIT_MINS=20
KEEP_ARMED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --wait)       WAIT_MINS="${2:?--wait needs minutes}"; shift 2 ;;
        --keep-armed) KEEP_ARMED=1; shift ;;
        -h|--help)    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "survey-node.sh: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

disarm() {
    if [ "$KEEP_ARMED" -eq 1 ]; then
        echo "==> leaving PXE armed (--keep-armed)"
    else
        echo "==> disarming PXE"
        "$HOME/scripts/pxe-stop.sh" >/dev/null 2>&1 || true
    fi
}

# Everything already filed, so a report from a previous run is not mistaken for
# this one. Compared by name: the survey server names each file after the
# reporting machine's MAC, so a re-survey of the SAME machine overwrites rather
# than adding - which is why mtime is checked too.
snapshot_existing() {
    sudo -A -A find "$SURVEY_DIR" -name '*.txt' -printf '%f %T@\n' 2>/dev/null | sort
}

echo "==> arming the read-only survey payload"
sudo -A -A pxectl survey || exit 1

BEFORE="$(snapshot_existing)"

cat <<MSG

Power the target on now, set to boot from the network via its UEFI
'PXE IPv4' entry (one-time boot menu: F11/F12/Esc at POST).

Nothing else to do. It will:

    netboot SystemRescue into RAM   (~1-2 min, nothing written to disk)
    inventory every disk it can see
    POST the report back here
    REBOOT, back onto its normal boot device

Waiting up to $WAIT_MINS min...

MSG

DEADLINE=$((SECONDS + WAIT_MINS * 60))
NEW=""
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    AFTER="$(snapshot_existing)"
    if [ "$AFTER" != "$BEFORE" ]; then
        # The changed entry is the report we just caused.
        NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") \
               | awk '{print $1}' | tail -1)"
        [ -n "$NEW" ] && break
    fi
    # Polled tightly on purpose: the target reboots ~20s after it reports, and
    # PXE must be disarmed before it comes back around.
    sleep 2
done

if [ -z "$NEW" ]; then
    echo "Timed out: nothing reported." >&2
    echo >&2
    echo "  - Check the boot entry was 'PXE IPv4', NOT 'HTTP IPv4'. UEFI's native" >&2
    echo "    HTTP Boot is a different DHCP vendor class this server never answers," >&2
    echo "    so the firmware retries silently and nothing appears in any log." >&2
    echo "  - Watch the handshake live with:  sudo pxectl log" >&2
    echo "  - The target needs ~2 GB RAM for copytoram." >&2
    disarm
    exit 1
fi

MAC="${NEW%.txt}"
echo "==> report received from $MAC"
echo

sudo -A -A cat "$SURVEY_DIR/$NEW"

cat <<MSG

======================================================================
 NEXT
======================================================================

Pick the disk from the SUMMARY above - the one you are certain about -
and enrol the machine with its SERIAL, not its device name:

    ~/scripts/onboard-node.sh <name> --mac $MAC --disk-serial <SERIAL>

--mac is free here: this machine has already told us what it is, so the
installer's answer file is in place before it is even switched on.

THAT command erases the named disk with no confirmation. This one did not
write anything.

  re-read this report : sudo cat $SURVEY_DIR/$NEW
  survey another box  : ~/scripts/survey-node.sh
MSG

disarm
