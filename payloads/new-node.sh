#!/bin/bash
# new-node.sh - generate the answer file for one new Proxmox node.
#
#   ./new-node.sh pve01                      # auto-pick the next free IP
#   ./new-node.sh pve01 --ip 192.0.2.35
#   ./new-node.sh pve01 --disk nvme0n1       # pin the disk (default: auto)
#   ./new-node.sh pve01 --fs zfs --disk sda,sdb
#
# Produces, for <name>:
#   secrets/<name>.env        the ROOT PASSWORD in clear + its hash   (0600)
#   nodes/<name>.answer.toml  the answer file to bake into an ISO
#
# Both directories are gitignored.
#
# THE PASSWORD IS WRITTEN TO DISK BEFORE ANYTHING ELSE HAPPENS. A 32-character
# random password that only exists inside a hash is a password you have lost,
# and the node it installs would be unreachable. Nothing later in this script
# can run until that file is safely on disk.
#
# ############################################################################
# # The ISO built from this answer file WIPES THE TARGET DISK, no prompt.    #
# ############################################################################
#
# Settings come from nodes.env (gitignored) - copy nodes.env.example. Anything
# not set there must be passed as a flag.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SECRETS="$REPO/secrets"
NODES="$REPO/nodes"

NAME=""; IP=""; DISKS=""; FS=""

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ip)   IP="${2:?--ip needs an address}"; shift 2 ;;
        --disk) DISKS="${2:?--disk needs a disk or comma list}"; shift 2 ;;
        --fs)   FS="${2:?--fs needs ext4|xfs|zfs|btrfs}"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "new-node.sh: unknown option '$1'" >&2; usage ;;
        *)  NAME="$1"; shift ;;
    esac
done

[ -n "$NAME" ] || usage
case "$NAME" in
    *[!a-zA-Z0-9-]*|-*|*-) echo "new-node.sh: '$NAME' is not a valid hostname" >&2; exit 1 ;;
esac

# ------------------------------------------------------------------ config --
[ -f "$REPO/nodes.env" ] && . "$REPO/nodes.env"
NODE_DOMAIN="${NODE_DOMAIN:-lan}"
NODE_GATEWAY="${NODE_GATEWAY:-}"
NODE_DNS="${NODE_DNS:-}"
NODE_TIMEZONE="${NODE_TIMEZONE:-UTC}"
NODE_COUNTRY="${NODE_COUNTRY:-us}"
NODE_KEYBOARD="${NODE_KEYBOARD:-en-us}"
NODE_MAILTO="${NODE_MAILTO:-root@${NODE_DOMAIN}}"
NODE_CIDR_BITS="${NODE_CIDR_BITS:-24}"
DISKS="${DISKS:-${NODE_DISKS:-auto}}"
FS="${FS:-${NODE_FS:-ext4}}"

need() { [ -n "${!1}" ] || { echo "new-node.sh: $1 is not set - put it in nodes.env or pass the flag" >&2; exit 1; }; }
need NODE_GATEWAY
need NODE_DNS

# ------------------------------------------------------------- pick an IP ---
case "$(uname -s)" in
    Darwin) PING="ping -c 1 -t 1" ;;
    *)      PING="ping -c 1 -W 1" ;;
esac

ip_in_use() {  # in use if it answers, or if another node already claimed it
    $PING "$1" >/dev/null 2>&1 && return 0
    grep -rqs "^NODE_IP=$1\$" "$SECRETS" 2>/dev/null && return 0
    return 1
}

if [ -z "$IP" ]; then
    need NODE_IP_START
    need NODE_IP_END
    base="${NODE_IP_START%.*}"
    first="${NODE_IP_START##*.}"
    last="${NODE_IP_END##*.}"
    echo "==> looking for a free address in ${NODE_IP_START}-${last}"
    for n in $(seq "$first" "$last"); do
        cand="$base.$n"
        if ip_in_use "$cand"; then
            echo "    $cand in use, skipping"
        else
            IP="$cand"; break
        fi
    done
    [ -n "$IP" ] || { echo "new-node.sh: no free address in the configured range" >&2; exit 1; }
    echo "    picked $IP"
else
    if ip_in_use "$IP"; then
        echo "new-node.sh: $IP already answers or is claimed by another node" >&2
        exit 1
    fi
fi

FQDN="$NAME.$NODE_DOMAIN"
SECRET_FILE="$SECRETS/$NAME.env"
ANSWER_FILE="$NODES/$NAME.answer.toml"

if [ -e "$SECRET_FILE" ]; then
    echo "new-node.sh: $SECRET_FILE already exists - refusing to overwrite a" >&2
    echo "             stored password. Delete it first if you really mean to." >&2
    exit 1
fi

# ------------------------------------------------- password: SAVE FIRST -----
# 32 chars from an alphabet with no quotes, backslash or $ - those would need
# escaping in TOML and in shell, and a password you cannot paste is a bug.
#
# Read a BOUNDED chunk of /dev/urandom rather than piping the endless stream
# into `head -c 32`: head exits at 32 bytes, tr dies of SIGPIPE, and under
# `set -o pipefail` that fails the whole script with 141. 1 KiB filtered down
# to this alphabet leaves ~270 usable characters, far more than the 32 needed.
_rand="$(LC_ALL=C head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._+=@%#-')"
PASSWORD="${_rand:0:32}"
unset _rand
[ "${#PASSWORD}" -eq 32 ] || { echo "new-node.sh: could not generate a password" >&2; exit 1; }

