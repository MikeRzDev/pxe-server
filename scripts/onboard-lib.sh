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
#   --chain       The target is ALREADY UP, held in the survey shell by
#                 survey-node.sh, waiting to be told which disk to install to.
#                 Needs --mac (survey-node.sh prints it). Instead of waiting for
#                 someone to power the machine on, this drops a release file the
#                 held machine is polling for; it then sets BootNext and reboots
#                 itself into the installer. That is what makes a multi-disk
#                 install a SINGLE power-on: look, decide, install, without
#                 anyone going back to the machine in between.
#
# In every mode THE TARGET'S DISK IS ERASED WITHOUT CONFIRMATION once its
# answer file exists. And while a payload is armed it is the ONLY one served,
# so anything netbooting gets that installer regardless of which product it was
# supposed to run. The one-shot modes disarm PXE once the answer has been
# collected; pass --keep-armed to leave it up for back-to-back enrolments.

ONBOARD_DIR="$HOME/pxe-server/new_machine_onboarding"
ANSWERS_DIR="${PXE_ANSWER_DIR:-/srv/pxe/answers}"
# Release files for machines held in the survey shell. Served by nginx, so a
# held machine can poll for its own MAC over plain HTTP. See --chain.
SURVEY_DIR="${PXE_SURVEY_DIR:-/srv/pxe/surveys}"
GO_DIR="${PXE_GO_DIR:-/srv/pxe/http/go}"
# Overridable, because the survey phase waits for a person to walk over and
# power a machine on, which is a different timescale from waiting for an
# already-booting machine to reach the installer.
WAIT_SECS="${PXE_WAIT_SECS:-900}"
# tools/dhcp-offer-shadow.py - only needed for a target the Pi cannot hear.
SHADOW_BIN="$HOME/pxe-server/tools/dhcp-offer-shadow.py"
SHADOW_PID=""

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

# ---------------------------------------------------------------------------
# SURVEY: look inside the machine before deciding anything about it.
#
# The installer's own POST describes DMI and NICs and says NOTHING about disks,
# so without this step the server is choosing a disk to erase while blind - and
# "auto" only means anything at all on a machine with exactly one disk. Two
# minutes of looking removes both that guess and the MAC race in one go.
# ---------------------------------------------------------------------------

# Everything already filed, so a report from a previous run is not mistaken for
# this one. Name plus mtime, because a re-survey of the same machine overwrites
# its own file rather than adding another.
_survey_snapshot() {
    sudo -A -A find "$SURVEY_DIR" -name '*.txt' -printf '%f %T@\n' 2>/dev/null | sort || true
}

