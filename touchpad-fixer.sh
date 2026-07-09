#!/usr/bin/env bash
#
# touchpad-fixer.sh
#
# Fix two related failure modes of I2C-HID touchpads on laptops such as the
# ASUS Zenbook (also seen on various Lenovo / AMD Ryzen machines):
#
#   1. Dead touchpad — the device fails to bind to the `i2c_hid_acpi` driver
#      at boot, or drops after a suspend/resume cycle. It vanishes from
#      xinput / libinput / /proc/bus/input/devices even though it's still on
#      the I2C bus. Fix: (re)bind the driver.
#
#   2. Motion freeze — clicks still register but sliding/scrolling freezes
#      intermittently. Caused by runtime power management (autosuspend) putting
#      the device to sleep and dropping the high-frequency motion packets.
#      Fix: disable runtime PM (power/control = on) on the device.
#
# This script always disables runtime PM on every I2C-HID touchpad it finds,
# and additionally (re)binds any that are unbound. It is idempotent.
#
# Modes:
#   (default)  Bind any I2C-HID device with NO driver bound. Best for boot.
#   --reset    Force an unbind+rebind of every I2C-HID device, re-probing it
#              even if it looks bound. Best for the resume case, where the
#              device can be bound-but-stuck.
#
# Usage:  sudo ./touchpad-fixer.sh [--reset] [--verbose]
#
set -euo pipefail

DRIVER="${I2C_HID_DRIVER:-i2c_hid_acpi}"
DRIVER_DIR="/sys/bus/i2c/drivers/$DRIVER"
# ACPI compatible IDs that identify an I2C-HID device in the modalias string.
HID_IDS_REGEX='PNP0C50|MSFT0001'

RESET=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        -r|--reset)   RESET=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

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

# Print the sysfs device name of every I2C-HID device (bound or not).
find_all_hid_devices() {
    local dev modalias
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        modalias="$(cat "$dev/modalias")"
        [[ "$modalias" =~ $HID_IDS_REGEX ]] || continue
        basename "$dev"
    done
}

# Print only the I2C-HID devices that have NO driver bound.
find_unbound_hid_devices() {
    local name
    while read -r name; do
        [[ -n "$name" ]] || continue
        [[ -e "/sys/bus/i2c/devices/$name/driver" ]] || echo "$name"
    done < <(find_all_hid_devices)
}

is_bound() { [[ -e "$DRIVER_DIR/$1" ]]; }

unbind_device() {
    vlog "unbinding $1"
    echo "$1" > "$DRIVER_DIR/unbind" 2>/dev/null || true
}

bind_device() {
    vlog "binding $1 to $DRIVER"
    echo "$1" > "$DRIVER_DIR/bind" 2>/dev/null || true
}

reload_modules() {
    log "Reloading i2c_hid modules..."
    modprobe -r i2c_hid_acpi i2c_hid 2>/dev/null || true
    modprobe i2c_hid i2c_hid_acpi
    sleep 1
}

# Disable runtime autosuspend on every present I2C-HID touchpad and its HID
# child node. Setting power/control=on keeps the device awake so motion
# packets aren't dropped. Runs every time, since a freshly (re)bound device
# resets back to "auto".
disable_runtime_pm() {
    local dev name f
    while read -r name; do
        [[ -n "$name" ]] || continue
        dev="/sys/bus/i2c/devices/$name"
        for f in "$dev/power/control" "$dev"/*/power/control; do
            [[ -w "$f" ]] || continue
            if echo on > "$f" 2>/dev/null; then
                vlog "runtime PM disabled: $f"
            fi
        done
    done < <(find_all_hid_devices)
}

# Send a desktop notification into the graphical user's session. The fixer
# runs as root (via sudo / systemd), so we drop to the target user and point at
# their D-Bus session. Silently no-ops if notify-send is missing or no session
# is found (e.g. at boot). Disable with TOUCHPAD_FIXER_NOTIFY=0.
notify_user() {
    [[ "${TOUCHPAD_FIXER_NOTIFY:-1}" == "0" ]] && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    local urgency="$1" title="$2" body="$3"
    local u uid
    u="${SUDO_USER:-}"
    if [[ -z "$u" ]]; then
        # Fall back to the owner of an active /run/user/<uid> session bus.
        u="$(who 2>/dev/null | awk 'NR==1{print $1}')"
    fi
    [[ -n "$u" ]] || return 0
    uid="$(id -u "$u" 2>/dev/null)" || return 0
    [[ -S "/run/user/$uid/bus" ]] || return 0
    sudo -u "$u" \
        DISPLAY="${DISPLAY:-:0}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        notify-send -a "touchpad-fixer" -i input-touchpad -u "$urgency" \
        "$title" "$body" 2>/dev/null || true
}

main() {
    local rc=0
    local targets=()

    if [[ $RESET -eq 1 ]]; then
        mapfile -t targets < <(find_all_hid_devices)
        if [[ ${#targets[@]} -gt 0 ]]; then
            log "Resetting ${#targets[@]} I2C-HID device(s): ${targets[*]}"
            for name in "${targets[@]}"; do
                unbind_device "$name"
            done
        fi
    else
        mapfile -t targets < <(find_unbound_hid_devices)
        [[ ${#targets[@]} -gt 0 ]] && \
            log "Found ${#targets[@]} unbound I2C-HID device(s): ${targets[*]}"
    fi

    # Bind whatever needs binding.
    local still_unbound=()
    for name in "${targets[@]}"; do
        bind_device "$name"
        if is_bound "$name"; then
            log "Bound $name to $DRIVER."
        else
            still_unbound+=("$name")
        fi
    done

    if [[ ${#still_unbound[@]} -gt 0 ]]; then
        log "Direct bind failed for: ${still_unbound[*]}"
        reload_modules
        mapfile -t after < <(find_unbound_hid_devices)
        if [[ ${#after[@]} -gt 0 ]]; then
            echo "Still unbound after reload: ${after[*]}" >&2
            echo "A full reboot may be required, or the I2C controller failed" >&2
            echo "to initialize. Inspect: sudo dmesg | grep -iE 'i2c|hid'" >&2
            rc=1
        fi
    fi

    # Always ensure the anti-freeze setting is applied, even when every device
    # was already bound (the freeze happens on a bound device).
    disable_runtime_pm

    if [[ $rc -ne 0 ]]; then
        log "Some device(s) could not be recovered."
        notify_user critical "Touchpad reset failed" "Could not rebind — try again or reboot."
    elif [[ $RESET -eq 1 ]]; then
        log "Done: touchpad(s) reset; runtime PM disabled (anti-freeze)."
        notify_user normal "Touchpad reset ✓" "Rebound ${#targets[@]} device(s); scrolling restored."
    elif [[ ${#targets[@]} -gt 0 ]]; then
        log "Done: touchpad(s) bound; runtime PM disabled (anti-freeze)."
        notify_user normal "Touchpad recovered ✓" "Rebound ${#targets[@]} device(s)."
    else
        # Nothing changed — stay quiet to avoid boot/watchdog notification noise.
        log "All I2C-HID devices already bound; runtime PM disabled (anti-freeze)."
    fi

    exit $rc
}

main
