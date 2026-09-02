#!/bin/bash
# secrets-guard.sh - keep the node credential store impossible to lose.
#
#     ~/scripts/secrets-guard.sh verify           # is every stored secret intact?
#     ~/scripts/secrets-guard.sh backup [--reason TEXT]
#     ~/scripts/secrets-guard.sh restore [node...] # refill gaps from the newest good snapshot
#     ~/scripts/secrets-guard.sh autoheal         # verify -> restore -> backup  (what the timer runs)
#     ~/scripts/secrets-guard.sh list [node]      # snapshots, and which hold a good copy
#     sudo ~/scripts/secrets-guard.sh protect     # chattr +i every stored secret
#     sudo ~/scripts/secrets-guard.sh unprotect [node...]
#     ~/scripts/secrets-guard.sh forget NODE     # credentials really are gone, stop alarming
#
# WHY THIS EXISTS. secrets/<node>/ holds the ONLY copy of a node's root
# password and SSH key - new-node.py generates them once, from a CSPRNG, and
# nothing can regenerate them. On 2026-09-02 the private keys and
# credentials.env for fermi, dirac and lawrence were found gone from this
# store (only id_ed25519.pub survived), and the Mac's mirror had been
# overwritten with the same emptiness by sync-from-pi.sh. Those three nodes
# are now unreachable and can only be recovered by console password reset or
# reinstall. This script exists so that can never happen twice:
#
#   1. every secret is snapshotted, timestamped, to a directory OUTSIDE this
#      repo and outside anything install.sh/uninstall.sh will ever remove;
#   2. snapshots holding the newest good copy of a node are PINNED - pruning
#      will never delete the last thing standing between you and a lost node;
#   3. live secrets are chattr +i, so no stray rm/cleanup/script can unlink
#      them - a real rotation has to say `unprotect` first, on purpose;
#   4. an hourly timer verifies, and silently restores anything that vanished.
#
# Snapshots are cleartext credentials, same as the originals: the backup root
# is 0700 and lives on this host only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_onboard() {
    # $HOME is /root under `sudo ./new-node.py` and under systemd, but the
    # store lives in the PXE user's home. Try the obvious places and take the
    # first that actually exists rather than inventing a path nobody uses.
    local c
    for c in "${ONBOARD_DIR:-}" \
             "$HOME/pxe-server/new_machine_onboarding" \
             "$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6)/pxe-server/new_machine_onboarding" \
             "/home/dietpi/pxe-server/new_machine_onboarding"; do
        [ -n "$c" ] && [ -d "$c/secrets" ] && { echo "$c"; return; }
    done
    echo "${ONBOARD_DIR:-$HOME/pxe-server/new_machine_onboarding}"
}
ONBOARD_DIR="$(resolve_onboard)"
SECRETS_DIR="${SECRETS_DIR:-$ONBOARD_DIR/secrets}"
NODES_DIR="${NODES_DIR:-$ONBOARD_DIR/nodes}"
ANSWER_DIR="${ANSWER_DIR:-/srv/pxe/answers}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/pxe-secrets}"
KEEP="${KEEP:-60}"

# The three files that make up one node's identity. id_ed25519.pub alone is
# worthless - it is the public half; losing the other two loses the node.
FILES=(id_ed25519 id_ed25519.pub credentials.env)

# A node whose credentials are genuinely gone would otherwise fail every check
# forever, and an alarm that is always on is an alarm nobody reads. `forget`
# records that you know - verify then reports it as written off instead of
# BAD. Restore still tries it: if a copy ever turns up, it comes back.
WRITTEN_OFF="$BACKUP_ROOT/WRITTEN-OFF"
is_written_off() { [ -f "$WRITTEN_OFF" ] && grep -qxF "$1" "$WRITTEN_OFF" 2>/dev/null; }

