#!/bin/bash
# End-to-end fleet onboarding for a Proxmox VE node.
#
#     ~/scripts/onboard-node.sh <name> --mac <MAC> [new-node.py flags...]
#     ~/scripts/onboard-node.sh <name> --any-mac   [new-node.py flags...]
#     ~/scripts/onboard-node.sh <name>             [new-node.py flags...]
#
#     ~/scripts/onboard-node.sh pve06 --mac 84:47:09:70:9c:11
#     ~/scripts/onboard-node.sh pve06 --disk nvme0n1
#
# Give it --mac and a single power-on installs the machine unattended: the
# answer file is in place before it ever boots. With no --mac it falls back to
# two-pass discovery - the target's first netboot 404s harmlessly, its MAC is
# read out of that, and it then needs a SECOND MANUAL REBOOT to install. That
# is the historical behaviour and still the default, because it is the only
# mode that is safe knowing nothing about the machine in advance.
#
# The target must boot via a UEFI **"...PXE IPv4..."** entry, not
# "...HTTP IPv4...": this server only answers classic PXE (DHCP vendor class
# PXEClient). UEFI's own native HTTP Boot (vendor class HTTPClient) gets no
# reply at the DHCP layer at all and just retries forever with no TFTP/HTTP
# traffic ever reaching this host - if that happens, reboot and pick the other
# network entry from the one-time boot menu (F11/F12/Esc at POST).
#
# Once the answer file exists, THE TARGET'S DISK IS ERASED WITH NO PROMPT.
# See onboard-lib.sh for the modes, the wildcard narrowing and --keep-armed.
set -euo pipefail

. "$(dirname "$0")/onboard-lib.sh"

onboard_main proxmox-fleet pve 8006 "$@"
