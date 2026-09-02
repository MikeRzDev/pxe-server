#!/bin/bash
# onboard-lib.sh - the shared engine behind onboard-node.sh (Proxmox VE) and
# onboard-admin.sh (Proxmox Datacenter Manager). Not meant to be run directly.
#
# The two wrappers differ only in which payload they arm, which product they
# ask new-node.py for, and which port the web UI ends up on. Everything below
# - the modes, watching the journals, narrowing a wildcard the moment it is
# used, disarming afterwards - is identical for both, and subtle enough that
# two copies would drift.
#
#     onboard_main <payload> <product> <ui-port> "$@"
#
# THE MODES:
#
#   (default)     WATCH. Needs nothing known in advance and still installs in a
#                 single power-on. The trick is that a netbooting machine
#                 announces its MAC to dnsmasq roughly a minute and a half
#                 before the installer asks for its answer file - so there is
#                 ample time to catch it and write the answer into the SAME
#                 boot. Measured on maxwell's real enrolment, 2026-09-02:
#
#                     18:24:56  dnsmasq: PXE(eth0) 84:47:09:70:9c:5c proxy
#                     18:26:31  pxe-answer: POST /answer ... (matched)
#                     -------------------------------------------------
#                     95 seconds to write a file that takes milliseconds.
#
#                 Scoped to exactly one MAC, so no wildcard ever exists. If the
#                 window is somehow missed the installer 404s and aborts having
#                 touched nothing - which is precisely the --two-pass outcome,
#                 so the worst case is one extra reboot, not a broken machine.
#
#   --mac <MAC>   You already know the MAC. Same single power-on, but the
#                 answer file is in place before the machine is even switched
#                 on, so there is no race at all. Marginally the safest.
#
#   --any-mac     Serves the answer as `default.toml`, which matches ANY
#                 machine, and narrows it to <mac>.toml once collected. Only
#                 useful if a target somehow never shows up in dnsmasq's log;
#                 WATCH gets the same result without the wildcard. During the
#                 window anything netbooting on this LAN is wiped.
#
#   --two-pass    The old flow: arm with no answer file, let the first netboot
#                 404, capture the MAC from that, then serve. Costs a SECOND
#                 MANUAL REBOOT. Kept because it is the most predictable thing
#                 to fall back to when something upstream has changed.
#
# In every mode THE TARGET'S DISK IS ERASED WITHOUT CONFIRMATION once its
# answer file exists. And while a payload is armed it is the ONLY one served,
# so anything netbooting gets that installer regardless of which product it was
# supposed to run. The one-shot modes disarm PXE once the answer has been
# collected; pass --keep-armed to leave it up for back-to-back enrolments.

ONBOARD_DIR="$HOME/pxe-server/new_machine_onboarding"
ANSWERS_DIR="${PXE_ANSWER_DIR:-/srv/pxe/answers}"
WAIT_SECS=900

norm_mac() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f'; }

# Watch dnsmasq for a machine starting a PXE boot and echo its MAC. The line is
#     <xid> PXE(eth0) 84:47:09:70:9c:5c proxy
# which dnsmasq only emits for an actual PXE client in proxy-DHCP mode - an
# ordinary laptop renewing its lease logs a "vendor class: MSFT 5.0" and no
# PXE(...) line, so this cannot be fooled by unrelated DHCP traffic.
wait_for_pxe_mac() {
    local since="$1" deadline=$((SECONDS + WAIT_SECS)) hit
    while [ "$SECONDS" -lt "$deadline" ]; do
        hit="$(sudo -A -A journalctl -u dnsmasq --no-pager -S "$since" 2>/dev/null \
               | grep -oE 'PXE\([^)]*\) ([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | tail -1)"
        [ -n "$hit" ] && { printf '%s' "${hit##* }"; return 0; }
        sleep 2
    done
    return 1
}

