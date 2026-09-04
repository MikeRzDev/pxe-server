#!/usr/bin/env bash
#
# bootstrap-pxe-pi.sh - stand up a PXE provisioning server on a clean Debian /
# DietPi / Raspberry Pi OS host: clone the repo, write its two config files,
# run install.sh, and verify the folder structure came out right.
#
# Software only. It does NOT download ISOs, build payloads, or copy any
# credentials - it prints those commands at the end for you to run.
#
# Run it ON the new host:
#     sudo ./bootstrap-pxe-pi.sh --server-ip 192.0.2.10
#
# ...or drive it from a workstation over ssh:
#     ssh newpi 'bash -s -- --server-ip 192.0.2.10' < bootstrap-pxe-pi.sh
#
# Idempotent: safe to re-run. --dry-run prints every command without running one.
#
set -euo pipefail

REPO_URL="https://github.com/MikeRzDev/pxe-server.git"
BRANCH=""
DEST=""
IFACE=""
SERVER_IP=""
DOMAIN=""
GATEWAY=""
DNS=""
IP_RANGE=""
NOPASSWD_USER=""
DRY_RUN=0
SKIP_INSTALL=0

usage() {
    cat <<'USAGE'
usage: bootstrap-pxe-pi.sh [options]

  --repo-url URL     git remote to clone            (default: MikeRzDev/pxe-server)
  --branch NAME      branch to check out            (default: the remote's default)
  --dest PATH        checkout location              (default: $HOME/pxe-server)
  --server-ip ADDR   this host's STATIC address     (default: auto-detected)
  --iface NAME       LAN interface                  (default: auto-detected)
  --domain NAME      search domain for new nodes    (e.g. lan)
  --gateway ADDR     gateway handed to new nodes
  --dns ADDR         resolver handed to new nodes
  --ip-range A-B     address pool for new nodes     (e.g. 192.0.2.31-192.0.2.54)
  --nopasswd-user U  grant NOPASSWD sudo to U       (default: the invoking user)
  --skip-install     configure only; do not run install.sh
  --dry-run          print what would happen, change nothing
  -h, --help         this text

The four node options write new_machine_onboarding/nodes.env, which new-node.py
reads and nothing else does. Omit them and an existing nodes.env is left alone;
if there is none, one is created from the example for you to edit.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo-url)      REPO_URL="$2"; shift 2 ;;
        --branch)        BRANCH="$2"; shift 2 ;;
        --dest)          DEST="$2"; shift 2 ;;
        --iface)         IFACE="$2"; shift 2 ;;
        --server-ip)     SERVER_IP="$2"; shift 2 ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --gateway)       GATEWAY="$2"; shift 2 ;;
        --dns)           DNS="$2"; shift 2 ;;
        --ip-range)      IP_RANGE="$2"; shift 2 ;;
        --nopasswd-user) NOPASSWD_USER="$2"; shift 2 ;;
        --skip-install)  SKIP_INSTALL=1; shift ;;
        --dry-run|-n)    DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "bootstrap-pxe-pi.sh: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------- helpers ----

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }
die()  { printf '\nbootstrap-pxe-pi.sh: %s\n' "$*" >&2; exit 1; }

# run <cmd...> - honours --dry-run
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would run: %s\n' "$*"
    else
        "$@"
    fi
}

# The operator user - the one whose $HOME gets the checkout and ~/scripts.
# Under sudo, $USER is root and SUDO_USER is who we actually mean.
OP_USER="${SUDO_USER:-${USER:-$(id -un)}}"
[ "$OP_USER" = "root" ] && die "run this as a normal user with sudo, not as root directly:
  the checkout, ~/scripts and the secrets store all belong to the operator user"

OP_HOME="$(getent passwd "$OP_USER" | cut -d: -f6)"
[ -n "$OP_HOME" ] || die "cannot resolve the home directory of '$OP_USER'"

# The hyphen matters. onboard-lib.sh, survey-node.sh, fleet-status.sh and
# secrets-guard.sh all hardcode ~/pxe-server; a checkout named anything else
# leaves them resolving paths that do not exist.
DEST="${DEST:-$OP_HOME/pxe-server}"
[ -n "$NOPASSWD_USER" ] || NOPASSWD_USER="$OP_USER"

