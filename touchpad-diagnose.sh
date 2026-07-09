#!/usr/bin/env bash
#
# touchpad-diagnose.sh
#
# Collect everything needed to tell whether a flaky I2C-HID touchpad is a
# software (bind / power-management) problem or a hardware/firmware one
# (loose FPC connector, failing module, outdated BIOS). Prints a report and
# a short verdict.
#
# Run with sudo for the full kernel log; without root it falls back to
# journalctl and notes what it couldn't read.
#
# Usage:  sudo ./touchpad-diagnose.sh
#
set -uo pipefail

HID_IDS_REGEX='PNP0C50|MSFT0001'
# Kernel-log lines that belong to the touchpad / its I2C bus.
CONTEXT_REGEX='i2c_hid|i2c_designware|i2c-ASUE|ASUE120C|ELAN|touchpad'
# Error keywords that indicate a signal / hardware / firmware problem rather
# than a benign bind-timing issue. Kept specific so unrelated log lines (e.g.
# btrfs "crc32c checksum") don't match — only counted when they also appear on
# a CONTEXT_REGEX line.
ERR_KEYWORDS='failed to reset|incomplete report|invalid report|timed out|controller timed out|-EREMOTEIO|-ENXIO|transfer error|crc error|reset device'

hr()  { printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

is_root=0
[[ $EUID -eq 0 ]] && is_root=1

# ---------------------------------------------------------------------------
hr "System"
if [[ -r /sys/class/dmi/id/product_name ]]; then
    echo "Model:  $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
fi
if [[ -r /sys/class/dmi/id/bios_version ]]; then
    echo "BIOS:   $(cat /sys/class/dmi/id/bios_version 2>/dev/null)  ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
    echo "        ^ compare against the latest on the ASUS support page for your model;"
    echo "          an outdated touchpad firmware is a common cause of these faults."
fi
echo "Kernel: $(uname -r)"
echo "Session:${XDG_SESSION_TYPE:-unknown}"

# ---------------------------------------------------------------------------
hr "I2C-HID devices (bind + power state)"
found=0
for dev in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$dev/modalias" ]] || continue
    grep -qE "$HID_IDS_REGEX" "$dev/modalias" 2>/dev/null || continue
    found=1
    name="$(basename "$dev")"
    [[ -e "$dev/driver" ]] && bind="BOUND" || bind="NOT BOUND"
    pm="$(cat "$dev/power/control" 2>/dev/null || echo '?')"
    echo "  $name"
    echo "     modalias      : $(cat "$dev/modalias" 2>/dev/null)"
    echo "     driver bound  : $bind"
    echo "     power/control : $pm   (want: on = autosuspend off)"
    for child in "$dev"/*:*; do
        [[ -e "$child/driver" ]] || continue
        echo "     HID driver    : $(basename "$(readlink -f "$child/driver")") on $(basename "$child")"
    done
done
[[ $found -eq 0 ]] && echo "  (no I2C-HID touchpad device present on the bus — fully dropped)"

# ---------------------------------------------------------------------------
hr "Input layer"
if have libinput; then
    if [[ $is_root -eq 1 ]]; then
        libinput list-devices 2>/dev/null | awk '/[Tt]ouch[Pp]ad/{p=1} p{print "  "$0} /^$/{if(p)exit}'
    else
        echo "  (run as root to read libinput device capabilities)"
    fi
else
    echo "  libinput not installed"
fi
if have xinput && [[ -n "${DISPLAY:-}" ]]; then
    echo "  --- xinput pointer nodes ---"
    xinput list 2>/dev/null | grep -iE 'touchpad|mouse' | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
hr "Kernel messages (I2C / HID)"
kbuf=""
if [[ $is_root -eq 1 ]] && dmesg >/dev/null 2>&1; then
    kbuf="$(dmesg 2>/dev/null)"
    src="dmesg"
elif have journalctl; then
    kbuf="$(journalctl -k -b 2>/dev/null)"
    src="journalctl -k"
    [[ $is_root -eq 0 ]] && echo "  (not root: using $src; run with sudo for raw dmesg)"
fi

if [[ -n "$kbuf" ]]; then
    matches="$(echo "$kbuf" | grep -iE "$CONTEXT_REGEX" | grep -ivE 'input: .*as /devices' | tail -40)"
    if [[ -n "$matches" ]]; then
        echo "$matches" | sed 's/^/  /'
    else
        echo "  (no touchpad/I2C kernel lines beyond device registration, source: $src)"
    fi
else
    echo "  (could not read kernel log)"
fi

# ---------------------------------------------------------------------------
hr "Error-signal count (hardware/firmware indicator)"
errcount=0
if [[ -n "$kbuf" ]]; then
    # Only count error keywords that appear on a touchpad/I2C context line.
    errcount="$(echo "$kbuf" | grep -iE "$CONTEXT_REGEX" | grep -icE "$ERR_KEYWORDS")"
fi
echo "  I2C/HID error lines in this boot's kernel log: $errcount"

# ---------------------------------------------------------------------------
hr "Verdict"
if [[ "$errcount" -gt 0 ]]; then
    echo "  ⚠ $errcount I2C/HID error line(s) found. Repeated reset/timeout/CRC/"
    echo "    incomplete-report errors point to a SIGNAL / HARDWARE / FIRMWARE"
    echo "    problem (loose touchpad FPC connector, failing module, or old BIOS)"
    echo "    rather than a benign bind-timing issue."
    echo "    Next: update BIOS, then if it persists, reseat/replace the touchpad."
elif [[ $found -eq 0 ]]; then
    echo "  Touchpad is currently DROPPED from the bus with no errors logged."
    echo "    Run: sudo ./touchpad-fixer.sh   to rebind it."
    echo "    If it keeps dropping with a clean log, still suspect BIOS/hardware."
else
    echo "  Device is present and bound with no I2C/HID errors logged. If it still"
    echo "    misbehaves, capture live events during the fault:"
    echo "      sudo libinput debug-events"
    echo "    and re-run this with sudo right after a failure to catch the log."
fi
echo
