#!/bin/bash
# install.sh - deploy the on-demand PXE boot server onto a fresh Debian host.
#
#   sudo ./install.sh                  # auto-detect network settings
#   sudo ./install.sh --dry-run        # show what would change, touch nothing
#   sudo ./install.sh --config my.env  # override the detected settings
#
# Idempotent: safe to re-run to pick up template changes.
#
# This installs the *machinery* only. The payloads (a 2 GB Proxmox initrd, a
# 1.3 GB SystemRescue tree) are far too big to keep in git, so they are built
# afterwards by the scripts in payloads/. Nothing is enabled at boot.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
CONFIG=""

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1; shift ;;
        --config|-c)  CONFIG="${2:?--config needs a file}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *) echo "install.sh: unknown argument '$1'" >&2; usage 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "install.sh: must run as root (use sudo)" >&2
    exit 1
fi

# ---------------------------------------------------------------- config ----
# Order: explicit --config file > environment > auto-detected from the host.
[ -n "$CONFIG" ] && . "$CONFIG"
[ -z "$CONFIG" ] && [ -f "$HERE/pxe.env" ] && . "$HERE/pxe.env"

detect_iface() { ip -4 route show default 2>/dev/null | awk '{print $5; exit}'; }
detect_ip()    { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'; }
detect_cidr()  {
    # Turn 10.0.0.5/24 into 10.0.0.0/24 (assumes a /24 or wider octet boundary).
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4; exit}' | {
        IFS='/' read -r addr bits
        IFS='.' read -r a b c d <<<"$addr"
        case "$bits" in
            24) echo "$a.$b.$c.0/24" ;;
            16) echo "$a.$b.0.0/16" ;;
            8)  echo "$a.0.0.0/8" ;;
            *)  echo "$a.$b.$c.0/24" ;;   # good enough for a home LAN
        esac
    }
}

IFACE="${IFACE:-$(detect_iface)}"
SERVER_IP="${SERVER_IP:-$(detect_ip "$IFACE")}"
LAN_CIDR="${LAN_CIDR:-$(detect_cidr "$IFACE")}"
LAN_NET="${LAN_NET:-${LAN_CIDR%/*}}"
SERVER_NAME="${SERVER_NAME:-$(hostname -s 2>/dev/null || echo pxe)}"
PXE_USER="${PXE_USER:-${SUDO_USER:-$(id -un)}}"
PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
ANSWER_DIR="${ANSWER_DIR:-$PXE_ROOT/answers}"
# Disk inventories POSTed by tools/disk-survey.sh. Kept apart from ANSWER_DIR
# because the answer server may only ever WRITE here and only ever READ there.
SURVEY_DIR="${SURVEY_DIR:-$PXE_ROOT/surveys}"
ANSWER_PORT="${ANSWER_PORT:-8080}"

for v in IFACE SERVER_IP LAN_CIDR LAN_NET; do
    if [ -z "${!v}" ]; then
        echo "install.sh: could not determine $v - set it in pxe.env" >&2
        exit 1
    fi
done

PXE_HOME="$(getent passwd "$PXE_USER" | cut -d: -f6)"
if [ -z "$PXE_HOME" ]; then
    echo "install.sh: user '$PXE_USER' does not exist - set PXE_USER in pxe.env" >&2
    exit 1
fi

cat <<EOF
PXE server install
  interface   : $IFACE
  server IP   : $SERVER_IP
  LAN         : $LAN_CIDR  (network $LAN_NET)
  server name : $SERVER_NAME
  payload root: $PXE_ROOT
  answers     : $ANSWER_DIR  (served on :$ANSWER_PORT for fleet mode)
  surveys     : $SURVEY_DIR  (disk inventories POSTed by disk-survey.sh)
  wrappers to : $PXE_HOME/scripts   (user $PXE_USER)
  mode        : $([ "$DRY_RUN" -eq 1 ] && echo "DRY RUN - nothing will change" || echo "applying")

EOF

# ------------------------------------------------------------- utilities ----
step() { echo "==> $*"; }

RUN() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] $*"
    else
        "$@"
    fi
}

# render <template> <dest> <mode> [owner:group]
render() {
    local src="$1" dst="$2" mode="$3" own="${4:-root:root}" tmp
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] render $(basename "$src") -> $dst ($mode $own)"
        return
    fi
    tmp="$(mktemp)"
    sed -e "s|@@SERVER_IP@@|$SERVER_IP|g" \
        -e "s|@@LAN_CIDR@@|$LAN_CIDR|g" \
        -e "s|@@LAN_NET@@|$LAN_NET|g" \
        -e "s|@@IFACE@@|$IFACE|g" \
        -e "s|@@SERVER_NAME@@|$SERVER_NAME|g" \
        -e "s|@@PXE_HOME@@|$PXE_HOME|g" \
        -e "s|@@ANSWER_DIR@@|$ANSWER_DIR|g" \
        -e "s|@@SURVEY_DIR@@|$SURVEY_DIR|g" \
        -e "s|@@ANSWER_PORT@@|$ANSWER_PORT|g" \
        "$src" > "$tmp"
    if grep -q '@@[A-Z_]*@@' "$tmp"; then
        echo "install.sh: unsubstituted placeholder in $dst:" >&2
        grep -o '@@[A-Z_]*@@' "$tmp" | sort -u >&2
        rm -f "$tmp"
        exit 1
    fi
    install -o "${own%:*}" -g "${own#*:}" -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
    echo "    $dst"
}