SUDO="sudo"
[ "$(id -u)" -eq 0 ] && SUDO=""

# ------------------------------------------------------------- 1. preflight --

say "Preflight"
info "operator user : $OP_USER ($OP_HOME)"
info "checkout      : $DEST"
[ "$DRY_RUN" -eq 1 ] && info "MODE          : dry run, nothing will be changed"

command -v apt-get >/dev/null 2>&1 || die "this expects a Debian-family host (no apt-get found)"

if ! $SUDO -n true 2>/dev/null; then
    warn "sudo asked for a password just now."
    warn "That is fine here, but the onboarding scripts call 'sudo -A' in 46 places"
    warn "and will fail with 'no askpass program specified'. Step 5 fixes it."
fi

# A DHCP lease is fatal *later*: the address is baked into dnsmasq's config and
# into the iPXE scripts at install time, so a lease change silently breaks
# stage 2 - TFTP still works, the kernel and initrd 404.
DETECTED_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
DETECTED_IP="$(ip -4 -o addr show dev "${IFACE:-$DETECTED_IFACE}" 2>/dev/null \
                 | awk '{split($4,a,"/"); print a[1]; exit}')"
IFACE="${IFACE:-$DETECTED_IFACE}"
SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
[ -n "$IFACE" ]     || die "cannot detect the LAN interface - pass --iface"
[ -n "$SERVER_IP" ] || die "cannot detect this host's address - pass --server-ip"
info "interface     : $IFACE"
info "address       : $SERVER_IP"

# The kernel flags a DHCP-assigned address "dynamic"; a static one has no flag.
if ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q ' dynamic '; then
    warn "$IFACE holds a DHCP lease, not a static address."
    warn "This address is baked into dnsmasq and the iPXE scripts at install time,"
    warn "so a lease change silently breaks stage 2: TFTP still works and the"
    warn "kernel and initrd 404. Make it static before enrolling anything."
fi

FREE_MB="$(df -Pm /srv 2>/dev/null || df -Pm /)"
FREE_MB="$(printf '%s\n' "$FREE_MB" | awk 'NR==2{print $4}')"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -eq "$FREE_MB" ] 2>/dev/null && [ "$FREE_MB" -lt 10240 ]; then
    warn "only ${FREE_MB} MB free where /srv/pxe will live; payloads need ~10 GB"
fi

# --------------------------------------------------------- 2. clone / pull ---

say "Repository"
PKGS=""
command -v git >/dev/null 2>&1 || PKGS="git"
if [ -n "$PKGS" ]; then
    info "installing: $PKGS"
    run $SUDO apt-get update -qq
    run $SUDO apt-get install -y $PKGS
fi

if [ -d "$DEST/.git" ]; then
    info "already a checkout, updating"
    run git -C "$DEST" fetch --all --quiet
    [ -n "$BRANCH" ] && run git -C "$DEST" checkout "$BRANCH"
    run git -C "$DEST" pull --ff-only
elif [ -e "$DEST" ]; then
    die "$DEST exists but is not a git checkout - move it aside first"
else
    info "cloning $REPO_URL"
    if [ -n "$BRANCH" ]; then
        run git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
    else
        run git clone "$REPO_URL" "$DEST"
    fi
fi

# ------------------------------------------------------------- 3. pxe.env ----

say "pxe.env (install.sh's config)"
if [ -f "$DEST/pxe.env" ]; then
    info "already present, left alone"
elif [ -z "${IFACE}${SERVER_IP}" ]; then
    info "not needed - install.sh auto-detects from the default route"
else
    info "writing $DEST/pxe.env"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write: IFACE=%s SERVER_IP=%s\n' "$IFACE" "$SERVER_IP"
    else
        LAN_CIDR="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')"
        LAN_NET="$(ip -4 -o route show dev "$IFACE" scope link | awk '{print $1; exit}')"
        cat > "$DEST/pxe.env" <<ENVEOF
