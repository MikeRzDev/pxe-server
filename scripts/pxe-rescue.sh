#!/bin/bash
# Convenience wrapper - equivalent to: ~/scripts/pxe.sh rescue
exec "$(dirname "$0")/pxe.sh" rescue
