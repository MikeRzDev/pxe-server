#!/bin/bash
# End-to-end fleet onboarding for a Proxmox VE node.
#
#     ~/scripts/onboard-node.sh <name> [new-node.py flags...]
#     ~/scripts/onboard-node.sh pve06
#     ~/scripts/onboard-node.sh pve06 --disk nvme0n1
#
# A single power-on installs the machine unattended, and you do NOT need to
# know its MAC in advance. A netbooting machine announces itself to dnsmasq
# about 90 seconds before the installer asks for its answer file, so this
# catches the MAC from that DHCP request and writes the answer into the same
# boot. Nothing to look up, no wildcard, no second reboot.
#
# Pass --mac if you happen to know it (removes the race entirely), or
# --two-pass for the old 404-discovery flow. See onboard-lib.sh for all four
# modes, --keep-armed, and the measurements behind the timing.
#
# The target must boot via a UEFI **"...PXE IPv4..."** entry, not
# "...HTTP IPv4...": this server only answers classic PXE (DHCP vendor class
# PXEClient). UEFI's own native HTTP Boot (vendor class HTTPClient) gets no
# reply at the DHCP layer at all and just retries forever with no TFTP/HTTP
# traffic ever reaching this host - if that happens, reboot and pick the other
# network entry from the one-time boot menu (F11/F12/Esc at POST).
#
# Once the answer file exists, THE TARGET'S DISK IS ERASED WITH NO PROMPT.
set -euo pipefail

. "$(dirname "$0")/onboard-lib.sh"

onboard_main proxmox-fleet pve 8006 "$@"
