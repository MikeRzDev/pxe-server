#!/bin/bash
# pick-disk.sh - choose which disk to install to, from a menu, and release the
# machine into the installer.
#
#     ~/scripts/pick-disk.sh oppenheimer
#     ~/scripts/pick-disk.sh oppenheimer --mac 047c1649aa63   # several reported
#     ~/scripts/pick-disk.sh oppenheimer --no-chain           # do not release
#
# Reads the survey report a held machine already filed, prints its disks as a
# numbered menu with how full each one is, and - once you have picked and
# confirmed - enrols the node against that disk's SERIAL and drops the release
# file. The machine is sitting in the survey shell polling for exactly that, so
# it sets BootNext and reboots straight into the installer.
#
#   survey (done)  ->  THIS: pick from a menu  ->  next reboot installs
#
# WHY A MENU
# ----------
# The survey deliberately refuses to choose on a multi-disk machine: silently
# picking one of seven is the mistake the whole survey path exists to prevent.
# But "read the table, then retype a 20-character serial into another command"
# invites a different mistake - a mistyped or stale serial naming the wrong
# disk. The serial never gets retyped here: it is carried straight from the row
# you picked into the answer file.
#
# THE DISK YOU CHOOSE IS ERASED, with no further prompt after the confirmation
# below. Nothing before that point writes anything to the target.

set -uo pipefail

SURVEY_DIR="${PXE_SURVEY_DIR:-/srv/pxe/surveys}"
CHAIN=1
MAC=""
NAME=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --mac)      MAC="$(printf '%s' "${2:?--mac needs an address}" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f')"; shift 2 ;;
        --no-chain) CHAIN=0; shift ;;
        -h|--help)  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         EXTRA+=("$1"); shift ;;
        *)          if [ -z "$NAME" ]; then NAME="$1"; else EXTRA+=("$1"); fi; shift ;;
    esac
done

if [ -z "$NAME" ]; then
    echo "usage: pick-disk.sh <node-name> [--mac <MAC>] [--no-chain]" >&2
    exit 1
fi

# An irreversible choice made by pressing a number needs a person on the other
# end of it. Refusing here rather than reading EOF as "1" is the whole point.
if [ ! -t 0 ]; then
    echo "pick-disk.sh: this is interactive - run it from a terminal on the Pi" >&2
    echo "  ssh arduino" >&2
    echo "  ~/scripts/pick-disk.sh $NAME" >&2
    exit 1
fi

# ------------------------------------------------------------- the report ----
if [ -n "$MAC" ]; then
    REPORT="$SURVEY_DIR/$MAC.txt"
    sudo -A -A test -f "$REPORT" || { echo "pick-disk.sh: no survey report for $MAC" >&2; exit 1; }
else
    mapfile -t FOUND < <(sudo -A -A find "$SURVEY_DIR" -name '*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if [ "${#FOUND[@]}" -eq 0 ]; then
        echo "pick-disk.sh: no survey reports in $SURVEY_DIR" >&2
        echo "  Survey the machine first:  ~/scripts/onboard-node.sh $NAME --shadow" >&2
        exit 1
    fi
    REPORT="${FOUND[0]}"
    if [ "${#FOUND[@]}" -gt 1 ]; then
        echo "Several machines have reported. Using the most recent:"
        printf '  %s\n' "$(basename "$REPORT" .txt)"
        echo "  (name another with --mac)"
        echo
    fi
fi

MAC="$(basename "$REPORT" .txt)"

# Rows are tab separated, and read positionally, so an empty column would shift
# every column after it. The survey writes "-" rather than nothing for exactly
# that reason; awk -F'\t' then keeps empty fields distinct, which a bare `read`
# with IFS=tab would not.
ROWS="$(sudo -A -A sed -n '/^### SURVEY-DATA v[0-9][0-9]*$/,/^### END SURVEY-DATA$/p' "$REPORT" \
        | awk -F'\t' '$1=="DISK"')"

COUNT="$(printf '%s\n' "$ROWS" | grep -c . || true)"
if [ "${COUNT:-0}" -eq 0 ]; then
    echo "pick-disk.sh: that report lists no disks." >&2
    exit 1
fi

# Is the machine still holding? It gives up after 90 min and reboots to its
# normal boot device, and releasing a machine that is no longer listening just
# leaves a file nobody collects.
AGE_MIN="$(sudo -A -A find "$REPORT" -mmin +90 -printf 'old\n' 2>/dev/null)"
HOLDING=1
[ "$AGE_MIN" = "old" ] && HOLDING=0

# ---------------------------------------------------------------- the menu ----
echo
echo "======================================================================"
echo " $NAME  -  disks reported by $MAC"
echo "======================================================================"
echo
printf '  %-3s %-12s %-9s %-9s %-9s %-20s %s\n' '#' DEVICE SIZE USED FREE MODEL VERDICT
printf '  %-3s %-12s %-9s %-9s %-9s %-20s %s\n' --- ------ ---- ---- ---- ----- -------

i=0
declare -a SERIALS DEVS SIZES VCODES USEDS
while IFS= read -r row; do
    [ -n "$row" ] || continue
    i=$((i + 1))
    _f() { printf '%s' "$row" | awk -F'\t' -v n="$1" '{v=$n; if(v=="-")v=""; print v}'; }
    DEVS[$i]="$(_f 2)";  SERIALS[$i]="$(_f 3)"
    SIZES[$i]="$(_f 5)"; VCODES[$i]="$(_f 7)"
    used_b="$(_f 8)"; free_b="$(_f 9)"
    used_h="-"; free_h="-"
    case "$used_b" in ''|*[!0-9]*) ;; *) used_h="$(numfmt --to=iec --suffix=B --format='%.1f' "$used_b")" ;; esac
    case "$free_b" in ''|*[!0-9]*) ;; *) free_h="$(numfmt --to=iec --suffix=B --format='%.1f' "$free_b")" ;; esac
    USEDS[$i]="$used_h"

    case "${VCODES[$i]}" in
        inuse)   note="IN USE - the system booted from this" ;;
        windows) note="WINDOWS/BOOT - keep" ;;
        empty)   note="empty - safe" ;;
        *)       note="has data - will be lost" ;;
    esac
    printf '  %-3s %-12s %-9s %-9s %-9s %-20s %s\n' \
        "$i)" "${DEVS[$i]}" "${SIZES[$i]}" "$used_h" "$free_h" \
        "$(printf '%s' "$(_f 6)" | cut -c1-20)" "$note"
