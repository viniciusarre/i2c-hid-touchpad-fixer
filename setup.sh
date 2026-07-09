#!/usr/bin/env bash
#
# setup.sh — install / manage the I2C-HID touchpad fixer.
#
# Installs a systemd oneshot service that runs touchpad-fixer.sh on every boot,
# so a touchpad that fails to bind is recovered automatically. Every action is
# idempotent — running it twice does no harm.
#
# Usage:
#   sudo ./setup.sh --install     Install + enable the boot service (default)
#   sudo ./setup.sh --uninstall   Disable + remove the boot service
#   sudo ./setup.sh --run         Run the fixer once, now
#        ./setup.sh --status      Show service + touchpad bind state (no root)
#        ./setup.sh --help        This help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FIXER="$SCRIPT_DIR/touchpad-fixer.sh"

SERVICE_NAME="touchpad-fixer.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
RESUME_NAME="touchpad-fixer-resume.service"
RESUME_PATH="/etc/systemd/system/$RESUME_NAME"
UDEV_RULE_PATH="/etc/udev/rules.d/99-i2c-hid-touchpad-fixer.rules"
HID_IDS_REGEX='PNP0C50|MSFT0001'

# Print the sysfs name of every I2C-HID device on this machine.
list_hid_devices() {
    local dev
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        grep -qE "$HID_IDS_REGEX" "$dev/modalias" 2>/dev/null || continue
        basename "$dev"
    done
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This action needs root. Re-run with: sudo $0 $*" >&2
        exit 1
    fi
}

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

do_install() {
    require_root --install

    if [[ ! -f "$FIXER" ]]; then
        echo "Fixer script not found at $FIXER" >&2
        exit 1
    fi
    chmod +x "$FIXER"

    # Generate the unit fresh — idempotent, and always points at the current
    # script location (so the folder can be moved and re-installed).
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Rebind I2C-HID touchpad if it failed to bind at boot
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=$FIXER
RemainAfterExit=no
# Don't fail the boot if the touchpad genuinely can't be recovered.
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
EOF

    # Resume unit: force a rebind cycle after waking from suspend/hibernate,
    # where the touchpad can be stuck-but-still-bound. ExecStartPre gives the
    # I2C bus a moment to settle before we re-probe.
    cat > "$RESUME_PATH" <<EOF
[Unit]
Description=Reset I2C-HID touchpad after resume from suspend
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=$FIXER --reset
RemainAfterExit=no
SuccessExitStatus=0 1

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF

    # udev rule: persistently disable runtime autosuspend on the touchpad so
    # motion/scroll doesn't freeze. Applied whenever the device (re)appears,
    # independent of the services. Includes a generic driver match plus an
    # explicit entry per detected device for reliability.
    {
        echo "# Installed by i2c-hid-touchpad-fixer setup.sh"
        echo "# Disable runtime PM on I2C-HID touchpads to stop intermittent"
        echo "# cursor/scroll freezes (clicks keep working when motion stalls)."
        echo 'ACTION=="add|bind", SUBSYSTEM=="i2c", DRIVER=="i2c_hid_acpi", ATTR{power/control}="on"'
        local name
        while read -r name; do
            [[ -n "$name" ]] || continue
            echo "ACTION==\"add\", SUBSYSTEM==\"i2c\", KERNEL==\"$name\", ATTR{power/control}=\"on\""
        done < <(list_hid_devices)
    } > "$UDEV_RULE_PATH"
    udevadm control --reload-rules 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl enable "$RESUME_NAME"
    echo "Installed and enabled:"
    echo "  $SERVICE_NAME   (runs at boot)"
    echo "  $RESUME_NAME    (runs after resume from suspend)"
    echo "  $UDEV_RULE_PATH"
    echo "     (disables touchpad autosuspend — anti motion-freeze)"
    echo "ExecStart=$FIXER"
    echo "Running the fixer once now..."
    "$FIXER" || true
}

do_uninstall() {
    require_root --uninstall
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$RESUME_NAME" 2>/dev/null || true
    rm -f "$SERVICE_PATH" "$RESUME_PATH" "$UDEV_RULE_PATH"
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    echo "Removed $SERVICE_NAME, $RESUME_NAME and the udev rule."
}

do_run() {
    require_root --run
    "$FIXER"
}

do_status() {
    echo "=== services (enabled?) ==="
    local unit state
    for unit in "$SERVICE_NAME" "$RESUME_NAME"; do
        state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        [[ -z "$state" || "$state" == "not-found" ]] && state="not-installed"
        printf '  %-30s %s\n' "$unit" "$state"
    done
    echo
    echo "=== udev anti-freeze rule ==="
    if [[ -e "$UDEV_RULE_PATH" ]]; then
        echo "  installed: $UDEV_RULE_PATH"
    else
        echo "  not installed"
    fi
    echo
    echo "=== I2C-HID device state (bind + runtime PM) ==="
    local found=0 dev modalias name bind pm
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        modalias="$(cat "$dev/modalias")"
        [[ "$modalias" =~ $HID_IDS_REGEX ]] || continue
        found=1
        name="$(basename "$dev")"
        [[ -e "$dev/driver" ]] && bind="BOUND" || bind="NOT BOUND"
        pm="$(cat "$dev/power/control" 2>/dev/null || echo '?')"
        # power/control: "on" = autosuspend disabled (good, anti-freeze)
        printf '  %-20s bind=%-10s power/control=%s\n' "$name" "$bind" "$pm"
    done
    [[ $found -eq 0 ]] && echo "  (no I2C-HID devices found)"
    return 0
}

case "${1:---install}" in
    -i|--install)   do_install ;;
    -u|--uninstall) do_uninstall ;;
    -r|--run)       do_run ;;
    -s|--status)    do_status ;;
    -h|--help)      usage ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
esac
