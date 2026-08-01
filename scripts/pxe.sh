#!/bin/bash
# Start the PXE server, serving the image given as the first argument.
#
#     ~/scripts/pxe.sh <payload>
#     ~/scripts/pxe.sh              # show what is installed
#
# Any /srv/pxe/http/boot-<name>.ipxe is a valid payload - the set is discovered
# at runtime, so this script has no list of images baked into it.
# Payloads are mutually exclusive: starting one stops the other.
set -u

if [ $# -eq 0 ]; then
    echo "usage: $(basename "$0") <payload>"
    echo
    sudo -A -A pxectl list
    echo
    echo "To add an image, drop a boot-<name>.ipxe into /srv/pxe/http/"
    exit 1
fi

PAYLOAD="$1"
sudo -A -A pxectl "$PAYLOAD" || exit 1
echo
sudo -A -A pxectl status
cat <<MSG

  watch handshake : sudo pxectl log
  switch image    : ~/scripts/pxe.sh <payload>
  list images     : sudo pxectl list
  turn off        : ~/scripts/pxe-stop.sh
MSG