# Arm the read-only survey payload and wait for a machine to report. Echoes the
# report's filename. The target holds itself in a rescue shell afterwards,
# polling to be released, which is what keeps this to a single power-on.
_survey_run() {
    local before after new deadline

    # A release file outliving its install would let the machine about to be
    # surveyed straight back into an installer with nobody deciding that.
    sudo -A -A find "$GO_DIR" -name '*.txt' -delete 2>/dev/null || true

    echo "==> arming the read-only survey payload" >&2
    sudo -A -A pxectl survey >/dev/null || return 1
    before="$(_survey_snapshot)"

    cat >&2 <<'MSG'

Power the target on now, set to boot from the network via its UEFI
'PXE IPv4' entry (one-time boot menu: F11/F12/Esc at POST). NOT 'HTTP IPv4' -
that is a different DHCP vendor class this server never answers.

Nothing is written to the machine. It netboots SystemRescue into RAM,
inventories its disks, reports back, and then HOLDS, waiting to be told which
disk to install to.

MSG
    echo "Waiting up to $((WAIT_SECS / 60)) min..." >&2
    echo >&2

    deadline=$((SECONDS + WAIT_SECS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        after="$(_survey_snapshot)"
        if [ "$after" != "$before" ]; then
            new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") \
                   | awk '{print $1}' | tail -1)"
            if [ -n "$new" ]; then printf '%s' "$new"; return 0; fi
        fi
        # Tight, because the machine starts holding the moment it has reported
        # and the sooner it is answered the shorter it sits there.
        sleep 2
    done
    return 1
}

# A report from a machine that is probably still holding. The survey payload
# holds for 90 min, so anything younger than that is very likely the machine
# waiting to be told which disk to use - and re-surveying it would hang forever,
# because a held machine never netboots again on its own.
_survey_recent() {
    sudo -A -A find "$SURVEY_DIR" -name '*.txt' -mmin -90 -printf '%f\n' 2>/dev/null | sort || true
}

# Pull the machine-readable tail out of a report.
_survey_field() {  # <report-path> <MAC|DISK>
    sudo -A -A sed -n '/^### SURVEY-DATA v[0-9][0-9]*$/,/^### END SURVEY-DATA$/p' "$1" \
        | awk -v k="$2" -F'\t' '$1==k'
}

# Decide which disk the installer may erase, from the survey's own rows.
#
# The rule is deliberately timid: auto-select ONLY when the machine has exactly
# one disk, because that is the only case with nothing to decide - it is what
# `--disk auto` already meant, just now confirmed rather than assumed. With
# several disks it refuses and prints the table, because silently picking one
# of six is precisely the mistake this whole path exists to prevent.
#
# Echoes the chosen serial, or empty with an explanation on stderr.
_survey_choose_disk() {   # <report-path>
    local report="$1" rows n
    rows="$(_survey_field "$report" DISK)"
    n="$(printf '%s\n' "$rows" | grep -c . || true)"

    if [ "${n:-0}" -eq 0 ]; then
        echo "The survey found no disks at all. On an NVMe or hardware-RAID box" >&2
        echo "that usually means the controller driver is missing - which would" >&2
        echo "stop the Proxmox installer just as dead." >&2
        return 1
    fi

    if [ "$n" -eq 1 ]; then
        local dev serial size model vcode
        # awk, not `read`: with IFS=tab a run of tabs is still collapsed (tab is
        # IFS whitespace), so one empty column silently shifts every column
        # after it - which here would hand back a disk SIZE as if it were a
        # serial. The survey writes "-" rather than nothing for the same reason.
        _f() { printf '%s' "$rows" | awk -F'\t' -v n="$1" 'NR==1{v=$n; if(v=="-")v=""; print v}'; }
        dev="$(_f 2)"; serial="$(_f 3)"; size="$(_f 5)"; model="$(_f 6)"; vcode="$(_f 7)"
        if [ -z "$serial" ]; then
            echo "The machine's one disk ($dev, $size) reports no serial, so it cannot" >&2
            echo "be named stably. Re-run with:  --disk ${dev#/dev/}" >&2
            return 1
        fi
        echo "==> one disk: $dev  $size  $model" >&2
        case "$vcode" in
            windows) echo "    NOTE: it carries Windows or an EFI System Partition. There is" >&2
                     echo "          nowhere else to install, so THAT IS WHAT GETS ERASED." >&2 ;;
            data)    echo "    NOTE: it has partitions on it. They will be erased." >&2 ;;
        esac
        printf '%s' "$serial"
        return 0
    fi

    # More than one disk: a person decides.
    {
        echo
        echo "$n disks. Nothing will be selected automatically - pick one."
        echo
        printf '  %-14s %-10s %-24s %-20s %s\n' DEVICE SIZE SERIAL MODEL VERDICT
        printf '%s\n' "$rows" | awk -F'\t' 'NF>=7 {
            s = ($3 == "-" ? "(none)" : $3)
            printf "  %-14s %-10s %-24s %-20s %s\n", $2, $5, s, substr($6, 1, 20), $7
        }' 
        echo
        echo "  empty   = nothing on it            data    = has partitions, will be lost"
        echo "  windows = Windows or an ESP        inuse   = the running system booted from it"
        echo
        echo "Full report:  sudo cat $SURVEY_DIR/$(basename "$report")"
    } >&2
    return 2
}

