#!/bin/bash
# Convenience wrapper - equivalent to: ~/scripts/pxe.sh proxmox
exec "$(dirname "$0")/pxe.sh" proxmox