done < <(printf '%s\n' "$ROWS")

echo
echo "  USED is read from each filesystem's own metadata - nothing was mounted."
echo "  Full report:  sudo cat $REPORT"
if [ "$HOLDING" -eq 0 ]; then
    echo
    echo "  NOTE: that report is over 90 min old, so the machine has stopped"
    echo "        holding and will need one power-on after this."
fi
echo

# ------------------------------------------------------------- the choice ----
printf 'Which disk should be ERASED and installed to?  [1-%s, q to quit] ' "$i"
read -r choice
case "$choice" in
    q|Q|'') echo "Nothing chosen. Nothing written."; exit 0 ;;
esac
case "$choice" in
    ''|*[!0-9]*) echo "Not a number. Nothing written." >&2; exit 1 ;;
esac
if [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
    echo "There is no disk $choice. Nothing written." >&2
    exit 1
fi

DEV="${DEVS[$choice]}"; SERIAL="${SERIALS[$choice]}"
SIZE="${SIZES[$choice]}"; VCODE="${VCODES[$choice]}"

if [ -z "$SERIAL" ]; then
    echo >&2
    echo "$DEV reports no serial, so it cannot be selected in a way that survives" >&2
    echo "a reboot - kernel names move with probe order. Pick another disk, or" >&2
    echo "enrol by udev property with --disk-filter." >&2
    exit 1
fi

echo
echo "======================================================================"
echo " ABOUT TO ERASE"
echo "======================================================================"
echo
echo "   node    : $NAME"
echo "   disk    : $DEV   $SIZE"
echo "   serial  : $SERIAL"
echo "   used    : ${USEDS[$choice]}"
echo "   verdict : $VCODE"
echo
case "$VCODE" in
    windows|inuse)
        echo "   !! The survey flagged this disk as carrying Windows, an EFI System"
        echo "      Partition, or the running system. Installing here destroys it."
        echo ;;
esac
echo "Everything on it goes. The serial above is what goes into the answer"
echo "file, so it selects this same physical disk whatever the kernel calls"
echo "it on the boot that installs."
echo
printf 'Type the node name (%s) to confirm, anything else to abort: ' "$NAME"
read -r confirm
if [ "$confirm" != "$NAME" ]; then
    echo "Aborted. Nothing was written and no credentials were minted."
    exit 0
fi

# ------------------------------------------------------------- hand off ----
# The serial is passed through, never retyped. --chain drops the release file
# the held machine is already polling for, so it sets BootNext and reboots into
# the installer without anyone going near it.
ARGS=("$NAME" --mac "$MAC" --disk-serial "$SERIAL")
[ "$CHAIN" -eq 1 ] && [ "$HOLDING" -eq 1 ] && ARGS+=(--chain)
[ "${#EXTRA[@]}" -gt 0 ] && ARGS+=("${EXTRA[@]}")

echo
echo "==> ~/scripts/onboard-node.sh ${ARGS[*]}"
echo
exec "$HOME/scripts/onboard-node.sh" "${ARGS[@]}"
