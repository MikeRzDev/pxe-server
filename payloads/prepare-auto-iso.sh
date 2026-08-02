#!/bin/bash
# prepare-auto-iso.sh - bake an answer file into a Proxmox VE ISO so the
# installer runs UNATTENDED.
#
#   ./prepare-auto-iso.sh answer.toml proxmox-ve_9.2-1.iso [out.iso]
#   ./prepare-auto-iso.sh --validate answer.toml       # syntax-check only
#
# ############################################################################
# # THE RESULTING IMAGE WIPES THE TARGET DISK WITH NO PROMPT AND NO          #
# # CONFIRMATION. Anything that netboots it loses its data. Serve it only    #
# # deliberately, as its own payload, and never as the default.              #
# ############################################################################
#
# WHY THIS SCRIPT EXISTS
#
# The work is done by `proxmox-auto-install-assistant`, which Proxmox ships
# for **amd64 only** - there is no arm64 index in their repo at all. So on an
# arm64 box (a Raspberry Pi PXE server, an Apple Silicon Mac) it cannot be
# installed, and this wraps it in an amd64 container instead. Emulated, but
# this is a one-off that takes a couple of minutes.
#
# Run this on any machine with Docker; it does NOT have to be the PXE server.
# Then copy the output to the PXE server and build the payload there:
#
#   scp proxmox-ve_9.2-1-auto.iso user@pxe:/srv/pxe/iso/
#   ssh user@pxe
#   sudo ~/pxe-server/payloads/build-proxmox.sh \
#        --iso /srv/pxe/iso/proxmox-ve_9.2-1-auto.iso --name pve-auto
#   sudo pxectl proxmox-auto
#
# The answer file is baked into the ISO (`--fetch-from iso`), which is the mode
# the PXE + auto-install combination is known to work with. The alternative,
# `--fetch-from http`, has the installer POST for its answer at install time -
# note POST, so a plain static-file nginx returns 405 and you need
# `error_page 405 =200 $uri;` in the location block.
#
# SECRETS: the answer file contains the root password, and it ends up inside
# the ISO *and* inside the 2 GB initrd that the PXE server hands out over plain
# HTTP to anyone on the LAN. Use `root-password-hashed` rather than
# `root-password` so a LAN sniffer gets a hash instead of the password.

set -euo pipefail

IMAGE="pve-autoinstall:9.2"
PVE_SUITE="trixie"
VALIDATE_ONLY=0

if [ "${1:-}" = "--validate" ]; then VALIDATE_ONLY=1; shift; fi

ANSWER="${1:-}"
SRC_ISO="${2:-}"
OUT_ISO="${3:-}"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

[ -n "$ANSWER" ] || usage
[ -f "$ANSWER" ] || { echo "prepare-auto-iso.sh: no such answer file: $ANSWER" >&2; exit 1; }
if [ "$VALIDATE_ONLY" -eq 0 ]; then
    [ -n "$SRC_ISO" ] || usage
    [ -f "$SRC_ISO" ] || { echo "prepare-auto-iso.sh: no such ISO: $SRC_ISO" >&2; exit 1; }
    OUT_ISO="${OUT_ISO:-${SRC_ISO%.iso}-auto.iso}"
fi

command -v docker >/dev/null || {
    echo "prepare-auto-iso.sh: docker is required (the assistant is amd64-only)." >&2
    echo "  Alternatively run proxmox-auto-install-assistant directly on any amd64 Debian host." >&2
    exit 1
}
docker info >/dev/null 2>&1 || {
    echo "prepare-auto-iso.sh: the docker daemon is not running." >&2
    exit 1
}

# ------------------------------------------------------------------ image ---
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> building the amd64 helper image (one-off)"
    docker build --platform linux/amd64 -q -t "$IMAGE" - >/dev/null <<EOF
FROM debian:${PVE_SUITE}
RUN apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null \\
 && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-${PVE_SUITE}.gpg \\
      -o /etc/apt/trusted.gpg.d/proxmox-release-${PVE_SUITE}.gpg \\
 && echo "deb http://download.proxmox.com/debian/pve ${PVE_SUITE} pve-no-subscription" \\
      > /etc/apt/sources.list.d/pve.list \\
 && apt-get update -qq \\
 && apt-get install -y -qq proxmox-auto-install-assistant xorriso >/dev/null \\
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
EOF
fi

run() { docker run --rm --platform linux/amd64 -v "$1:/work" "$IMAGE" "${@:2}"; }

# --------------------------------------------------------------- validate ---
ANSWER_DIR="$(cd "$(dirname "$ANSWER")" && pwd)"
ANSWER_FILE="$(basename "$ANSWER")"

echo "==> validating $ANSWER"
# `validate-answer` ALWAYS EXITS 0 - even when it prints
# "Error: Found issues in the answer file." (verified against
# proxmox-installer-common 9.2.7). Its exit status is therefore useless, and
# the output has to be matched instead. Trusting $? here silently accepts a
# broken answer file and you only find out when the target fails to install.
_out="$(run "$ANSWER_DIR" proxmox-auto-install-assistant validate-answer "/work/$ANSWER_FILE" 2>&1)" || true
printf '%s\n' "$_out"
if ! printf '%s' "$_out" | grep -q 'parsed successfully'; then
    echo "prepare-auto-iso.sh: the answer file is NOT valid - fix it before building." >&2
    exit 1
fi

if [ "$VALIDATE_ONLY" -eq 1 ]; then
    echo
    echo "Valid. Re-run without --validate and pass an ISO to bake it in."
    exit 0
fi

# ---------------------------------------------------------------- prepare ---
ISO_DIR="$(cd "$(dirname "$SRC_ISO")" && pwd)"
ISO_FILE="$(basename "$SRC_ISO")"
OUT_FILE="$(basename "$OUT_ISO")"

if [ "$ISO_DIR" != "$ANSWER_DIR" ]; then
    cp "$ANSWER" "$ISO_DIR/.answer.tmp.toml"
    trap 'rm -f "$ISO_DIR/.answer.tmp.toml"' EXIT
    ANSWER_IN_ISO_DIR=".answer.tmp.toml"
else
    ANSWER_IN_ISO_DIR="$ANSWER_FILE"
fi

echo "==> baking the answer file into the ISO (this takes a few minutes, emulated)"
run "$ISO_DIR" proxmox-auto-install-assistant prepare-iso \
    "/work/$ISO_FILE" \
    --fetch-from iso \
    --answer-file "/work/$ANSWER_IN_ISO_DIR" \
    --output "/work/$OUT_FILE"

echo
echo "Done: $ISO_DIR/$OUT_FILE"
ls -lh "$ISO_DIR/$OUT_FILE" | awk '{print "  " $5, $9}'
cat <<EOF

Next, on the PXE server:

  scp $ISO_DIR/$OUT_FILE <user>@<pxe-server>:/srv/pxe/iso/
  sudo ~/pxe-server/payloads/build-proxmox.sh --iso /srv/pxe/iso/$OUT_FILE --name pve-auto
  sudo pxectl proxmox-auto      # <-- this WILL wipe the target's disk
EOF
