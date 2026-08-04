#!/bin/bash
# prepare-iso.sh - point it at an ISO, get a bootable payload.
#
#   sudo ./prepare-iso.sh <name> <iso-path-or-url> [options]
#
# Takes a local file OR a URL, works out which installer family the image
# belongs to, copies exactly the files that family needs into the HTTP root,
# and WRITES A WORKING boot-<name>.ipxe. When it finishes the payload is in
# `pxectl list` and bootable - there is nothing left to edit.
#
#   sudo ./prepare-iso.sh rocky10 https://.../Rocky-10-x86_64-dvd.iso
#   sudo ./prepare-iso.sh arch    /home/me/archlinux-x86_64.iso --start
#   sudo ./prepare-iso.sh ubuntu  https://.../ubuntu-24.04-live-server-amd64.iso
#
# Options:
#   --start            run `pxectl <name>` once it is prepared
#   --dry-run, -n      mount, detect, print the boot script; copy nothing
#   --force, -f        overwrite an existing payload of this name
#   --family <f>       skip detection (see FAMILIES below)
#   --desc "<text>"    menu title / `pxectl list` description
#   --whole            copy the entire image tree regardless of family
#   --server-ip <ip>   override the address baked into the boot script
#   --emit-template    also write templates/srv/pxe/http/boot-<name>.ipxe with
#                      @@SERVER_IP@@ placeholders, so install.sh recreates it
#   --discard-iso      delete a downloaded ISO once the payload is built
#
# FAMILIES it knows, and the cmdline each one needs:
#
#   archiso     Arch, SystemRescue, EndeavourOS  - pulls its own squashfs over
#               HTTP with archiso_http_srv=
#   anaconda    Fedora, RHEL, Rocky, Alma        - needs inst.repo=
#   casper      Ubuntu live / live-server        - fetches the ISO itself with
#               url=, so the ISO is served whole rather than unpacked
#   alpine      Alpine standard/extended         - alpine_repo= + modloop=
#   live        Debian live (live-boot)          - boot=live fetch=<squashfs>
#   debian-netboot   a d-i netboot.tar.gz        - the reliable Debian path
#   debian-installer a Debian/Ubuntu netinst ISO - see the WARNING it prints
#   proxmox     refused on purpose: the ISO has to be embedded in the initrd,
#               which is build-proxmox.sh's job, not a cmdline this can write
#
# Anything else is still unpacked and still gets a boot-<name>.ipxe, but with
# the kernel cmdline left blank and every kernel/initrd found listed in the
# file as comments. It exits 3 to say "prepared, but you must finish it".
# Guessing a cmdline is how you get a boot that fails in confusing ways, so
# this does not guess - same reasoning as fetch-iso.sh, which it supersedes
# for everything except deliberately hand-written payloads.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

NAME=""; SRC=""; FAMILY=""; DESC=""; SERVER_IP_OVERRIDE=""
START=0; DRY_RUN=0; FORCE=0; WHOLE=0; EMIT_TEMPLATE=0; KEEP_ISO=1

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit "${1:-1}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --start)         START=1; shift ;;
        --dry-run|-n)    DRY_RUN=1; shift ;;
        --force|-f)      FORCE=1; shift ;;
        --whole)         WHOLE=1; shift ;;
        --emit-template) EMIT_TEMPLATE=1; shift ;;
        --discard-iso)   KEEP_ISO=0; shift ;;
        --keep-iso)      KEEP_ISO=1; shift ;;
        --family)        FAMILY="${2:?--family needs a value}"; shift 2 ;;
        --desc)          DESC="${2:?--desc needs a value}"; shift 2 ;;
        --server-ip)     SERVER_IP_OVERRIDE="${2:?--server-ip needs a value}"; shift 2 ;;
        -h|--help)       usage 0 ;;
        -*)              echo "prepare-iso.sh: unknown option '$1'" >&2; usage 1 ;;
        *)  if   [ -z "$NAME" ]; then NAME="$1"
            elif [ -z "$SRC" ];  then SRC="$1"
            else echo "prepare-iso.sh: unexpected argument '$1'" >&2; usage 1
            fi
            shift ;;
    esac
done