say()  { echo "$*"; }
warn() { echo "secrets-guard: $*" >&2; }
die()  { warn "$*"; exit 1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

# ----------------------------------------------------------------- checks ---
# A node is only "good" if the private key parses, its public half matches the
# stored .pub, and credentials.env carries a non-empty password. Size alone is
# not enough: a truncated or half-written key passes `-s` and fails at login.
key_pub() { ssh-keygen -y -P "" -f "$1" 2>/dev/null | awk '{print $1, $2}'; }

node_ok() {
    local d="$1" derived stored
    for f in "${FILES[@]}"; do [ -s "$d/$f" ] || return 1; done
    derived="$(key_pub "$d/id_ed25519")"
    stored="$(awk '{print $1, $2}' "$d/id_ed25519.pub" 2>/dev/null)"
    [ -n "$derived" ] && [ "$derived" = "$stored" ] || return 1
    grep -qE '^NODE_PASSWORD=.+' "$d/credentials.env" 2>/dev/null
}

node_why() {
    local d="$1"
    [ -d "$d" ] || { echo "directory missing"; return; }
    for f in "${FILES[@]}"; do
        [ -e "$d/$f" ] || { echo "$f missing"; return; }
        [ -s "$d/$f" ] || { echo "$f is 0 bytes"; return; }
    done
    [ -n "$(key_pub "$d/id_ed25519")" ] || { echo "id_ed25519 does not parse"; return; }
    [ "$(key_pub "$d/id_ed25519")" = "$(awk '{print $1, $2}' "$d/id_ed25519.pub")" ] \
        || { echo "key and .pub do not match"; return; }
    grep -qE '^NODE_PASSWORD=.+' "$d/credentials.env" || { echo "no NODE_PASSWORD"; return; }
    echo ok
}

# The store is root-owned (onboard-node.sh runs `sudo ./new-node.py`).
# Reporting "no nodes" for a store we merely cannot read is how a guard lies
# to you - so every command that reads the store asserts this FIRST, in the
# main shell. Doing it inside live_nodes was useless: that only ever runs
# inside $(...), where die exits the subshell and the caller sails on.
assert_store_readable() {
    [ -d "$SECRETS_DIR" ] || die "no secrets dir at $SECRETS_DIR (set ONBOARD_DIR)"
    [ -r "$SECRETS_DIR" ] && [ -x "$SECRETS_DIR" ] \
        || die "cannot read $SECRETS_DIR as $(id -un) - run this with sudo"
}

live_nodes() {
    [ -d "$SECRETS_DIR" ] || return 0
    find "$SECRETS_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

snapshots() {  # newest first
    [ -d "$BACKUP_ROOT" ] || return 0
    find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

# ----------------------------------------------------------------- verify ---
cmd_verify() {
    local bad=0 n why
    assert_store_readable
    for n in $(live_nodes); do
        why="$(node_why "$SECRETS_DIR/$n")"
        if [ "$why" = ok ]; then
            printf '  %-12s ok\n' "$n"
        elif is_written_off "$n"; then
            printf '  %-12s lost, acknowledged - %s\n' "$n" "$why"
        else
            printf '  %-12s BAD - %s\n' "$n" "$why"
            bad=$((bad + 1))
        fi
    done
    [ -z "$(live_nodes)" ] && say "  (no nodes enrolled)"
    if [ "$bad" -gt 0 ]; then
        warn "$bad node(s) have lost credentials - try: $HERE/$(basename "$0") restore"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------- backup ---
cmd_backup() {
    local reason="manual" stamp snap n copied=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason) reason="${2:?--reason needs text}"; shift 2 ;;
            *) die "backup: unknown argument '$1'" ;;
        esac
    done

    # A backup that silently finds nothing is how you discover, months later,
    # that you have no backups. Wrong path = hard failure, not "0 nodes".
    # A backup that silently finds nothing is how you discover, months later,
    # that you have no backups.
    assert_store_readable
    install -d -m 0700 "$BACKUP_ROOT" 2>/dev/null || die "cannot create $BACKUP_ROOT"
    stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    snap="$BACKUP_ROOT/$stamp"
    [ -e "$snap" ] && snap="$snap.$$"
    install -d -m 0700 "$snap"

    # Only good nodes get copied. Snapshotting a node that is already broken
    # would add a useless directory and, worse, make it look like a restore
    # point. The previous good snapshot stays pinned instead.
    for n in $(live_nodes); do
        if node_ok "$SECRETS_DIR/$n"; then
            install -d -m 0700 "$snap/secrets/$n"
            cp -p "$SECRETS_DIR/$n"/* "$snap/secrets/$n/" 2>/dev/null || true
            copied=$((copied + 1))
        fi
    done
    [ -d "$NODES_DIR" ]  && { install -d -m 0700 "$snap/nodes";   cp -p "$NODES_DIR"/*.toml  "$snap/nodes/"   2>/dev/null || true; }
    [ -d "$ANSWER_DIR" ] && { install -d -m 0700 "$snap/answers"; cp -p "$ANSWER_DIR"/*.toml "$snap/answers/" 2>/dev/null || true; }

    {
        echo "# snapshot $stamp"
        echo "# reason: $reason"
        echo "# host:   $(hostname)"
        echo "# nodes:  $copied good copied"
    } > "$snap/STATUS"
    ( cd "$snap" && find . -type f ! -name MANIFEST -exec sha256sum {} + | sort -k2 ) > "$snap/MANIFEST" 2>/dev/null || true

    chmod -R go-rwx "$snap"
    say "  snapshot -> $snap  ($copied node(s), reason: $reason)"
    if [ "$copied" -eq 0 ] && [ -n "$(live_nodes)" ]; then
        warn "SNAPSHOT IS EMPTY but $SECRETS_DIR has node folders - none of them verify."
        warn "this snapshot protects nothing; run 'verify' now."
    fi

    prune
    is_root && protect_backups || true
    return 0
}

# Pin the newest snapshot that holds a good copy of each node - including
# nodes that are no longer in the live store at all. Those are exactly the
# copies you need after a loss, so they must survive any retention policy.
pinned_snapshots() {
    local s n seen=" " out=" "
    for s in $(snapshots); do
        for n in $(find "$BACKUP_ROOT/$s/secrets" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null); do
            case "$seen" in *" $n "*) continue ;; esac
            if node_ok "$BACKUP_ROOT/$s/secrets/$n"; then
                seen="$seen$n "
                case "$out" in *" $s "*) ;; *) out="$out$s " ;; esac
            fi
        done
    done
    echo "$out"
}

prune() {
    local pinned count=0 s
    pinned="$(pinned_snapshots)"
    for s in $(snapshots); do
        count=$((count + 1))
        [ "$count" -le "$KEEP" ] && continue
        case "$pinned" in *" $s "*) continue ;; esac   # never drop a last-good copy
        is_root && chattr -R -i "$BACKUP_ROOT/$s" 2>/dev/null || true
        rm -rf "$BACKUP_ROOT/$s" && say "  pruned old snapshot $s"
    done
}

protect_backups() {
    local s
    for s in $(snapshots); do
        chattr -R +i "$BACKUP_ROOT/$s" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------- restore ---
# Refill only what is missing or broken. A live file that passes verification
# is never touched, so restore is always safe to run.
cmd_restore() {
    assert_store_readable
    local wanted=("$@") n s src restored=0 found
    [ ${#wanted[@]} -eq 0 ] && wanted=($(live_nodes) $(all_backed_up_nodes))
    for n in $(printf '%s\n' "${wanted[@]}" | sort -u); do
        [ -z "$n" ] && continue
        if [ -d "$SECRETS_DIR/$n" ] && node_ok "$SECRETS_DIR/$n"; then
            continue
        fi
        found=""
        for s in $(snapshots); do
            src="$BACKUP_ROOT/$s/secrets/$n"
            [ -d "$src" ] && node_ok "$src" && { found="$src"; break; }
        done
        if [ -z "$found" ]; then
            warn "$n: no good copy in any snapshot - nothing to restore from"
            continue
        fi
        is_root && chattr -R -i "$SECRETS_DIR/$n" 2>/dev/null || true
        install -d -m 0700 "$SECRETS_DIR/$n"
        cp -p "$found"/* "$SECRETS_DIR/$n/"
        chmod 0600 "$SECRETS_DIR/$n/id_ed25519" "$SECRETS_DIR/$n/credentials.env"
        chmod 0644 "$SECRETS_DIR/$n/id_ed25519.pub"
        is_root && chown -R "$(stat -c '%u:%g' "$SECRETS_DIR")" "$SECRETS_DIR/$n" 2>/dev/null || true
        say "  restored $n from $(basename "$(dirname "$(dirname "$found")")")"
        restored=$((restored + 1))
    done
    [ "$restored" -eq 0 ] && say "  nothing needed restoring"
    is_root && cmd_protect >/dev/null || true
    return 0
}

all_backed_up_nodes() {
    local s
    for s in $(snapshots); do
        find "$BACKUP_ROOT/$s/secrets" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null
    done | sort -u
}

# ---------------------------------------------------------------- protect ---
cmd_protect() {
    is_root || die "protect needs root (chattr +i) - use sudo"
    assert_store_readable
    local n
    for n in $(live_nodes); do
        chattr -R +i "$SECRETS_DIR/$n" 2>/dev/null \
            && say "  +i $n" \
            || warn "$n: could not set immutable (not ext4?)"
    done
    protect_backups
    say "  live secrets and snapshots are now immutable (rm will fail until 'unprotect')"
}

cmd_unprotect() {
    is_root || die "unprotect needs root - use sudo"
    local targets=("$@") n
    [ ${#targets[@]} -eq 0 ] && targets=($(live_nodes))
    for n in "${targets[@]}"; do
        chattr -R -i "$SECRETS_DIR/$n" 2>/dev/null && say "  -i $n" || warn "$n: nothing to clear"
    done
    warn "these secrets are now deletable - re-run 'protect' when you are done"
}

# ------------------------------------------------------------------- list ---
cmd_list() {
    local want="${1:-}" s n line
    [ -d "$BACKUP_ROOT" ] || die "no snapshots yet at $BACKUP_ROOT"
    for s in $(snapshots); do
        line=""
        for n in $(find "$BACKUP_ROOT/$s/secrets" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort); do
            [ -n "$want" ] && [ "$n" != "$want" ] && continue
            node_ok "$BACKUP_ROOT/$s/secrets/$n" && line="$line $n"
        done
        [ -n "$want" ] && [ -z "$line" ] && continue
        printf '  %s %s\n' "$s" "${line:- (none)}"
    done
}

# --------------------------------------------------------------- autoheal ---
# What the timer runs: check, silently repair anything that vanished, then
# snapshot. Exit non-zero only if something is still broken afterwards, so a
# failed unit is a real "you have lost a node" signal.
cmd_autoheal() {
    local rc=0
    cmd_verify || rc=1
    if [ "$rc" -ne 0 ]; then
        warn "restoring from snapshots"
        cmd_restore
        rc=0
        cmd_verify || rc=1
    fi
    cmd_backup --reason "$([ "$rc" -eq 0 ] && echo scheduled || echo "scheduled (UNRESOLVED LOSS)")"
    is_root && cmd_protect >/dev/null 2>&1 || true
    return "$rc"
}

cmd_forget() {
    [ $# -gt 0 ] || die "forget: name at least one node"
    install -d -m 0700 "$BACKUP_ROOT" 2>/dev/null || true
    for n in "$@"; do
        is_written_off "$n" && { say "  $n already written off"; continue; }
        echo "$n" >> "$WRITTEN_OFF"
        say "  $n written off - verify will stop calling it a failure"
    done
    warn "this does not recover anything: those credentials are still gone"
}

cmd_unforget() {
    [ $# -gt 0 ] || die "unforget: name at least one node"
    [ -f "$WRITTEN_OFF" ] || die "nothing has been written off"
    for n in "$@"; do
        grep -vxF "$n" "$WRITTEN_OFF" > "$WRITTEN_OFF.tmp" || true
        mv -f "$WRITTEN_OFF.tmp" "$WRITTEN_OFF"
        say "  $n is back under watch"
    done
}

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

case "${1:-}" in
    verify)    shift; cmd_verify "$@" ;;
    backup)    shift; cmd_backup "$@" ;;
    restore)   shift; cmd_restore "$@" ;;
    protect)   shift; cmd_protect "$@" ;;
    unprotect) shift; cmd_unprotect "$@" ;;
    list)      shift; cmd_list "$@" ;;
    autoheal)  shift; cmd_autoheal "$@" ;;
    forget)    shift; cmd_forget "$@" ;;
    unforget)  shift; cmd_unforget "$@" ;;
    -h|--help|"") usage 0 ;;
    *) warn "unknown command '$1'"; usage 1 ;;
esac
