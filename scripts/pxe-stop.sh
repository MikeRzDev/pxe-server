#!/bin/bash
# Stop the PXE server (whichever image is being served) and close the firewall.
set -u
echo "Stopping PXE server..."
sudo -A -A pxectl off
echo
sudo -A -A pxectl status
