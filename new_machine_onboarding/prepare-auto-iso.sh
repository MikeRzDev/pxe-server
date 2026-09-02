#!/bin/bash
# prepare-auto-iso.sh - bake an answer file into a Proxmox installer ISO so the
# installer runs UNATTENDED.
#
# Product-agnostic: any ISO carrying an `auto-installer-capable` marker in its
# root works, so this takes a Proxmox Datacenter Manager ISO exactly as it
# takes a Proxmox VE one. Only the payload builder differs afterwards
# (build-proxmox.sh vs build-pdm.sh).
#
#   ./prepare-auto-iso.sh nodes/pve01.answer.toml proxmox-ve_9.2-1.iso [out.iso]
#   ./prepare-auto-iso.sh --validate answer.toml       # syntax-check only
#   ./prepare-auto-iso.sh --http http://SERVER:8080/answer proxmox-ve_9.2-1.iso
#
# The --http form bakes NO answer file. The installer POSTs a description of
# itself - including every NIC's MAC - to that URL and the answer server replies
# with the answer for that machine. One image then serves the whole fleet, and
# enrolling a machine is a small text file instead of a per-machine 2 GB
# rebuild. Build it once; use the first form only for a one-off machine.
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
HTTP_URL=""

case "${1:-}" in
    --validate) VALIDATE_ONLY=1; shift ;;
    --http)     HTTP_URL="${2:?--http needs a URL}"; shift 2 ;;
esac

if [ -n "$HTTP_URL" ]; then
    ANSWER=""
    SRC_ISO="${1:-}"
    OUT_ISO="${2:-}"
else
    ANSWER="${1:-}"
    SRC_ISO="${2:-}"
    OUT_ISO="${3:-}"
fi

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

if [ -z "$HTTP_URL" ]; then
    [ -n "$ANSWER" ] || usage
    [ -f "$ANSWER" ] || { echo "prepare-auto-iso.sh: no such answer file: $ANSWER" >&2; exit 1; }
fi
if [ "$VALIDATE_ONLY" -eq 0 ]; then
    [ -n "$SRC_ISO" ] || usage
    [ -f "$SRC_ISO" ] || { echo "prepare-auto-iso.sh: no such ISO: $SRC_ISO" >&2; exit 1; }
    if [ -n "$HTTP_URL" ]; then
        OUT_ISO="${OUT_ISO:-${SRC_ISO%.iso}-fleet.iso}"
    else
        OUT_ISO="${OUT_ISO:-${SRC_ISO%.iso}-auto.iso}"
    fi
fi

# Which builder and payload the trailers below should point at. PVE and PDM
# ISOs go through this script identically; only the next step differs, and
# printing the PVE one after preparing a PDM ISO is how you end up with a
# hypervisor payload sitting under a manager's name.
case "$(basename "${SRC_ISO:-}")" in
    *datacenter-manager*)
        BUILDER=build-pdm.sh;     FLEET_PAYLOAD=pdm-fleet;     AUTO_PAYLOAD=pdm ;;
    *)
        BUILDER=build-proxmox.sh; FLEET_PAYLOAD=proxmox-fleet; AUTO_PAYLOAD=proxmox-auto ;;
esac
# For both products the payload directory name matches the pxectl payload name,
# except PVE's baked variant, which is historically "pve-auto" not "proxmox-auto".
FLEET_DIR="$FLEET_PAYLOAD"
[ "$FLEET_PAYLOAD" = "proxmox-fleet" ] && FLEET_DIR=pve-fleet
AUTO_DIR="$AUTO_PAYLOAD"
[ "$AUTO_PAYLOAD" = "proxmox-auto" ] && AUTO_DIR=pve-auto

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
ANSWER_DIR="$([ -n "$ANSWER" ] && cd "$(dirname "$ANSWER")" && pwd || echo "")"
ANSWER_FILE="$([ -n "$ANSWER" ] && basename "$ANSWER" || echo "")"

if [ -n "$HTTP_URL" ]; then
    echo "==> fleet mode: no answer file is baked in; it will be fetched from"
    echo "    $HTTP_URL"
else
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
fi

# ---------------------------------------------------------------- prepare ---
ISO_DIR="$(cd "$(dirname "$SRC_ISO")" && pwd)"
ISO_FILE="$(basename "$SRC_ISO")"
OUT_FILE="$(basename "$OUT_ISO")"

if [ -n "$HTTP_URL" ]; then
    echo "==> preparing a fleet ISO (answers fetched at install time)"
    run "$ISO_DIR" proxmox-auto-install-assistant prepare-iso \
        "/work/$ISO_FILE" --fetch-from http --url "$HTTP_URL" \
        --output "/work/$OUT_FILE"
    echo
    echo "Done: $ISO_DIR/$OUT_FILE"
    ls -lh "$ISO_DIR/$OUT_FILE" | awk '{print "  " $5, $9}'
    cat <<EOF

Build the payload ONCE, then enrol machines by writing answer files:

  scp $ISO_DIR/$OUT_FILE <user>@<pxe>:/srv/pxe/iso/
  sudo -A ~/pxe-server/payloads/$BUILDER --iso /srv/pxe/iso/$OUT_FILE --name $FLEET_DIR
  sudo -A pxectl $FLEET_PAYLOAD

  ./new_machine_onboarding/new-node.py <name> --serve   # per machine, no rebuild
EOF
    exit 0
fi

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
  sudo ~/pxe-server/payloads/$BUILDER --iso /srv/pxe/iso/$OUT_FILE --name $AUTO_DIR
  sudo pxectl $AUTO_PAYLOAD      # <-- this WILL wipe the target's disk
EOF