# ------------------------------------------------------------- 1 packages ----
step "packages"
PKGS=(dnsmasq nginx ipxe zstd cpio wget ufw)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [ ${#MISSING[@]} -eq 0 ]; then
    echo "    all present: ${PKGS[*]}"
else
    echo "    installing: ${MISSING[*]}"
    RUN apt-get update -qq
    RUN env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
fi

# Both workers are driven by pxe@.service and must never come up on their own.
step "disable dnsmasq/nginx at boot (pxe@.service owns them)"
RUN systemctl disable --now dnsmasq.service    2>/dev/null || true
RUN systemctl disable --now nginx.service      2>/dev/null || true
RUN systemctl disable --now pxe-answer.service 2>/dev/null || true

# ---------------------------------------------------------- 2 directories ----
step "directories under $PXE_ROOT"
for d in tftp http iso; do
    RUN install -d -o "$PXE_USER" -g "$PXE_USER" -m 0755 "$PXE_ROOT/$d"
done
# Answer files hold a root password hash and are read by the answer server,
# which runs as www-data. Not world-readable.
RUN install -d -o "$PXE_USER" -g www-data -m 0750 "$ANSWER_DIR"
# Surveys are written by the answer server (www-data) and read by a human.
# They describe hardware, not credentials, so they are not secret.
RUN install -d -o www-data -g "$PXE_USER" -m 0775 "$SURVEY_DIR"
# nginx logs live on a tmpfs on DietPi; the drop-in recreates this at start,
# but create it now so a manual `nginx -t` before first start also works.
RUN install -d -o www-data -g adm -m 0755 /var/log/nginx

# ------------------------------------------------------- 3 iPXE binaries ----
step "iPXE boot binaries -> $PXE_ROOT/tftp"
# Debian's ipxe package is Architecture: all and ships the x86 builds, so an
# arm64 Pi serves x86 clients fine. boot.ipxe.org 404s on .efi these days.
if [ -f /usr/lib/ipxe/ipxe-amd64.efi ]; then
    RUN install -o "$PXE_USER" -g "$PXE_USER" -m 0644 /usr/lib/ipxe/ipxe-amd64.efi "$PXE_ROOT/tftp/ipxe.efi"
    RUN install -o "$PXE_USER" -g "$PXE_USER" -m 0644 /usr/lib/ipxe/undionly.kpxe   "$PXE_ROOT/tftp/undionly.kpxe"
    echo "    ipxe.efi + undionly.kpxe"
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] would copy from /usr/lib/ipxe (package not installed yet)"
else
    echo "install.sh: /usr/lib/ipxe/ipxe-amd64.efi missing after installing 'ipxe'" >&2
    exit 1
fi

# ---------------------------------------------------------- 4 config files --
step "configuration"
render "$HERE/templates/etc/dnsmasq.d/pxe.conf"        /etc/dnsmasq.d/pxe.conf 0644
render "$HERE/templates/etc/nginx/sites-available/pxe" /etc/nginx/sites-available/pxe 0644

# Every boot-*.ipxe under templates/ becomes an available payload. Adding an
# image means dropping a file in here - there is no list in this script, in
# pxectl, or in the unit to keep in sync.
step "payload boot scripts"
for b in "$HERE"/templates/srv/pxe/http/boot-*.ipxe; do
    [ -e "$b" ] || continue
    render "$b" "$PXE_ROOT/http/$(basename "$b")" 0644 "$PXE_USER:$PXE_USER"
done

# Small helper scripts the TARGET machine fetches over HTTP while it is
# netbooted - disk-survey.sh from a SystemRescue shell, most of all. They are
# rendered like everything else so @@SERVER_IP@@ in their usage text is real.
step "tools -> $PXE_ROOT/http/tools"
RUN install -d -o "$PXE_USER" -g "$PXE_USER" -m 0755 "$PXE_ROOT/http/tools"
for t in "$HERE"/tools/*; do
    [ -e "$t" ] || continue
    render "$t" "$PXE_ROOT/http/tools/$(basename "$t")" 0644 "$PXE_USER:$PXE_USER"
done

step "nginx site"
RUN ln -sfn /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
# The pxe site is `listen 80 default_server`; Debian's stock site claims that too.
if [ -e /etc/nginx/sites-enabled/default ]; then
    step "removing stock nginx default site (conflicts with default_server)"
    RUN rm -f /etc/nginx/sites-enabled/default
fi

# ------------------------------------------------------------ 5 systemd -----
step "systemd units"
render "$HERE/templates/etc/systemd/system/pxe@.service" /etc/systemd/system/pxe@.service 0644
RUN install -d -m 0755 /etc/systemd/system/nginx.service.d
render "$HERE/templates/etc/systemd/system/nginx.service.d/logdir.conf"  /etc/systemd/system/nginx.service.d/logdir.conf 0644
# Earlier layouts tore the workers down with PartOf= drop-ins. PartOf= can only
# name concrete instances, which cannot express a payload set discovered at
# runtime, so `pxectl _down` does it from ExecStop instead. Clear the stale
# files so an upgraded host does not keep the old behaviour.
RUN rm -f /etc/systemd/system/dnsmasq.service.d/pxe.conf \
          /etc/systemd/system/nginx.service.d/pxe.conf

step "pxectl"
render "$HERE/templates/usr/local/sbin/pxectl" /usr/local/sbin/pxectl 0755

step "answer server (fleet mode)"
render "$HERE/templates/usr/local/sbin/pxe-answer-server" /usr/local/sbin/pxe-answer-server 0755
render "$HERE/templates/etc/systemd/system/pxe-answer.service" /etc/systemd/system/pxe-answer.service 0644

step "credential-store guard"
# secrets/<node>/ is the ONLY copy of every node's root password and SSH key:
# new-node.py generates them once from a CSPRNG and nothing can regenerate
# them. Snapshots therefore live OUTSIDE this repo, under /var/backups, where
# neither uninstall.sh (which removes $PXE_ROOT) nor a re-clone can take them
# with it. Owned by $PXE_USER so new-node.py can snapshot without sudo; the
# hourly root timer is what makes the copies immutable.
RUN install -d -o "$PXE_USER" -g "$PXE_USER" -m 0700 /var/backups/pxe-secrets
render "$HERE/templates/etc/systemd/system/pxe-secrets-guard.service" /etc/systemd/system/pxe-secrets-guard.service 0644
render "$HERE/templates/etc/systemd/system/pxe-secrets-guard.timer"   /etc/systemd/system/pxe-secrets-guard.timer 0644

step "wrapper scripts -> $PXE_HOME/scripts"
RUN install -d -o "$PXE_USER" -g "$PXE_USER" -m 0755 "$PXE_HOME/scripts"
for s in "$HERE"/scripts/*.sh; do
    [ -e "$s" ] || continue
    RUN install -o "$PXE_USER" -g "$PXE_USER" -m 0755 "$s" "$PXE_HOME/scripts/$(basename "$s")"
done

RUN systemctl daemon-reload

step "arm the credential-store timer (hourly verify + snapshot)"
RUN systemctl enable --now pxe-secrets-guard.timer
if [ "$DRY_RUN" -eq 0 ] && [ -d "$PXE_HOME/pxe-server/new_machine_onboarding/secrets" ]; then
    ONBOARD_DIR="$PXE_HOME/pxe-server/new_machine_onboarding" \
    ANSWER_DIR="$ANSWER_DIR" BACKUP_ROOT=/var/backups/pxe-secrets \
        "$PXE_HOME/scripts/secrets-guard.sh" backup --reason "install.sh" || \
        echo "    (initial snapshot failed - run secrets-guard.sh backup by hand)"
fi

# ------------------------------------------------------------- 6 firewall ---
step "firewall"
if ufw status 2>/dev/null | head -1 | grep -q inactive; then
    echo "    ufw is INACTIVE - PXE rules are stored but nothing is enforced."
    echo "    That is fine. If you enable ufw later, allow SSH FIRST:"
    echo "        sudo ufw allow 22/tcp && sudo ufw enable"
else
    echo "    ufw active - pxe@.service opens/closes its rules on start/stop."
fi

# --------------------------------------------------------------- summary ----
cat <<EOF

Done.$([ "$DRY_RUN" -eq 1 ] && echo "  (dry run - nothing was changed)")

Next: install a payload. These download multi-GB ISOs, so they are separate.

    sudo $HERE/payloads/build-proxmox.sh          # ~1.7 GB ISO -> 2.0 GB initrd
    sudo $HERE/payloads/build-pdm.sh              # Datacenter Manager (admin node)
    sudo $HERE/payloads/build-rescue.sh           # ~1.4 GB ISO -> 1.3 GB tree
    sudo $HERE/payloads/prepare-iso.sh NAME ISO   # any other image: file or URL,
                                                  # detects the family and writes
                                                  # the boot script for you

Then:

    sudo pxectl list                  # what is installed
    $PXE_HOME/scripts/pxe.sh proxmox  # or any name from that list
    sudo pxectl status
EOF