# Watch the answer server's journal since $1 for a line matching $2, and echo
# the first MAC on it. Handles both formats the server emits:
#   NO ANSWER for <ip> (macs=aabbccddeeff) - add <mac>.toml ...
#   POST /answer from <ip> macs=[aabbccddeeff] -> <file>.toml (matched ...)
wait_for_log() {
    local since="$1" pattern="$2" deadline=$((SECONDS + WAIT_SECS)) line mac
    while [ "$SECONDS" -lt "$deadline" ]; do
        line="$(sudo -A -A journalctl -u pxe-answer --no-pager -S "$since" 2>/dev/null \
                | grep -- "$pattern" | tail -1)"
        if [ -n "$line" ]; then
            mac="$(sed -n 's/.*macs=\[\{0,1\}\([^],)]*\).*/\1/p' <<<"$line" | cut -d, -f1)"
            [ -n "$mac" ] && { printf '%s' "$mac"; return 0; }
        fi
        sleep 5
    done
    return 1
}

onboard_main() {
    local payload="$1" product="$2" ui_port="$3"; shift 3
    local self; self="$(basename "${BASH_SOURCE[1]:-onboard}")"

    if [ $# -eq 0 ]; then
        echo "usage: $self <name> [--mac <MAC>|--any-mac|--two-pass] [--keep-armed] [new-node.py flags...]" >&2
        echo "  $self node06                              # one power-on, MAC caught from DHCP (default)" >&2
        echo "  $self node06 --mac 84:47:09:70:9c:11      # one power-on, no race at all" >&2
        echo "  $self node06 --any-mac                    # wildcard, auto-narrowed - rarely needed" >&2
        echo "  $self node06 --two-pass                   # old flow: second manual reboot" >&2
        return 1
    fi

    local name="$1"; shift
    local mode=watch mac="" keep_armed=0
    local passthru=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --mac)        mac="${2:?--mac needs an address}"; mode=mac; shift 2 ;;
            --any-mac)    mode=any;      shift ;;
            --two-pass)   mode=twopass;  shift ;;
            --watch)      mode=watch;    shift ;;
            --keep-armed) keep_armed=1;  shift ;;
            *)            passthru+=("$1"); shift ;;
        esac
    done
    # Flags below are forwarded to new-node.py as ${passthru[@]+"${passthru[@]}"}.
    # That idiom, rather than a bare "${passthru[@]}", because expanding an
    # EMPTY array under `set -u` is an unbound-variable error in bash 3.2 -
    # which is what macOS ships. The plain form works on the Pi (bash 5) and
    # blows up the moment anyone runs these scripts anywhere else.

    _disarm() {
        [ "$keep_armed" -eq 1 ] && { echo "==> leaving PXE armed (--keep-armed)"; return; }
        echo "==> disarming PXE (the install no longer needs it)"
        "$HOME/scripts/pxe-stop.sh" >/dev/null 2>&1 || true
    }

    _serve() {  # $1 = mac, or empty for the default.toml wildcard
        cd "$ONBOARD_DIR"
        if [ -n "$1" ]; then
            sudo ./new-node.py "$name" --mac "$1" --product "$product" \
                 ${passthru[@]+"${passthru[@]}"} --serve
        else
            sudo ./new-node.py "$name" --product "$product" \
                 ${passthru[@]+"${passthru[@]}"} --serve
        fi
    }

    _trailer() {
        cat <<MSG

  watch it     : sudo pxectl log
  credentials  : sudo cat $ONBOARD_DIR/secrets/$name/credentials.env
  fleet status : ~/scripts/fleet-status.sh

The web UI comes up on https://<address>:$ui_port
Then, on the Mac:  cd ~/Documents/DevOps/Manhattan && ./sync-from-pi.sh
MSG
    }

    local since

    # ----------------------------------------------------- two-pass (old) --
    if [ "$mode" = twopass ]; then
        echo "==> arming PXE ($payload)"
        sudo -A -A pxectl "$payload"
        cat <<MSG

Boot '$name' now via its UEFI 'PXE IPv4' entry (one-time boot menu, NOT
'HTTP IPv4'). Its first attempt will 404 and change nothing; that is how its
MAC is discovered. Waiting up to $((WAIT_SECS / 60)) min...

