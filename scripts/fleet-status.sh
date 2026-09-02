#!/bin/bash
# Fleet status: every enrolled node's name/IP/MAC from its fleet-mode answer
# file, cross-checked against what's actually alive and answering on the LAN.
#
#     ~/scripts/fleet-status.sh              # print table, refresh FLEET.md
#     ~/scripts/fleet-status.sh --no-write   # print only, don't touch FLEET.md
#
# "Enrolled" = one /srv/pxe/answers/<mac>.toml per node (default.toml, which
# matches ANY machine, is not a node and is skipped). This tells you whether a
# node is enrolled and whether whatever answers at its IP right now has the
# expected MAC - it does NOT tell you whether that node's Proxmox install
# actually completed.
set -u

ANSWERS_DIR=/srv/pxe/answers
OUT_MD="$HOME/pxe-server/new_machine_onboarding/FLEET.md"
IFACE=eth0
WRITE=1
[ "${1:-}" = "--no-write" ] && WRITE=0

rows=()
for f in "$ANSWERS_DIR"/*.toml; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .toml)"
    [ "$base" = "default" ] && continue

    fqdn="$(sudo -A -A grep -m1 '^fqdn' "$f" | sed -E 's/.*"(.*)".*/\1/')"
    cidr="$(sudo -A -A grep -m1 '^cidr' "$f" | sed -E 's/.*"(.*)".*/\1/')"
    ip="${cidr%%/*}"
    name="${fqdn%%.*}"
    mac_norm="$(echo "$base" | tr 'A-Z' 'a-z')"

    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        alive="yes"
    else
        alive="no"
    fi

    seen_mac="$(ip -4 neigh show "$ip" dev "$IFACE" 2>/dev/null \
        | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 \
        | tr -d ':' | tr 'A-Z' 'a-z')"

    if [ -z "$seen_mac" ]; then
        mac_status="unknown (no ARP entry)"
    elif [ "$seen_mac" = "$mac_norm" ]; then
        mac_status="match"
    else
        mac_status="**MISMATCH** (seen $seen_mac)"
    fi

    rows+=("| $name | $fqdn | $ip | $mac_norm | $alive | $mac_status |")
done

TABLE="$(
    echo "# Fleet status"
    echo
    echo "Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') by fleet-status.sh."
    echo
    echo "| Name | FQDN | IP | Enrolled MAC | Alive | MAC on wire |"
    echo "|---|---|---|---|---|---|"
    for r in "${rows[@]}"; do echo "$r"; done
)"

echo "$TABLE"

if [ "$WRITE" -eq 1 ]; then
    echo "$TABLE" >"$OUT_MD"
    echo
    echo "written to $OUT_MD" >&2
fi