if ! HASH="$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin 2>/dev/null)" || [ -z "$HASH" ]; then
    echo "new-node.sh: 'openssl passwd -6' failed. macOS LibreSSL does not support it;" >&2
    echo "             install OpenSSL (brew install openssl) or run this on Linux." >&2
    exit 1
fi

umask 077
mkdir -p "$SECRETS" "$NODES"
chmod 700 "$SECRETS"

# Written before the answer file, before any ISO is built, before anything is
# served. If the script dies after this point the password is still recoverable.
cat > "$SECRET_FILE" <<EOF
# Proxmox node credentials - KEEP. Generated by new-node.sh.
# This file is gitignored and mode 0600. There is no other copy.
NODE_NAME=$NAME
NODE_FQDN=$FQDN
NODE_IP=$IP
NODE_URL=https://$IP:8006
NODE_USER=root@pam
NODE_PASSWORD=$PASSWORD
NODE_PASSWORD_HASH=$HASH
EOF
chmod 600 "$SECRET_FILE"
echo "==> password saved to $SECRET_FILE (0600)"

# ------------------------------------------------------------ answer file ---
# Emit the [disk-setup] disk selection.
#
# ext4 and xfs accept exactly ONE disk - `disk-list = ["sda","nvme0n1"]` is
# rejected outright ("make sure to define only one disk for ext4 and xfs"), so
# you cannot list both names and let the missing one be ignored.
#
# A UDEV filter sidesteps that: it is resolved on the target, so the validator
# accepts it and the machine decides. `filter.DEVNAME = "*"` therefore installs
# to whatever the single disk is called, sda or nvme0n1, with no prior scan.
#
# The catch: on a machine with MORE THAN ONE disk "*" matches all of them, and
# which one an ext4 install then picks is not documented. Pin those explicitly
# with --disk.
disk_selection() {
    local d
    if [ "$DISKS" = "auto" ]; then
        echo 'filter.DEVNAME = "*"'
        return
    fi
    IFS=',' read -ra arr <<<"$DISKS"
    case "$FS" in
        ext4|xfs)
            if [ "${#arr[@]}" -ne 1 ]; then
                echo "new-node.sh: filesystem '$FS' takes exactly one disk, got: $DISKS" >&2
                echo "             use --fs zfs for several, or name a single disk." >&2
                exit 1
            fi
            echo "disk-list  = [\"${arr[0]}\"]"
            ;;
        *)
            local out=""
            for d in "${arr[@]}"; do out="$out\"$d\", "; done
            echo "disk-list  = [${out%, }]"
            ;;
    esac
}

{
    echo "# Proxmox VE answer file for $FQDN - generated by new-node.sh."
    echo "# THIS WIPES THE TARGET DISK. Credentials: secrets/$NAME.env"
    echo
    echo "[global]"
    echo "keyboard = \"$NODE_KEYBOARD\""
    echo "country  = \"$NODE_COUNTRY\""
    echo "timezone = \"$NODE_TIMEZONE\""
    echo "fqdn     = \"$FQDN\""
    echo "mailto   = \"$NODE_MAILTO\""
    echo "root-password-hashed = \"$HASH\""
    [ -n "${NODE_SSH_KEY:-}" ] && echo "root-ssh-keys = [\"$NODE_SSH_KEY\"]"
    echo
    echo "[network]"
    echo "source  = \"from-answer\""
    echo "cidr    = \"$IP/$NODE_CIDR_BITS\""
    echo "gateway = \"$NODE_GATEWAY\""
    echo "dns     = \"$NODE_DNS\""
    echo "filter.ID_NET_NAME_MAC = \"*\""
    echo
    echo "[disk-setup]"
    echo "filesystem = \"$FS\""
    if [ "$DISKS" = "auto" ]; then
        echo "# Resolved on the target: installs to whatever the single disk is"
        echo "# called (sda, nvme0n1, ...). On a MULTI-disk machine this is"
        echo "# ambiguous - pin it with --disk instead."
    fi
    echo "$(disk_selection)"
} > "$ANSWER_FILE"
chmod 600 "$ANSWER_FILE"
echo "==> answer file written to $ANSWER_FILE"

# ------------------------------------------------------------- validate -----
echo "==> validating"
if ! "$HERE/prepare-auto-iso.sh" --validate "$ANSWER_FILE"; then
    echo "new-node.sh: validation FAILED - the answer file above is not usable." >&2
    echo "             The password is still saved in $SECRET_FILE." >&2
    exit 1
fi

cat <<EOF

--------------------------------------------------------------------
  node      : $FQDN
  address   : $IP  ->  https://$IP:8006
  disks     : $DISKS   (filesystem $FS)
  password  : saved in secrets/$NAME.env  (not printed here)
--------------------------------------------------------------------

Next - bake it into an ISO and serve it:

  ./payloads/prepare-auto-iso.sh $ANSWER_FILE /path/to/proxmox-ve_9.2-1.iso
  scp <that>-auto.iso <user>@<pxe>:/srv/pxe/iso/
  ssh <user>@<pxe> 'sudo ~/pxe-server/payloads/build-proxmox.sh \\
        --iso /srv/pxe/iso/<that>-auto.iso --name pve-auto && sudo pxectl proxmox-auto'

Then netboot the target. IT WILL ERASE ITS DISK WITHOUT ASKING.
Stop serving it afterwards:  ~/scripts/pxe-stop.sh
EOF
