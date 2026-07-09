#!/usr/bin/env bash
#
# touchpad-fixer.sh
#
# Revive an I2C-HID touchpad that failed to bind to its driver at boot.
#
# On a number of laptops (notably ASUS Zenbooks, but also various Lenovo and
# AMD Ryzen machines) the I2C-HID touchpad occasionally fails to bind to the
# `i2c_hid_acpi` driver during boot — usually a reset/init timing issue on the
# I2C bus. When that happens the touchpad vanishes completely: nothing in
# `xinput`, `libinput list-devices`, or `/proc/bus/input/devices`, even though
# the device is still present on the I2C bus.
#
# This script finds any I2C-HID device (ACPI compatible id PNP0C50 / MSFT0001)
# that has no driver bound and binds it to `i2c_hid_acpi`. If the direct bind
# fails it falls back to reloading the i2c_hid modules. It is idempotent: if
# every touchpad is already bound it does nothing.
#
# Usage:  sudo ./touchpad-fixer.sh [--verbose]
#
set -euo pipefail

DRIVER="${I2C_HID_DRIVER:-i2c_hid_acpi}"
DRIVER_DIR="/sys/bus/i2c/drivers/$DRIVER"
# ACPI compatible IDs that identify an I2C-HID device in the modalias string.
HID_IDS_REGEX='PNP0C50|MSFT0001'

VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

log()  { echo "$@"; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "  $*" || true; }

if [[ $EUID -ne 0 ]]; then
    echo "This needs root. Re-run with: sudo $0" >&2
    exit 1
fi

if [[ ! -d "$DRIVER_DIR" ]]; then
    echo "Driver '$DRIVER' not present at $DRIVER_DIR." >&2
    echo "Is the i2c_hid_acpi module loaded? Try: sudo modprobe i2c_hid_acpi" >&2
    exit 1
fi

# Print the sysfs device name of every I2C-HID device that has NO driver bound.
find_unbound_hid_devices() {
    local dev modalias
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        modalias="$(cat "$dev/modalias")"
        [[ "$modalias" =~ $HID_IDS_REGEX ]] || continue
        # A bound device has a "driver" symlink; an unbound one does not.
        if [[ ! -e "$dev/driver" ]]; then
            basename "$dev"
        fi
    done
}

# Is a given device name currently bound under our driver?
is_bound() {
    [[ -e "$DRIVER_DIR/$1" ]]
}

bind_device() {
    local name="$1"
    vlog "unbinding stale reference (if any) for $name"
    echo "$name" > "$DRIVER_DIR/unbind" 2>/dev/null || true
    vlog "binding $name to $DRIVER"
    echo "$name" > "$DRIVER_DIR/bind" 2>/dev/null || true
}

reload_modules() {
    log "Reloading i2c_hid modules..."
    modprobe -r i2c_hid_acpi i2c_hid 2>/dev/null || true
    modprobe i2c_hid i2c_hid_acpi
    sleep 1
}

main() {
    mapfile -t unbound < <(find_unbound_hid_devices)

    if [[ ${#unbound[@]} -eq 0 ]]; then
        log "All I2C-HID devices are already bound. Nothing to do."
        exit 0
    fi

    log "Found ${#unbound[@]} unbound I2C-HID device(s): ${unbound[*]}"

    local still_unbound=()
    for name in "${unbound[@]}"; do
        bind_device "$name"
        if is_bound "$name"; then
            log "Success: bound $name to $DRIVER."
        else
            still_unbound+=("$name")
        fi
    done

    if [[ ${#still_unbound[@]} -eq 0 ]]; then
        exit 0
    fi

    log "Direct bind failed for: ${still_unbound[*]}"
    reload_modules

    # Re-check after the module reload.
    mapfile -t after < <(find_unbound_hid_devices)
    if [[ ${#after[@]} -eq 0 ]]; then
        log "Success: touchpad(s) recovered after module reload."
        exit 0
    fi

    echo "Still unbound after reload: ${after[*]}" >&2
    echo "A full reboot may be required, or the I2C controller failed to" >&2
    echo "initialize. Inspect: sudo dmesg | grep -iE 'i2c|hid'" >&2
    exit 1
}

main "$@"
