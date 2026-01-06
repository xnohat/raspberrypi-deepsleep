#!/bin/bash
# uninstall.sh - Remove Pi Deep Sleep power button handler
# Run with: sudo ./uninstall.sh

set -e

echo "=== Pi Deep Sleep Uninstaller ==="

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (sudo ./uninstall.sh)"
    exit 1
fi

# Remove handler script
echo "Removing handler script..."
rm -f /usr/local/bin/powerbtn-deepsleep.sh

# Remove ACPI event config
echo "Removing ACPI event configuration..."
rm -f /etc/acpi/events/powerbtn-custom

# Restore original power button handler if backup exists
if [ -f /etc/acpi/events/powerbtn.bak ]; then
    echo "Restoring original power button handler..."
    mv /etc/acpi/events/powerbtn.bak /etc/acpi/events/powerbtn
fi

# Clear state file
rm -f /tmp/pi-deepsleep-state

# Restore original /usr/bin/pwrkey if we backed it up
PWRKEY_BIN="/usr/bin/pwrkey"
if [ -f "${PWRKEY_BIN}.bak" ]; then
    echo "Restoring original desktop pwrkey handler..."
    mv "${PWRKEY_BIN}.bak" "$PWRKEY_BIN"
fi

# Restore desktop power key inhibitor if we disabled it
PWRKEY_DESKTOP="/etc/xdg/autostart/pwrkey.desktop"
if [ -f "${PWRKEY_DESKTOP}.disabled" ]; then
    echo "Restoring desktop power key inhibitor..."
    mv "${PWRKEY_DESKTOP}.disabled" "$PWRKEY_DESKTOP"
fi

# Restore systemd-logind power button handling
LOGIND_CONF="/etc/systemd/logind.conf"
echo "Restoring systemd-logind power button handling..."
if grep -q "^HandlePowerKey=ignore" "$LOGIND_CONF"; then
    # Restore to default poweroff behavior
    sed -i 's/^HandlePowerKey=ignore/HandlePowerKey=poweroff/' "$LOGIND_CONF"
fi
# Restart systemd-logind to apply changes
systemctl restart systemd-logind

# Restart acpid
systemctl restart acpid

echo ""
echo "=== Uninstallation Complete ==="
echo "Power button restored to default behavior."