[ -n "$NAME" ] && [ -n "$SRC" ] || usage 1

case "$NAME" in
    *[!a-zA-Z0-9_-]*) echo "prepare-iso.sh: '$NAME' - use only letters, digits, - and _" >&2; exit 1 ;;
    EXAMPLE)          echo "prepare-iso.sh: 'EXAMPLE' is reserved" >&2; exit 1 ;;
esac

# Root is required even for --dry-run: detection reads the image, and reading
# an ISO means a loop mount.
[ "$(id -u)" -eq 0 ] || { echo "prepare-iso.sh: must run as root (use sudo)" >&2; exit 1; }

# ---------------------------------------------------------------- config ----
# Same precedence as install.sh: pxe.env if the repo has one, else detect from
# the default route. The address is baked into the boot script, so it must be
# the one clients will actually reach.
[ -f "$REPO/pxe.env" ] && . "$REPO/pxe.env"

PXE_ROOT="${PXE_ROOT:-/srv/pxe}"
WWW="$PXE_ROOT/http"
IFACE="${IFACE:-$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')}"
SERVER_IP="${SERVER_IP_OVERRIDE:-${SERVER_IP:-$(ip -4 -o addr show dev "${IFACE:-lo}" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')}}"
SERVER_NAME="${SERVER_NAME:-$(hostname -s 2>/dev/null || echo pxe)}"
PXE_USER="${PXE_USER:-${SUDO_USER:-$(id -un)}}"

[ -n "$SERVER_IP" ] || { echo "prepare-iso.sh: could not determine the server address - pass --server-ip" >&2; exit 1; }

DEST="$WWW/$NAME"
BOOT_SCRIPT="$WWW/boot-$NAME.ipxe"
WORK="$PXE_ROOT/work-$NAME"
MNT="$WORK/mnt"

if [ -e "$BOOT_SCRIPT" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "prepare-iso.sh: $BOOT_SCRIPT already exists - pass --force to replace it" >&2
    exit 1
fi

MOUNTED=0
cleanup() {
    [ "$MOUNTED" -eq 1 ] && mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

install -d "$PXE_ROOT/iso" "$MNT"

# ----------------------------------------------------------------- fetch ----
# Half the point of this script: fetch-iso.sh only ever accepted a URL, so an
# ISO you already had on disk could not be used without renaming it into place.
IS_TARBALL=0
DOWNLOADED=0
case "$SRC" in
    http://*|https://*|ftp://*)
        case "$SRC" in *.tar.gz|*.tgz) IS_TARBALL=1 ;; esac
        if [ "$IS_TARBALL" -eq 1 ]
            then ISO_PATH="$PXE_ROOT/iso/${NAME}-netboot.tar.gz"
            else ISO_PATH="$PXE_ROOT/iso/${NAME}.iso"
        fi
        DOWNLOADED=1
        if [ -f "$ISO_PATH" ]; then
            echo "==> already downloaded: $ISO_PATH"
        else
            echo "==> downloading $SRC"
            wget -c -O "$ISO_PATH" "$SRC"
        fi
        ;;
    *)
        [ -f "$SRC" ] || { echo "prepare-iso.sh: no such file '$SRC'" >&2; exit 1; }
        ISO_PATH="$(readlink -f "$SRC")"
        case "$ISO_PATH" in *.tar.gz|*.tgz) IS_TARBALL=1 ;; esac
        echo "==> using local image: $ISO_PATH"
        ;;
esac

if [ -n "${SRC_SHA256:-}" ]; then
    echo "==> verifying sha256"
    echo "$SRC_SHA256  $ISO_PATH" | sha256sum -c -
fi

if [ "$IS_TARBALL" -eq 1 ]; then
    echo "==> unpacking netboot tarball"
    tar -xzf "$ISO_PATH" -C "$MNT"
else
    echo "==> mounting"
    mount -o loop,ro "$ISO_PATH" "$MNT"
    MOUNTED=1
fi

# ---------------------------------------------------------------- detect ----
have()      { [ -e "$MNT/$1" ]; }
# Echo the first path matching a glob, relative to $MNT. Non-zero if none.
firstglob() { local g; for g in "$MNT"/$1; do [ -e "$g" ] && { echo "${g#"$MNT"/}"; return 0; }; done; return 1; }

