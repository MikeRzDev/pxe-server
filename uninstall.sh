#!/bin/bash
# uninstall.sh - remove the PXE boot server machinery from a host.
#
#   sudo ./uninstall.sh                    # remove machinery, KEEP payloads
#   sudo ./uninstall.sh --purge-payloads   # also delete /srv/pxe (multi-GB)
#   sudo ./uninstall.sh --yes              # skip the confirmation prompt
#
# Packages (dnsmasq, nginx, ipxe) are left installed - removing them is more
# likely to break something else on the host than to help.

set -euo pipefail

PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
PURGE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --purge-payloads) PURGE=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)        sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "uninstall.sh: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: must run as root (use sudo)" >&2; exit 1; }

echo "This will remove:"
echo "    /etc/systemd/system/pxe@.service and the dnsmasq/nginx drop-ins"
echo "    /etc/dnsmasq.d/pxe.conf, /etc/nginx/sites-{available,enabled}/pxe"
echo "    /usr/local/sbin/pxectl and the ~/scripts/pxe*.sh wrappers"
echo "    the PXE ufw rules"
if [ "$PURGE" -eq 1 ]; then
    echo "    $PXE_ROOT  <-- INCLUDING ALL PAYLOADS AND ISOs"
else
    echo "  keeping $PXE_ROOT (pass --purge-payloads to delete it too)"
fi
echo

if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in [yY]*) ;; *) echo "aborted"; exit 0 ;; esac
fi

echo "==> stopping and closing the firewall"
if [ -x /usr/local/sbin/pxectl ]; then
    /usr/local/sbin/pxectl off >/dev/null 2>&1 || true
else
    systemctl stop 'pxe@*.service' dnsmasq.service nginx.service 2>/dev/null || true
fi

echo "==> removing units and config"
rm -f /etc/systemd/system/pxe@.service \
      /etc/systemd/system/dnsmasq.service.d/pxe.conf \
      /etc/systemd/system/nginx.service.d/pxe.conf \
      /etc/systemd/system/nginx.service.d/logdir.conf \
      /etc/dnsmasq.d/pxe.conf \
      /etc/nginx/sites-enabled/pxe \
      /etc/nginx/sites-available/pxe \
      /usr/local/sbin/pxectl
rmdir --ignore-fail-on-non-empty /etc/systemd/system/dnsmasq.service.d \
                                 /etc/systemd/system/nginx.service.d 2>/dev/null || true

echo "==> removing wrapper scripts"
while IFS=: read -r _ _ _ _ _ home _; do
    [ -d "$home/scripts" ] || continue
    rm -f "$home/scripts"/pxe.sh "$home/scripts"/pxe-proxmox.sh \
          "$home/scripts"/pxe-rescue.sh "$home/scripts"/pxe-stop.sh
done < /etc/passwd

if [ "$PURGE" -eq 1 ]; then
    echo "==> deleting $PXE_ROOT"
    rm -rf "$PXE_ROOT"
fi

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo
echo "Done. Packages (dnsmasq, nginx, ipxe) were left installed."
echo "The stock nginx default site was removed at install time; if you want it"
echo "back:  ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/"
