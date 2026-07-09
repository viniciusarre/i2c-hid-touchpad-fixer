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
HID_IDS_REGEX='PNP0C50|MSFT0001'

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

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    echo "Installed and enabled $SERVICE_NAME (ExecStart=$FIXER)."
    echo "Running the fixer once now..."
    "$FIXER" || true
}

do_uninstall() {
    require_root --uninstall
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    echo "Removed $SERVICE_NAME."
}

do_run() {
    require_root --run
    "$FIXER"
}

do_status() {
    echo "=== service ==="
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "(not installed)"
    echo
    echo "=== I2C-HID device bind state ==="
    local found=0 dev modalias name
    for dev in /sys/bus/i2c/devices/i2c-*; do
        [[ -e "$dev/modalias" ]] || continue
        modalias="$(cat "$dev/modalias")"
        [[ "$modalias" =~ $HID_IDS_REGEX ]] || continue
        found=1
        name="$(basename "$dev")"
        if [[ -e "$dev/driver" ]]; then
            echo "  $name : BOUND"
        else
            echo "  $name : NOT BOUND"
        fi
    done
    [[ $found -eq 0 ]] && echo "  (no I2C-HID devices found)"
}

case "${1:---install}" in
    -i|--install)   do_install ;;
    -u|--uninstall) do_uninstall ;;
    -r|--run)       do_run ;;
    -s|--status)    do_status ;;
    -h|--help)      usage ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
esac
