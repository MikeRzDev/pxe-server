#!/bin/bash
# End-to-end onboarding for the admin node - Proxmox Datacenter Manager.
#
#     ~/scripts/onboard-admin.sh <name> [new-node.py flags...]
#     ~/scripts/onboard-admin.sh kay --ip 192.168.1.236
#
# PDM is the management product for the PVE fleet: it drives the nodes from one
# pane. It is a WHOLE-DISK install like PVE, so it needs its own machine rather
# than a slot on an existing node, and there is normally exactly one of them.
#
# Identical in every other way to onboard-node.sh - same modes, same one
# power-on with no MAC known in advance, same answer schema, same MAC-keyed
# answer server, which is shared between the products without conflict. Only
# three things differ: the payload armed (pdm-fleet, not proxmox-fleet), the
# --product passed to new-node.py, and the web UI port (8443, not 8006).
#
# The target must boot via a UEFI **"...PXE IPv4..."** entry, not
# "...HTTP IPv4..." - see onboard-lib.sh for why, for all four modes, and for
# --keep-armed.
#
# Once the answer file exists, THE TARGET'S DISK IS ERASED WITH NO PROMPT.
set -euo pipefail

. "$(dirname "$0")/onboard-lib.sh"

onboard_main pdm-fleet pdm 8443 "$@"
