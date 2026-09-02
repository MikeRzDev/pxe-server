#!/bin/bash
# End-to-end fleet onboarding: arm PXE, discover the new machine's MAC from
# its first (harmless) netboot attempt, then generate + serve its answer file.
#
#     ~/scripts/onboard-node.sh <name> [extra new-node.py flags...]
#     ~/scripts/onboard-node.sh pve05 --disk nvme0n1
#
# The target must already be set to boot from network - see the prompt below
# for exactly which entry. It must be a UEFI **"...PXE IPv4..."** boot entry,
# not "...HTTP IPv4...": this server only answers classic PXE (DHCP vendor
# class PXEClient). UEFI's own native HTTP Boot (vendor class HTTPClient) gets
# no reply at the DHCP layer at all and just retries forever with no TFTP/HTTP
# traffic ever reaching this host - if that happens, reboot and pick the other
# network entry from the one-time boot menu (F11/F12/Esc at POST).
#
# Safe by construction up to the confirmation prompt: until an answer file
# exists for its MAC, any netboot attempt 404s at the answer server and
# touches nothing on the target. After you confirm and the file is written,
# the NEXT netboot of that MAC WIPES THE TARGET DISK and installs unattended.
set -euo pipefail

ONBOARD_DIR="$HOME/pxe-server/new_machine_onboarding"
WAIT_SECS=900

if [ $# -eq 0 ]; then
    echo "usage: $(basename "$0") <name> [extra new-node.py flags...]" >&2
    echo "  e.g. $(basename "$0") pve05 --disk nvme0n1" >&2
    exit 1
fi
NAME="$1"; shift

echo "==> arming PXE (proxmox-fleet)"
sudo -A -A pxectl proxmox-fleet
echo
echo "Boot '$NAME' now via its UEFI 'PXE IPv4' network boot entry (one-time"
echo "boot menu, not 'HTTP IPv4'). Waiting up to $((WAIT_SECS / 60)) min for its first attempt..."
echo

SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
DEADLINE=$((SECONDS + WAIT_SECS))
MAC=""
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    LINE="$(sudo -A -A journalctl -u pxe-answer --no-pager -S "$SINCE" 2>/dev/null | grep "NO ANSWER" | tail -1)"
    if [ -n "$LINE" ]; then
        MAC="$(sed -n 's/.*macs=\([^)]*\).*/\1/p' <<<"$LINE" | cut -d, -f1)"
        [ -n "$MAC" ] && break
    fi
    sleep 5
done

if [ -z "$MAC" ]; then
    echo "Timed out waiting for a netboot attempt. Re-run when '$NAME' is ready to boot." >&2
    exit 1
fi

echo "==> captured MAC: $MAC"
echo
cd "$ONBOARD_DIR"
sudo ./new-node.py "$NAME" --mac "$MAC" "$@" --dry-run
echo
read -rp "Write + serve this answer file? [y/N] " CONFIRM
case "$CONFIRM" in
    y | Y) ;;
    *)
        echo "Aborted - nothing written."
        exit 1
        ;;
esac

sudo ./new-node.py "$NAME" --mac "$MAC" "$@" --serve

cat <<MSG

Done. Boot '$NAME' via PXE IPv4 again - it will now match and WIPE its disk
installing Proxmox unattended.

  watch it     : sudo pxectl log
  credentials  : sudo cat $ONBOARD_DIR/secrets/$NAME/credentials.env
  fleet status : ~/scripts/fleet-status.sh
  turn PXE off : ~/scripts/pxe-stop.sh
MSG
