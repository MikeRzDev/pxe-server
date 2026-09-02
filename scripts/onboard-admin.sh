#!/bin/bash
# Onboard the admin node (Proxmox Datacenter Manager) over network boot.
#
#     ~/scripts/onboard-admin.sh <name> --mac <MAC> [new-node.py flags...]
#     ~/scripts/onboard-admin.sh <name> --any-mac    [new-node.py flags...]
#     ~/scripts/onboard-admin.sh <name> --two-pass   [new-node.py flags...]
#
#     ~/scripts/onboard-admin.sh kay --mac 84:47:09:70:9c:11 --ip 192.168.1.236
#     ~/scripts/onboard-admin.sh kay --any-mac --ip 192.168.1.236
#
# PDM is the management product for the PVE fleet. It is a whole-disk install
# like PVE, so it gets its own machine; there is normally exactly one.
#
# ---------------------------------------------------------------------------
# THE POINT OF THE FIRST TWO MODES: ONE POWER-ON, NOTHING ELSE.
#
# The answer file is in place BEFORE the target ever boots, so its very first
# netboot matches, installs unattended and reboots into PDM. No second reboot,
# no operator at the keyboard.
#
#   --mac <MAC>   You know the NIC's MAC (BIOS/UEFI network-boot screen, a
#                 sticker on the case, or your router's DHCP leases). The
#                 answer file is scoped to that one machine. USE THIS.
#
#   --any-mac     You do not know the MAC. Falls back to `default.toml`, which
#                 matches ANY machine. As soon as the target collects it, this
#                 script learns the MAC from the answer server's log, renames
#                 the file to <mac>.toml and deletes the default - so the
#                 wildcard lives for seconds, not indefinitely. Still: while it
#                 is armed, ANYTHING on this LAN that netboots gets wiped.
#
#   --two-pass    The older, most conservative flow: arm with no answer file,
#                 let the target's first netboot 404 (harmless - the installer
#                 aborts and touches nothing), capture its MAC from that, then
#                 serve. Costs a SECOND MANUAL REBOOT of the target. Use it
#                 when you cannot get the MAC and will not accept a wildcard.
# ---------------------------------------------------------------------------
#
# The target must be set to boot from network via a UEFI **"...PXE IPv4..."**
# entry, not "...HTTP IPv4...": this server only answers classic PXE (DHCP
# vendor class PXEClient). UEFI's own native HTTP Boot (vendor class
# HTTPClient) gets no reply at the DHCP layer at all and just retries forever
# with no TFTP/HTTP traffic ever reaching this host - if that happens, reboot
# and pick the other network entry from the one-time boot menu (F11/F12/Esc).
#
# Whichever mode you use, THE TARGET'S DISK IS ERASED WITHOUT CONFIRMATION.
# And while pdm-fleet is armed it is the ONLY payload served, so a PVE node
# that netboots meanwhile would get the PDM installer. This script disarms PXE
# itself once the install has been handed its answer.
set -euo pipefail

ONBOARD_DIR="$HOME/pxe-server/new_machine_onboarding"
ANSWERS_DIR="${PXE_ANSWER_DIR:-/srv/pxe/answers}"
WAIT_SECS=900
PAYLOAD=pdm-fleet

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

[ $# -eq 0 ] && usage
NAME="$1"; shift

MODE="" MAC=""
PASSTHRU=()
while [ $# -gt 0 ]; do
    case "$1" in
        --mac)      MAC="${2:?--mac needs an address}"; MODE=mac;  shift 2 ;;
        --any-mac)  MODE=any;      shift ;;
        --two-pass) MODE=twopass;  shift ;;
        -h|--help)  usage ;;
        *)          PASSTHRU+=("$1"); shift ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "onboard-admin.sh: pick how the target is identified:" >&2
    echo "  --mac <MAC>   first boot installs, scoped to that machine  (preferred)" >&2
    echo "  --any-mac     first boot installs, wildcard answer file, narrowed on use" >&2
    echo "  --two-pass    no wildcard, but needs a SECOND manual reboot" >&2
    exit 1
fi

# bash 3.2-safe expansion of a possibly-empty array under `set -u`.
passthru() { [ "${#PASSTHRU[@]}" -gt 0 ] && printf '%s\n' "${PASSTHRU[@]}" || true; }

norm_mac() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f'; }

# Watch the answer server's journal from $1 for a line naming an answer file,
# and echo the first MAC on it. $2 is the grep pattern that identifies the
# interesting line. Returns non-zero on timeout.
wait_for_log() {
    local since="$1" pattern="$2" deadline=$((SECONDS + WAIT_SECS)) line mac
    while [ "$SECONDS" -lt "$deadline" ]; do
        line="$(sudo -A -A journalctl -u pxe-answer --no-pager -S "$since" 2>/dev/null \
                | grep -- "$pattern" | tail -1)"
        if [ -n "$line" ]; then
            mac="$(sed -n 's/.*macs=\[\{0,1\}\([^],)]*\).*/\1/p' <<<"$line" | cut -d, -f1)"
            [ -n "$mac" ] && { printf '%s' "$mac"; return 0; }
        fi
        sleep 5
    done
    return 1
}