MSG
        since="$(date '+%Y-%m-%d %H:%M:%S')"
        if ! mac="$(wait_for_log "$since" "NO ANSWER")"; then
            echo "Timed out waiting for a netboot attempt. Re-run when '$name' is ready." >&2
            return 1
        fi
        echo "==> captured MAC: $mac"
        echo
        _serve "$mac"
        cat <<MSG

Now reboot '$name' via PXE IPv4 AGAIN - this time it matches and WIPES its
disk, installing unattended. (Drop --two-pass next time to skip this step.)
MSG
        _trailer
        return 0
    fi

    # ------------------------------------------- answer known before boot --
    if [ "$mode" = mac ]; then
        echo "==> writing the answer file for $name, scoped to $mac"
        _serve "$mac"
    elif [ "$mode" = any ]; then
        cat <<'WARN'
==> WILDCARD MODE

    The answer file is served as default.toml, which MATCHES ANY MACHINE.
    From the moment PXE is armed until the target collects it, anything on
    this LAN that network-boots will be WIPED and reinstalled.

    Power on ONLY the machine you are enrolling during this window.
    (The default mode does not need this - it catches the MAC from DHCP.)

WARN
        _serve ""
    fi

    echo
    echo "==> arming PXE ($payload)"
    sudo -A -A pxectl "$payload"
    since="$(date '+%Y-%m-%d %H:%M:%S')"

    # ------------------------------------------------ watch: catch the MAC --
    if [ "$mode" = watch ]; then
        cat <<MSG

Power on '$name' now, set to boot from network via its UEFI 'PXE IPv4' entry.

Nothing else is needed. Its MAC is read from the DHCP request it makes on the
way up, and its answer file is written while it is still fetching the
installer - so this same boot wipes the disk and installs unattended.

Waiting up to $((WAIT_SECS / 60)) min for it to appear...

MSG
        if ! mac="$(wait_for_pxe_mac "$since")"; then
            echo "Timed out: nothing tried to PXE boot." >&2
            echo "Check the boot entry is 'PXE IPv4', not 'HTTP IPv4' - the latter is a" >&2
            echo "different DHCP vendor class this server has no rules for, so it stays silent." >&2
            _disarm
            return 1
        fi
        echo "==> '$name' is netbooting - MAC $mac"
        echo "==> writing its answer file now (the installer asks for it in ~90s)"
        echo
        _serve "$mac"
        echo
    fi

    cat <<MSG
Waiting to confirm '$name' collected its answer file...

MSG

    local matched
    if ! matched="$(wait_for_log "$since" '\-> .*\.toml')"; then
        echo "Timed out: '$name' never fetched an answer file." >&2
        if [ "$mode" = any ]; then
            # The wildcard was never claimed, so take it away rather than leave
            # something armed that would wipe whatever netboots next.
            sudo -A -A rm -f "$ANSWERS_DIR/default.toml" || true
            echo "Removed the wildcard default.toml." >&2
            _disarm
        else
            # The answer file is MAC-scoped and already in place, so one more
            # netboot finishes the job. Deliberately leave PXE armed - disarming
            # here would mean that reboot had nothing to boot into.
            echo "Its answer file is in place and PXE is still armed, so just" >&2
            echo "reboot '$name' via PXE IPv4 again and it will install." >&2
            echo "Run ~/scripts/pxe-stop.sh when you give up on it." >&2
        fi
        return 1
    fi

    echo "==> '$name' collected its answer file (MAC $matched) - installing now."

    # Narrow the wildcard the moment it has been used, so it cannot catch a
    # second machine. The installer already holds its copy; renaming underneath
    # it is safe.
    if [ "$mode" = any ]; then
        local norm; norm="$(norm_mac "$matched")"
        if [ -n "$norm" ] && sudo -A -A test -f "$ANSWERS_DIR/default.toml"; then
            sudo -A -A mv "$ANSWERS_DIR/default.toml" "$ANSWERS_DIR/$norm.toml"
            echo "==> narrowed default.toml -> $norm.toml (the wildcard is gone)"
        fi
    fi

    # The installer runs from its own ramdisk now and will not come back to the
    # server, so there is no reason to keep serving a disk-wiping image.
    _disarm
    _trailer
}