ARCHISO_DIR=""
find_archiso_dir() {
    local d
    for d in "$MNT"/*/; do
        [ -d "$d" ] || continue
        if [ -f "$d/x86_64/airootfs.sfs" ] && compgen -G "$d/boot/x86_64/vmlinuz*" >/dev/null; then
            ARCHISO_DIR="$(basename "$d")"
            return 0
        fi
    done
    return 1
}

# Sets FAMILY, and ARCHISO_DIR when the answer is archiso. It assigns rather
# than echoing on purpose: `FAMILY=$(detect_family)` would run this in a
# subshell, and ARCHISO_DIR would be lost with it.
detect_family() {
    # Proxmox first: /boot/linux26 is its signature, and it is the one image
    # here that no cmdline can rescue - the ISO must live inside the initrd.
    if have boot/linux26; then FAMILY=proxmox; return; fi

    if [ "$IS_TARBALL" -eq 1 ]; then
        if firstglob 'debian-installer/*/linux'   >/dev/null 2>&1 ||
           firstglob '*/debian-installer/*/linux' >/dev/null 2>&1
        then FAMILY=debian-netboot; return; fi
    fi

    # archiso keeps everything under one top-level directory whose name IS the
    # archisobasedir: 'arch' upstream, 'sysresccd' on SystemRescue.
    if find_archiso_dir;        then FAMILY=archiso;          return; fi
    if have .treeinfo;          then FAMILY=anaconda;         return; fi
    if have images/pxeboot;     then FAMILY=anaconda;         return; fi
    if have casper;             then FAMILY=casper;           return; fi
    if have apks;               then FAMILY=alpine;           return; fi
    if have live;               then FAMILY=live;             return; fi
    if have install.amd;        then FAMILY=debian-installer; return; fi

    FAMILY=unknown
}

if [ -z "$FAMILY" ]; then
    detect_family
    echo "==> detected family: $FAMILY"
else
    [ "$FAMILY" = archiso ] && { find_archiso_dir || true; }
    echo "==> family forced to: $FAMILY"
fi

if [ "$FAMILY" = proxmox ]; then
    cat >&2 <<EOF

prepare-iso.sh: this is a Proxmox VE ISO, which this script deliberately does
not handle.

Proxmox's installer init looks for /proxmox.iso INSIDE the initrd; there is no
kernel parameter that makes it fetch the ISO from a URL. Building that payload
is initrd surgery, not a cmdline:

    sudo $HERE/build-proxmox.sh --iso $ISO_PATH --name $NAME

EOF
    exit 1
fi

# ------------------------------------------------- per-family boot recipe ---
# Each family sets COPY (how much of the image to take), KERNEL, INITRDS and
# KOPTS. \${base-url} is an iPXE variable and must reach the file unexpanded.
COPY=whole      # whole | subtree | subtree_keep | files | bootdirs
SUBTREE=""; FILES=(); KERNEL=""; INITRDS=(); KOPTS=""; NOTE=""; SERVE_ISO=0

