#!/bin/bash
# onboard-lib.sh - the shared engine behind onboard-node.sh (Proxmox VE) and
# onboard-admin.sh (Proxmox Datacenter Manager). Not meant to be run directly.
#
# The two wrappers differ only in which payload they arm, which product they
# ask new-node.py for, and which port the web UI ends up on. Everything below
# - the three identification modes, watching the answer server's journal,
# narrowing a wildcard the moment it is used, disarming afterwards - is
# identical for both, and is subtle enough that two copies would drift.
#
#     onboard_main <payload> <product> <ui-port> "$@"
#
# THE THREE MODES, and why the safe one is the default:
#
#   --mac <MAC>   You know the NIC's MAC (UEFI network-boot screen, a sticker
#                 on the case, or your router's DHCP leases). The answer file
#                 is written BEFORE the machine boots and scoped to that one
#                 MAC, so a single power-on installs unattended and no
#                 wildcard ever exists. This is the best of the three.
#
#   --any-mac     You do not know the MAC but still want one power-on. The
#                 answer goes out as `default.toml`, which matches ANY
#                 machine. As soon as the target collects it, this renames it
#                 to <mac>.toml and disarms PXE, so the wildcard lives for
#                 seconds - but during those seconds anything that netboots on
#                 this LAN is wiped and reinstalled.
#
#   (neither)     Two-pass discovery, and the default because it is the only
#                 mode that is safe with no prior knowledge: arm with no answer
#                 file, let the target's first netboot 404 (harmless - the
#                 installer aborts and touches nothing), capture its MAC from
#                 that, then serve. Costs a SECOND MANUAL REBOOT of the target.
#
# In every mode THE TARGET'S DISK IS ERASED WITHOUT CONFIRMATION once its
# answer file exists. And while a payload is armed it is the ONLY one served,
# so anything netbooting gets that installer regardless of which product it was
# supposed to run. The one-shot modes therefore disarm PXE once the answer has
# been delivered; pass --keep-armed to leave it up when enrolling several
# machines back to back.

ONBOARD_DIR="$HOME/pxe-server/new_machine_onboarding"
ANSWERS_DIR="${PXE_ANSWER_DIR:-/srv/pxe/answers}"
WAIT_SECS=900

norm_mac() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f'; }

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
        echo "usage: $self <name> [--mac <MAC> | --any-mac] [--keep-armed] [new-node.py flags...]" >&2
        echo "  $self node06 --mac 84:47:09:70:9c:11      # one power-on, scoped (preferred)" >&2
        echo "  $self node06 --any-mac                    # one power-on, wildcard, auto-narrowed" >&2
        echo "  $self node06                              # two-pass: needs a second manual reboot" >&2
        return 1
    fi

    local name="$1"; shift
    local mode=twopass mac="" keep_armed=0
    local passthru=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --mac)        mac="${2:?--mac needs an address}"; mode=mac; shift 2 ;;
            --any-mac)    mode=any;      shift ;;
            --two-pass)   mode=twopass;  shift ;;
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

    _trailer() {
        cat <<MSG

  watch it     : sudo pxectl log
  credentials  : sudo cat $ONBOARD_DIR/secrets/$name/credentials.env
  fleet status : ~/scripts/fleet-status.sh

The web UI comes up on https://<address>:$ui_port
Then, on the Mac:  cd ~/Documents/DevOps/Manhattan && ./sync-from-pi.sh
MSG
    }

    # --------------------------------------------- two-pass (safe default) --
    if [ "$mode" = twopass ]; then
        echo "==> arming PXE ($payload)"
        sudo -A -A pxectl "$payload"
        cat <<MSG

Boot '$name' now via its UEFI 'PXE IPv4' entry (one-time boot menu, NOT
'HTTP IPv4'). Its first attempt will 404 and change nothing; that is how its
MAC is discovered. Waiting up to $((WAIT_SECS / 60)) min...

MSG
        local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
        if ! mac="$(wait_for_log "$since" "NO ANSWER")"; then
            echo "Timed out waiting for a netboot attempt. Re-run when '$name' is ready." >&2
            return 1
        fi
        echo "==> captured MAC: $mac"
        echo
        cd "$ONBOARD_DIR"
        sudo ./new-node.py "$name" --mac "$mac" --product "$product" ${passthru[@]+"${passthru[@]}"} --serve
        cat <<MSG

Now reboot '$name' via PXE IPv4 AGAIN - this time it matches and WIPES its
disk, installing unattended. (Give it --mac $mac next time to skip this step.)
MSG
        _trailer
        return 0
    fi

    # ------------------------------------------- one-shot: answer up front --
    cd "$ONBOARD_DIR"
    if [ "$mode" = mac ]; then
        echo "==> writing the answer file for $name, scoped to $mac"
        sudo ./new-node.py "$name" --mac "$mac" --product "$product" ${passthru[@]+"${passthru[@]}"} --serve
    else
        cat <<'WARN'
==> WILDCARD MODE

    No MAC given, so the answer file is served as default.toml, which MATCHES
    ANY MACHINE. From the moment PXE is armed until the target collects it,
    anything on this LAN that network-boots will be WIPED and reinstalled.

    Power on ONLY the machine you are enrolling during this window.

WARN
        sudo ./new-node.py "$name" --product "$product" ${passthru[@]+"${passthru[@]}"} --serve
    fi

    echo
    echo "==> arming PXE ($payload)"
    sudo -A -A pxectl "$payload"

    local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
    cat <<MSG

Power on '$name' now, set to boot from network via its UEFI 'PXE IPv4' entry.

Nothing else is needed: it fetches its answer file on this FIRST boot, wipes
its disk, installs unattended and reboots.

Waiting up to $((WAIT_SECS / 60)) min to confirm it collected the answer...

MSG

    local matched
    if ! matched="$(wait_for_log "$since" '\-> .*\.toml')"; then
        echo "Timed out: '$name' never fetched an answer file." >&2
        echo "Nothing was installed. Check the boot entry is 'PXE IPv4', not 'HTTP IPv4'." >&2
        if [ "$mode" = any ]; then
            sudo -A -A rm -f "$ANSWERS_DIR/default.toml" || true
            echo "Removed the wildcard default.toml." >&2
        fi
        _disarm
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
