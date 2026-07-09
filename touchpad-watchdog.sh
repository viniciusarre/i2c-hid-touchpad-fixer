#!/usr/bin/env bash
#
# touchpad-watchdog.sh
#
# Long-running poll loop: if an I2C-HID touchpad silently drops (driver
# unbinds / device disappears from under the driver) mid-session, rebind it
# automatically. Run as a systemd service. Catches the "goes dead / unbound"
# failure mode; the bound-but-dead hangs (freeze / stuck-scroll) are not
# detectable by a bind poll — use the reset hotkey for those.
#
# Interval is configurable via TOUCHPAD_WATCHDOG_INTERVAL (seconds).
#
set -uo pipefail

HID_IDS_REGEX='PNP0C50|MSFT0001'
INTERVAL="${TOUCHPAD_WATCHDOG_INTERVAL:-3}"
FIXER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/touchpad-fixer.sh"

# Return 0 if any I2C-HID touchpad currently has no driver bound.
any_unbound() {
    local dev
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        grep -qE "$HID_IDS_REGEX" "$dev/modalias" 2>/dev/null || continue
        [[ -e "$dev/driver" ]] || return 0
    done
    return 1
}

echo "touchpad-watchdog: polling every ${INTERVAL}s (fixer: $FIXER)"
while true; do
    if any_unbound; then
        echo "touchpad-watchdog: touchpad unbound — running fixer"
        "$FIXER" || true
    fi
    sleep "$INTERVAL"
done