case "$FAMILY" in
archiso)
    # Copy the basedir's CONTENTS into http/<name>/, which makes <name> the
    # archisobasedir; archiso then fetches http://ip/<name>/x86_64/airootfs.sfs.
    SUBTREE="$ARCHISO_DIR"; COPY=subtree
    KERNEL="$(firstglob "$ARCHISO_DIR/boot/x86_64/vmlinuz*" || true)"; KERNEL="${KERNEL#"$ARCHISO_DIR"/}"
    for u in intel_ucode.img amd_ucode.img; do
        have "$ARCHISO_DIR/boot/$u" && INITRDS+=("boot/$u")
    done
    main="$(firstglob "$ARCHISO_DIR/boot/x86_64/*.img" || true)"
    [ -n "$main" ] && INITRDS+=("${main#"$ARCHISO_DIR"/}")
    KOPTS="archisobasedir=$NAME archiso_http_srv=\${base-url}/ ip=dhcp checksum"
    NOTE="Runs entirely in RAM. Add copytoram to free the server after boot."
    ;;
anaconda)
    COPY=whole
    KERNEL="images/pxeboot/vmlinuz"
    INITRDS=("images/pxeboot/initrd.img")
    KOPTS="inst.repo=\${base-url}/$NAME/ ip=dhcp"
    NOTE="inst.repo points at the unpacked tree, so the whole ISO is served."
    ;;
casper)
    # Ubuntu's live installer downloads the ISO itself, so unpacking the tree
    # would waste gigabytes. Take the boot pair and publish the ISO.
    COPY=files; SERVE_ISO=1
    KERNEL="casper/vmlinuz"
    INITRDS=("$(firstglob 'casper/initrd*' || true)")
    FILES=("$KERNEL" "${INITRDS[0]}")
    KOPTS="ip=dhcp url=\${base-url}/$NAME/$NAME.iso"
    NOTE="casper downloads the ISO itself; add 'autoinstall' for unattended."
    ;;
alpine)
    COPY=whole
    KERNEL="$(firstglob 'boot/vmlinuz-*' || true)"
    INITRDS=("$(firstglob 'boot/initramfs-*' || true)")
    modloop="$(firstglob 'boot/modloop-*' || true)"
    KOPTS="ip=dhcp alpine_repo=\${base-url}/$NAME/apks"
    [ -n "$modloop" ] && KOPTS="$KOPTS modloop=\${base-url}/$NAME/$modloop"
    NOTE="Boots to a shell; run setup-alpine to install."
    ;;
live)
    SUBTREE="live"; COPY=subtree_keep
    KERNEL="$(firstglob 'live/vmlinuz*' || true)"
    INITRDS=("$(firstglob 'live/initrd*' || true)")
    squash="$(firstglob 'live/filesystem.squashfs' || true)"
    KOPTS="boot=live components ip=dhcp"
    [ -n "$squash" ] && KOPTS="$KOPTS fetch=\${base-url}/$NAME/$squash"
    NOTE="live-boot pulls the squashfs with fetch= and runs it from RAM."
    ;;
debian-netboot)
    COPY=whole
    KERNEL="$(firstglob 'debian-installer/*/linux' || firstglob '*/debian-installer/*/linux' || true)"
    INITRDS=("$(firstglob 'debian-installer/*/initrd.gz' || firstglob '*/debian-installer/*/initrd.gz' || true)")
    KOPTS="ip=dhcp"
    NOTE="The real d-i netboot initrd - installs from a network mirror."
    ;;
debian-installer)
    COPY=files
    KERNEL="install.amd/vmlinuz"
    INITRDS=("$(firstglob 'install.amd/initrd*' || true)")
    FILES=("$KERNEL" "${INITRDS[0]}")
    KOPTS="ip=dhcp"
    NOTE="WARNING: this initrd came off an ISO and expects install media - it will ask for a CD-ROM. For a reliable network install, feed this script the d-i netboot.tar.gz instead."
    ;;
unknown)
    COPY=bootdirs
    NOTE="Family not recognised - the cmdline is blank and must be filled in."
    ;;
*)
    echo "prepare-iso.sh: unknown --family '$FAMILY'" >&2; exit 1 ;;
esac

[ "$WHOLE" -eq 1 ] && { COPY=whole; SERVE_ISO=0; }

if [ "$FAMILY" != unknown ] && { [ -z "$KERNEL" ] || [ -z "${INITRDS[0]:-}" ]; }; then
    echo "prepare-iso.sh: family '$FAMILY' was detected but its kernel/initrd are" >&2
    echo "                not where that family puts them. Found in the image:" >&2
    find "$MNT" \( -name 'vmlinuz*' -o -name 'linux' -o -name 'initrd*' \) -type f \
        -printf '                  %P\n' 2>/dev/null | head -20 >&2
    exit 1
fi

# The unknown-family boot script lists what is in the image, and the listing
# has to be taken while the ISO is still mounted.
IMAGE_LISTING=""
if [ "$FAMILY" = unknown ]; then
    IMAGE_LISTING="$(find "$MNT" \( -name 'vmlinuz*' -o -name 'linux' -o -name 'initrd*' -o -name '*.img' \) \
                     -type f -printf '#     %P\n' 2>/dev/null | sort | head -25)"
fi

if [ -z "$DESC" ]; then
    label="$(blkid -s LABEL -o value "$ISO_PATH" 2>/dev/null || true)"
    DESC="${label:-$NAME}"
    if [ "$FAMILY" = unknown ]
        # `pxectl list` shows the description and nothing else, so an
        # unfinished payload has to say so there or it looks bootable.
        then DESC="$DESC - NOT BOOTABLE, cmdline unset"
        else DESC="$DESC ($FAMILY)"
    fi
fi

# ------------------------------------------------------------ boot script ---
build_boot_script() {
    local ip="$1" srvname="$2" out="$3" i
    {
        echo '#!ipxe'
        echo "# pxe-description: $DESC"
        echo "# pxe-payload-dir: $NAME"
        echo '#'
        echo "# Written by prepare-iso.sh from $(basename "$ISO_PATH")."
        echo "# Detected family: $FAMILY"
        [ -n "$NOTE" ] && echo "$NOTE" | fold -s -w 72 | sed 's/^/# /'
        if [ "$FAMILY" = unknown ]; then
            echo '#'
            echo '# NOT BOOTABLE YET. The family was not recognised, so the cmdline'
            echo '# below is blank. Pick the kernel and initrd out of the list, and'
            echo '# see boot-EXAMPLE.ipxe for what each installer family expects.'
            echo '#'
            [ -n "$IMAGE_LISTING" ] && echo "$IMAGE_LISTING"
        fi
        echo
        echo "set base-url http://$ip"
        # No trailing space when the cmdline is empty (unknown family).
        if [ -n "$KOPTS" ]
            then echo "set kbase $KOPTS"
            else echo "set kbase"
        fi
        echo
        echo ':start'
        echo "menu $DESC  --  network boot ($srvname)"
        echo 'item --gap --                 Boot'
        echo 'item default                  Default                          [default]'
        echo 'item nomodeset                Default + nomodeset  (no/odd GPU)'
        echo 'item --gap --                 Other'
        echo 'item shell                    iPXE shell'
        echo 'choose --timeout 10000 --default default selected || goto default'
        echo 'goto ${selected}'
        echo
        echo ':default'
        echo 'set kopts ${kbase}'
        echo 'goto load'
        echo
        echo ':nomodeset'
        echo 'set kopts ${kbase} nomodeset'
        echo 'goto load'
        echo
        echo ':load'
        echo 'echo'
        echo "echo Loading $DESC"
        echo 'echo   cmdline : ${kopts}'
        echo 'echo   client  : ${net0/mac}  ${ip}'
        echo 'echo'
        if [ -n "$KERNEL" ]
            then echo "kernel \${base-url}/$NAME/$KERNEL \${kopts} || goto failed"
            else echo "# kernel \${base-url}/$NAME/<vmlinuz> \${kopts} || goto failed"
        fi
        for i in "${INITRDS[@]}"; do
            [ -n "$i" ] && echo "initrd \${base-url}/$NAME/$i || goto failed"
        done
        [ -z "${INITRDS[0]:-}" ] && echo "# initrd \${base-url}/$NAME/<initrd> || goto failed"
        echo 'boot || goto failed'
        echo
        echo ':failed'
        echo 'echo'
        echo 'echo BOOT FAILED - dropping to an iPXE shell.'
        [ -n "$KERNEL" ] && echo "echo Try:  imgfetch \${base-url}/$NAME/$KERNEL"
        echo 'echo'
        echo
        echo ':shell'
        echo 'shell'
    } > "$out"
}

if [ "$DRY_RUN" -eq 1 ]; then
    tmp="$(mktemp)"
    build_boot_script "$SERVER_IP" "$SERVER_NAME" "$tmp"
    echo
    echo "──────── $BOOT_SCRIPT (dry run - not written) ────────"
    cat "$tmp"
    rm -f "$tmp"
    echo "──────────────────────────────────────────────────────"
    echo "copy mode : $COPY${SUBTREE:+ ($SUBTREE)}${FILES:+ (${FILES[*]})}"
    [ "$SERVE_ISO" -eq 1 ] && echo "also serves the ISO itself as $NAME/$NAME.iso"
    echo "Nothing was changed."
    exit 0
fi

# ------------------------------------------------------------------ copy ----
[ -d "$DEST" ] && [ "$FORCE" -eq 1 ] && { echo "==> removing existing $DEST"; rm -rf "${DEST:?}"; }
install -d "$DEST"

case "$COPY" in
    subtree)
        echo "==> copying $SUBTREE/ -> $DEST/ ($(du -sh "$MNT/$SUBTREE" | cut -f1))"
        cp -a "$MNT/$SUBTREE/." "$DEST/" ;;
    subtree_keep)
        echo "==> copying $SUBTREE/ -> $DEST/$SUBTREE/ ($(du -sh "$MNT/$SUBTREE" | cut -f1))"
        cp -a "$MNT/$SUBTREE" "$DEST/" ;;
    whole)
        echo "==> copying the whole tree -> $DEST/ ($(du -sh "$MNT" | cut -f1)) - this takes a while"
        cp -a "$MNT/." "$DEST/" ;;
    files)
        echo "==> copying the boot files only"
        for f in "${FILES[@]}"; do
            [ -n "$f" ] || continue
            install -d "$DEST/$(dirname "$f")"
            cp -a "$MNT/$f" "$DEST/$f"
            echo "    $f"
        done ;;
    bootdirs)
        echo "==> copying boot directories (pass --whole for the full tree)"
        for d in boot isolinux images casper live install.amd install; do
            [ -d "$MNT/$d" ] || continue
            cp -a "$MNT/$d" "$DEST/"
            echo "    $d/"
        done ;;
esac

if [ "$SERVE_ISO" -eq 1 ]; then
    echo "==> publishing the ISO itself as $NAME/$NAME.iso"
    # Hardlink when the ISO is already on this filesystem - it is gigabytes and
    # a second copy buys nothing.
    ln -f "$ISO_PATH" "$DEST/$NAME.iso" 2>/dev/null || cp "$ISO_PATH" "$DEST/$NAME.iso"
fi

if [ "$MOUNTED" -eq 1 ]; then umount "$MNT"; MOUNTED=0; fi

chmod -R a+rX "$DEST"
chown -R "$PXE_USER:$PXE_USER" "$DEST" 2>/dev/null || true

# ----------------------------------------------------------- write script ---
build_boot_script "$SERVER_IP" "$SERVER_NAME" "$BOOT_SCRIPT"
chmod 0644 "$BOOT_SCRIPT"
chown "$PXE_USER:$PXE_USER" "$BOOT_SCRIPT" 2>/dev/null || true
echo "==> wrote $BOOT_SCRIPT"

if [ "$EMIT_TEMPLATE" -eq 1 ]; then
    tdir="$REPO/templates/srv/pxe/http"
    install -d "$tdir"
    build_boot_script '@@SERVER_IP@@' '@@SERVER_NAME@@' "$tdir/boot-$NAME.ipxe"
    chown "$PXE_USER:$PXE_USER" "$tdir/boot-$NAME.ipxe" 2>/dev/null || true
    echo "==> wrote $tdir/boot-$NAME.ipxe (commit it to survive a rebuild)"
fi

if [ "$KEEP_ISO" -eq 0 ] && [ "$DOWNLOADED" -eq 1 ]; then
    echo "==> discarding $ISO_PATH"
    rm -f "$ISO_PATH"
fi

# --------------------------------------------------------------- summary ----
echo
echo "Done. $NAME is $(du -sh "$DEST" | cut -f1) under $DEST"
echo

if [ "$FAMILY" = unknown ]; then
    cat <<EOF
NOT BOOTABLE YET - this image's family was not recognised.

$BOOT_SCRIPT was written with the cmdline left blank and
every kernel/initrd in the image listed as a comment. Fill in the kernel,
initrd and cmdline, then:

    sudo pxectl $NAME
EOF
    exit 3
fi

printf '    %-24s # %s\n' "sudo pxectl list" "$NAME is in here now" \
                          "sudo pxectl $NAME" "serve it"

if [ "$START" -eq 1 ]; then
    echo
    exec pxectl "$NAME"
fi