trailer() {
    cat <<MSG

  watch it     : sudo pxectl log
  credentials  : sudo cat $ONBOARD_DIR/secrets/$NAME/credentials.env
  fleet status : ~/scripts/fleet-status.sh
  PXE is off   : nothing is being served any more

The web UI comes up on https://<address>:8443 (PVE nodes are on 8006).
Then, on the Mac:  cd ~/Documents/DevOps/Manhattan && ./sync-from-pi.sh
MSG
}

# ------------------------------------------------------- two-pass (legacy) --
if [ "$MODE" = twopass ]; then
    echo "==> arming PXE ($PAYLOAD - Proxmox Datacenter Manager)"
    sudo -A -A pxectl "$PAYLOAD"
    echo
    echo "Boot '$NAME' now via its UEFI 'PXE IPv4' entry. Its first attempt will"
    echo "404 and change nothing; that is how its MAC is discovered."
    echo "Waiting up to $((WAIT_SECS / 60)) min..."
    echo
    SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
    MAC="$(wait_for_log "$SINCE" "NO ANSWER")" || {
        echo "Timed out waiting for a netboot attempt. Re-run when '$NAME' is ready." >&2
        exit 1
    }
    echo "==> captured MAC: $MAC"
    echo
    cd "$ONBOARD_DIR"
    sudo ./new-node.py "$NAME" --mac "$MAC" --product pdm $(passthru) --serve
    cat <<MSG

Now reboot '$NAME' via PXE IPv4 AGAIN - this time it matches and WIPES its
disk, installing Proxmox Datacenter Manager unattended.
MSG
    trailer
    exit 0
fi

# ------------------------------------------------- one-shot: answer first ---
cd "$ONBOARD_DIR"
if [ "$MODE" = mac ]; then
    echo "==> writing the answer file for $NAME, scoped to $MAC"
    sudo ./new-node.py "$NAME" --mac "$MAC" --product pdm $(passthru) --serve
else
    cat <<'WARN'
==> WILDCARD MODE

    No MAC given, so the answer file is served as default.toml, which MATCHES
    ANY MACHINE. From the moment PXE is armed until the target collects it,
    anything on this LAN that network-boots will be WIPED and reinstalled.

    Power on ONLY the admin node during this window.

WARN
    sudo ./new-node.py "$NAME" --product pdm $(passthru) --serve
fi

echo
echo "==> arming PXE ($PAYLOAD - Proxmox Datacenter Manager)"
sudo -A -A pxectl "$PAYLOAD"

SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
cat <<MSG

Power on '$NAME' now, set to boot from network via its UEFI 'PXE IPv4' entry.

Nothing else is needed: it fetches its answer file on this FIRST boot, wipes
its disk, installs unattended and reboots into Proxmox Datacenter Manager.

Waiting up to $((WAIT_SECS / 60)) min to confirm it collected the answer...
MSG
echo

if MATCHED="$(wait_for_log "$SINCE" '\-> .*\.toml')"; then
    echo "==> '$NAME' collected its answer file (MAC $MATCHED) - installing now."

    # Narrow the wildcard the moment it has been used, so it cannot catch a
    # second machine. The installer already holds its copy; renaming underneath
    # it is safe.
    if [ "$MODE" = any ]; then
        NORM="$(norm_mac "$MATCHED")"
        if [ -n "$NORM" ] && sudo -A -A test -f "$ANSWERS_DIR/default.toml"; then
            sudo -A -A mv "$ANSWERS_DIR/default.toml" "$ANSWERS_DIR/$NORM.toml"
            echo "==> narrowed default.toml -> $NORM.toml (the wildcard is gone)"
        fi
    fi
else
    echo "Timed out: '$NAME' never fetched an answer file." >&2
    echo "Nothing was installed. Check the boot entry is 'PXE IPv4', not 'HTTP IPv4'." >&2
    if [ "$MODE" = any ]; then
        sudo -A -A rm -f "$ANSWERS_DIR/default.toml" || true
        echo "Removed the wildcard default.toml." >&2
    fi
    echo "==> disarming PXE"
    ~/scripts/pxe-stop.sh >/dev/null 2>&1 || true
    exit 1
fi

# The answer is delivered and the install is running off its own ramdisk - it
# does not need the PXE server any more, so stop serving a disk-wiping image
# to the LAN rather than leaving it armed for the length of an install.
echo "==> disarming PXE (the install no longer needs it)"
~/scripts/pxe-stop.sh >/dev/null 2>&1 || true

trailer