# Written by bootstrap-pxe-pi.sh. Gitignored - describes THIS host only.
IFACE=$IFACE
SERVER_IP=$SERVER_IP
LAN_CIDR=${LAN_CIDR:-$SERVER_IP/24}
LAN_NET=${LAN_NET:-}
SERVER_NAME=$(hostname -s)
PXE_USER=$OP_USER
ENVEOF
        [ -n "$LAN_NET" ] || warn "LAN_NET could not be detected - edit $DEST/pxe.env before install"
    fi
fi

# ------------------------------------------------------------ 4. nodes.env ---
#
# Mandatory for new-node.py and documented nowhere. Only the NODE_* keys its
# load_env_file() knows are honoured; anything else is silently ignored.

say "nodes.env (new-node.py's config)"
NODES_ENV="$DEST/new_machine_onboarding/nodes.env"
if [ -n "${DOMAIN}${GATEWAY}${DNS}${IP_RANGE}" ]; then
    info "writing $NODES_ENV from the flags given"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write: domain=%s gateway=%s dns=%s range=%s\n' \
               "$DOMAIN" "$GATEWAY" "$DNS" "$IP_RANGE"
    else
        [ -f "$NODES_ENV" ] && cp -p "$NODES_ENV" "$NODES_ENV.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        {
            echo "# Written by bootstrap-pxe-pi.sh. Gitignored - names YOUR network."
            [ -n "$DOMAIN" ]  && echo "NODE_DOMAIN=$DOMAIN"
            [ -n "$GATEWAY" ] && echo "NODE_GATEWAY=$GATEWAY"
            [ -n "$DNS" ]     && echo "NODE_DNS=$DNS"
            if [ -n "$IP_RANGE" ]; then
                echo "NODE_IP_START=${IP_RANGE%%-*}"
                echo "NODE_IP_END=${IP_RANGE##*-}"
            fi
            echo "NODE_DISKS=auto"
            echo "NODE_FS=ext4"
        } > "$NODES_ENV"
        chmod 0600 "$NODES_ENV"
    fi
elif [ -f "$NODES_ENV" ]; then
    info "already present, left alone"
else
    info "creating from the example - EDIT IT before enrolling anything"
    run cp "$DEST/new_machine_onboarding/nodes.env.example" "$NODES_ENV"
    run chmod 0600 "$NODES_ENV"
fi

# --------------------------------------------------------- 5. sudo askpass ---
#
# The single biggest undocumented prerequisite: the operator scripts use
# `sudo -A` throughout, which needs either NOPASSWD or $SUDO_ASKPASS.

say "Passwordless sudo for $NOPASSWD_USER"
SUDOERS="/etc/sudoers.d/pxe-$NOPASSWD_USER"
if [ "$NOPASSWD_USER" = "$OP_USER" ] && sudo -n true 2>/dev/null; then
    # Already granted somehow - DietPi ships /etc/sudoers.d/dietpi, for instance.
    # Adding a second NOPASSWD file would be a privilege change for no gain.
    GRANT="$($SUDO grep -rlE "^[[:space:]]*$NOPASSWD_USER[[:space:]]+.*NOPASSWD" \
             /etc/sudoers /etc/sudoers.d/ 2>/dev/null | head -1)"
    info "already works${GRANT:+ (granted by $GRANT)} - nothing to do"
elif [ -n "${SUDO_ASKPASS:-}" ]; then
    info "SUDO_ASKPASS is set ($SUDO_ASKPASS) - the 'sudo -A' call sites will work"
elif $SUDO test -f "$SUDOERS" 2>/dev/null; then
    info "already present: $SUDOERS"
else
    info "writing $SUDOERS"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write: %s ALL=(ALL) NOPASSWD: ALL\n' "$NOPASSWD_USER"
    else
        TMP="$(mktemp)"
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$NOPASSWD_USER" > "$TMP"
        # visudo -c on the fragment, so a typo cannot lock sudo out entirely
        $SUDO visudo -cqf "$TMP" || { rm -f "$TMP"; die "generated sudoers fragment is invalid"; }
        $SUDO install -m 0440 -o root -g root "$TMP" "$SUDOERS"
        rm -f "$TMP"
    fi
fi