onboard_main() {
    local payload="$1" product="$2" ui_port="$3"; shift 3
    local self; self="$(basename "${BASH_SOURCE[1]:-onboard}")"

    if [ $# -eq 0 ]; then
        echo "usage: $self <name> [--no-survey|--mac <MAC>|--any-mac|--two-pass] [--keep-armed] [new-node.py flags...]" >&2
        echo "  $self node06                              # SURVEY first, then install (default)" >&2
        echo "  $self node06 --disk-serial S3Z9NB0M1234   # survey, but the disk is already decided" >&2
        echo "  $self node06 --no-survey                  # straight to the installer, MAC from DHCP" >&2
        echo "  $self node06 --mac 84:47:09:70:9c:11      # straight to the installer, no race at all" >&2
        echo "  $self node06 --any-mac                    # wildcard, auto-narrowed - rarely needed" >&2
        echo "  $self node06 --two-pass                   # old flow: second manual reboot" >&2
        echo "  $self node06 --shadow                     # target the Pi cannot hear (behind the router)" >&2
        return 1
    fi

    local name="$1"; shift
    local mode=survey mac="" keep_armed=0 chain=0 want_serial="" resurvey=0 report=""
    local shadow="${PXE_SHADOW:-0}"
    local passthru=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --mac)        mac="${2:?--mac needs an address}"; mode=mac; shift 2 ;;
            --chain)      chain=1;       shift ;;
            --any-mac)    mode=any;      shift ;;
            --two-pass)   mode=twopass;  shift ;;
            --watch)      mode=watch;    shift ;;
            --no-survey)  mode=watch;    shift ;;
            --survey)     mode=survey;   shift ;;
            --resurvey)   mode=survey; resurvey=1; shift ;;
            # Noted as well as forwarded: with several disks the survey needs
            # to know a choice has already been made, and it is checked
            # against what the machine actually reports before being used.
            --disk-serial) want_serial="${2:?--disk-serial needs a serial}"; passthru+=("$1" "$2"); shift 2 ;;
            --keep-armed) keep_armed=1;  shift ;;
            --shadow)     shadow=1;      shift ;;
            *)            passthru+=("$1"); shift ;;
        esac
    done
    # Flags below are forwarded to new-node.py as ${passthru[@]+"${passthru[@]}"}.
    # That idiom, rather than a bare "${passthru[@]}", because expanding an
    # EMPTY array under `set -u` is an unbound-variable error in bash 3.2 -
    # which is what macOS ships. The plain form works on the Pi (bash 5) and
    # blows up the moment anyone runs these scripts anywhere else.

    # --shadow: for a target on the far side of a router that eats client DHCP
    # broadcasts, so dnsmasq never hears its DISCOVER and never answers. The
    # shadow answers instead, working off the router's OFFER - the half of the
    # conversation that does arrive. Harmless where it is not needed, since a
    # client that takes its offer lands on the same iPXE either way, but it
    # puts the NIC into promiscuous mode, so it is opt-in rather than always-on.
    _shadow_start() {
        [ "$shadow" -eq 1 ] || return 0
        if [ ! -x "$SHADOW_BIN" ]; then
            echo "==> --shadow: $SHADOW_BIN is missing; carrying on without it" >&2
            return 0
        fi
        local args=(--timeout "$(( (WAIT_SECS + 59) / 60 ))")
        [ -n "$mac" ] && args+=(--mac "$mac")
        sudo -A -A setsid "$SHADOW_BIN" "${args[@]}" \
            </dev/null >/tmp/dhcp-offer-shadow.log 2>&1 &
        SHADOW_PID=$!
        echo "==> shadowing the router's DHCP offers for this wait (pid $SHADOW_PID)"
        echo "    log: /tmp/dhcp-offer-shadow.log"
    }

    _shadow_stop() {
        [ -n "$SHADOW_PID" ] || return 0
        sudo -A -A kill "$SHADOW_PID" 2>/dev/null || true
        SHADOW_PID=""
    }

    _disarm() {
        _shadow_stop
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

    # Started once, before any mode arms anything: every mode below ends in
    # waiting for a machine to netboot, and that is the wait the shadow exists
    # to make possible. _disarm stops it again on every exit path.
    _shadow_start

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

    # ------------------------------------------------ survey, then install --
    # The default. Look inside the machine, confirm which disk may be erased,
    # and release the machine straight into the installer without anyone going
    # back to it. One power-on, start to finish.
    if [ "$mode" = survey ]; then
        local serial rc recent nrecent

        # Re-running after "pick a disk" must NOT survey again: that machine is
        # already holding and will never netboot on its own, so waiting for a
        # fresh report would hang until the hold times out.
        recent="$(_survey_recent)"
        nrecent="$(printf '%s\n' "$recent" | grep -c . || true)"
        if [ "$resurvey" -eq 0 ] && [ "${nrecent:-0}" -ge 1 ]; then
            if [ -n "$mac" ]; then
                report="$(printf '%s\n' "$recent" | grep -F "$(norm_mac "$mac").txt" | head -1 || true)"
            elif [ "$nrecent" -eq 1 ]; then
                report="$recent"
            else
                echo "Several machines reported in the last 90 min:" >&2
                printf '  %s\n' $recent >&2
                echo "Name one with --mac <MAC>, or --resurvey to take a fresh look." >&2
                return 1
            fi
        fi

        if [ -n "$report" ]; then
            echo "==> reusing the report this machine already sent" \
                 "($(( ($(date +%s) - $(sudo -A -A stat -c %Y "$SURVEY_DIR/$report")) / 60 )) min ago)"
            echo "    It is still holding, so it is not asked to boot again."
        elif ! report="$(_survey_run)"; then
            echo "Timed out: nothing reported." >&2
            echo >&2
            echo "  - Was the boot entry 'PXE IPv4' and not 'HTTP IPv4'? The latter is" >&2
            echo "    UEFI's own HTTP Boot, a vendor class this server has no rules for," >&2
            echo "    so it gets no reply and retries silently with nothing in any log." >&2
            echo "  - Watch the handshake live with:  sudo pxectl log" >&2
            echo "  - The target needs ~2 GB RAM to hold SystemRescue." >&2
            _disarm
            return 1
        fi

        mac="${report%.txt}"
        echo
        echo "==> '$name' reported in - MAC $mac"

        if [ -n "$want_serial" ]; then
            # Trust, but check: a serial typed from the wrong report, or from
            # the wrong machine entirely, would erase a disk nobody looked at.
            if ! _survey_field "$SURVEY_DIR/$report" DISK | grep -qF "$want_serial"; then
                echo >&2
                echo "--disk-serial $want_serial is not one of the disks this machine" >&2
                echo "just reported. Refusing to install to a disk the survey never saw." >&2
                echo >&2
                _survey_choose_disk "$SURVEY_DIR/$report" >/dev/null || true
                _disarm
                return 1
            fi
            serial="$want_serial"
            echo "==> using the disk you named: $serial (confirmed present)"
        else
            rc=0
            serial="$(_survey_choose_disk "$SURVEY_DIR/$report")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                # Several disks. The machine is still holding, so this costs
                # nothing but a decision - re-run naming one and it is released.
                cat >&2 <<MSG

The machine is STILL HOLDING and nothing has been written to it. Re-run with
the serial you want, and it will be released straight into the installer:

    $self $name --disk-serial <SERIAL>

It holds for 90 min from when it reported, then reboots to its normal boot
device on its own.
MSG
                # Deliberately NOT disarmed: the held machine polls this server
                # over HTTP, and taking it away would strand it.
                return 1
            fi
            if [ "$rc" -ne 0 ]; then _disarm; return 1; fi
        fi

        echo "==> writing the answer file for $name, scoped to $mac"
        # The serial is already in passthru when the caller named it; only add
        # it when the survey chose it, or new-node.py would see it twice.
        if [ -z "$want_serial" ]; then
            passthru+=(--disk-serial "$serial")
        fi
        _serve "$mac"
        # From here the machine is held and waiting, so releasing it is the
        # same job --chain does after an explicit survey-node.sh run.
        chain=1
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

    # Release AFTER arming, never before: the held machine reboots within
    # seconds of seeing this file, and it must find the installer already being
    # served when it comes back around.
    if [ "$chain" -eq 1 ]; then
        local norm; norm="$(norm_mac "$mac")"
        if [ -z "$norm" ]; then
            echo "--chain needs --mac (survey-node.sh prints the machine's MAC)." >&2
            _disarm
            return 1
        fi
        sudo -A -A install -d -m 0755 "$GO_DIR"
        printf 'install %s\n' "$name" | sudo -A -A tee "$GO_DIR/$norm.txt" >/dev/null
        sudo -A -A chmod 0644 "$GO_DIR/$norm.txt"
        echo "==> released $norm - the held machine sets BootNext and reboots"
        echo "    into the installer within ~10s. It erases the disk named above."
    fi

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

    # A release file that outlives its install is a loaded gun: the next time
    # this machine is surveyed it would be let straight back into an installer
    # without anyone deciding that. Remove it the moment it has done its job.
    if [ "$chain" -eq 1 ]; then
        sudo -A -A rm -f "$GO_DIR/$(norm_mac "$mac").txt"
        echo "==> release file removed"
    fi

    # The installer runs from its own ramdisk now and will not come back to the
    # server, so there is no reason to keep serving a disk-wiping image.
    _disarm
    _trailer
}