# ------------------------------------------------------------ 6. install.sh --

if [ "$SKIP_INSTALL" -eq 1 ]; then
    say "install.sh skipped (--skip-install)"
else
    say "install.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -x "$DEST/install.sh" ]; then
            info "running install.sh --dry-run to show what it would do:"
            ( cd "$DEST" && $SUDO ./install.sh --dry-run ) || true
        else
            info "would run: sudo $DEST/install.sh"
            info "(no checkout here yet, so its own dry-run cannot be shown)"
        fi
    else
        ( cd "$DEST" && $SUDO ./install.sh )
    fi
fi

# ---------------------------------------------------------------- 7. verify --

say "Verifying the folder structure"
if [ "$DRY_RUN" -eq 1 ]; then
    info "skipped in dry-run"
else
    RC=0
    # path:owner:group:mode - what install.sh is supposed to have produced
    while IFS=: read -r path owner group mode; do
        [ -n "$path" ] || continue
        if [ ! -e "$path" ]; then
            warn "missing: $path"; RC=1; continue
        fi
        got="$(stat -c '%U:%G:%a' "$path" 2>/dev/null || echo '?:?:?')"
        want="${owner//OP/$OP_USER}:$group:$mode"
        if [ "$got" != "$want" ]; then
            warn "$path is $got, expected $want"; RC=1
        else
            info "ok  $path  ($got)"
        fi
    done <<VERIFY
/srv/pxe/tftp:OP:$OP_USER:755
/srv/pxe/http:OP:$OP_USER:755
/srv/pxe/iso:OP:$OP_USER:755
/srv/pxe/answers:OP:www-data:750
/srv/pxe/surveys:www-data:$OP_USER:775
/srv/pxe/http/go:www-data:$OP_USER:775
/var/backups/pxe-secrets:OP:$OP_USER:700
$OP_HOME/scripts:OP:$OP_USER:755
VERIFY

    for f in /usr/local/sbin/pxectl /usr/local/sbin/pxe-answer-server \
             /etc/dnsmasq.d/pxe.conf /etc/systemd/system/pxe@.service \
             /etc/systemd/system/pxe-answer.service; do
        if [ -e "$f" ]; then info "ok  $f"; else warn "missing: $f"; RC=1; fi
    done

    if systemctl is-enabled pxe-secrets-guard.timer >/dev/null 2>&1; then
        info "ok  pxe-secrets-guard.timer enabled"
    else
        warn "pxe-secrets-guard.timer is not enabled - credentials will not be snapshotted hourly"
        RC=1
    fi

    # Nothing PXE-related may start at boot: this server is on-demand only.
    for u in dnsmasq nginx pxe-answer; do
        if systemctl is-enabled "$u" >/dev/null 2>&1; then
            warn "$u is enabled at boot - it should be disabled (on-demand only)"
            RC=1
        else
            info "ok  $u disabled at boot"
        fi
    done

    [ "$RC" -eq 0 ] && info "structure looks right" || warn "see the warnings above"
fi

# ------------------------------------------------------------- 8. follow-ups -

cat <<NEXT

== Not done here, on purpose

Payloads are multi-GB downloads and builds. Run what you need:

    sudo $DEST/payloads/build-proxmox.sh          # Proxmox VE installer
    sudo $DEST/payloads/build-rescue.sh           # SystemRescue + the disk survey
    sudo $DEST/payloads/build-ipxe-chain.sh       # only if you need --shadow

The fleet (answer-fetching) payloads are built from an ISO prepared by
new_machine_onboarding/prepare-auto-iso.sh, which is amd64-only and runs in
Docker on a workstation - see references/enrol-node.md.

Then:

    sudo pxectl list                              # what is installed
    sudo pxectl status                            # everything should be inactive
    $OP_HOME/scripts/pxe.sh <payload>             # arm one
    $OP_HOME/scripts/pxe-stop.sh                  # turn it off

Credentials for nodes enrolled here live in
$DEST/new_machine_onboarding/secrets/ and are NOT copied from any other
server by this script. If this host replaces an existing one, move that store
across deliberately - it cannot be regenerated.
NEXT
