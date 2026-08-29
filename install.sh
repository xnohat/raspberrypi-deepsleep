#!/bin/bash
# install.sh - Install Pi Deep Sleep power button handler
# Run with: sudo ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Pi Deep Sleep Installer ==="

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (sudo ./install.sh)"
    exit 1
fi

# Install acpid if not present
if ! command -v acpid &>/dev/null; then
    echo "Installing acpid..."
    apt-get update && apt-get install -y acpid
fi

# Install wireless-tools for iw command
if ! command -v iw &>/dev/null; then
    echo "Installing wireless-tools..."
    apt-get install -y iw
fi

# Disable desktop power key inhibitor (Raspberry Pi OS Desktop)
PWRKEY_DESKTOP="/etc/xdg/autostart/pwrkey.desktop"
if [ -f "$PWRKEY_DESKTOP" ]; then
    echo "Disabling desktop power key inhibitor..."
    mv "$PWRKEY_DESKTOP" "${PWRKEY_DESKTOP}.disabled"
    # Kill existing inhibitor process
    pkill -f "systemd-inhibit.*handle-power-key" 2>/dev/null || true
fi

# Configure systemd-logind to ignore power button (let acpid handle it)
LOGIND_CONF="/etc/systemd/logind.conf"
echo "Configuring systemd-logind to ignore power button..."
if grep -q "^HandlePowerKey=" "$LOGIND_CONF"; then
    # Replace existing setting
    sed -i 's/^HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
elif grep -q "^#HandlePowerKey=" "$LOGIND_CONF"; then
    # Uncomment and set to ignore
    sed -i 's/^#HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
else
    # Add setting if not present
    echo "HandlePowerKey=ignore" >> "$LOGIND_CONF"
fi
# Reload systemd-logind config without restarting (avoids session termination)
systemctl kill -s HUP systemd-logind

# Copy handler script
echo "Installing handler script..."
cp "$SCRIPT_DIR/powerbtn-deepsleep.sh" /usr/local/bin/
chmod +x /usr/local/bin/powerbtn-deepsleep.sh

# Backup existing power button handler if exists
if [ -f /etc/acpi/events/powerbtn ]; then
    echo "Backing up existing power button handler..."
    mv /etc/acpi/events/powerbtn /etc/acpi/events/powerbtn.bak
fi

# Install ACPI event config
echo "Installing ACPI event configuration..."
cp "$SCRIPT_DIR/powerbtn-custom" /etc/acpi/events/
chmod 644 /etc/acpi/events/powerbtn-custom

# Disable duplicate ACPI handler (acpi-support also matches button/power ->
# double-toggle race: two handlers fire per press)
if [ -f /etc/acpi/events/powerbtn-acpi-support ]; then
    echo "Disabling duplicate acpi-support power button handler..."
    mv /etc/acpi/events/powerbtn-acpi-support /etc/acpi/events/powerbtn-acpi-support.disabled
fi

# Neuter /usr/bin/pwrkey (desktop power button hook). acpid is the ONLY
# handler; if the desktop hook also ran the script we'd get double toggles,
# and running it as the session user triggers polkit auth popups that can
# hang the compositor (modal grab + our freeze pass).
PWRKEY_BIN="/usr/bin/pwrkey"
if [ -f "$PWRKEY_BIN" ]; then
    [ -f "${PWRKEY_BIN}.bak" ] || cp "$PWRKEY_BIN" "${PWRKEY_BIN}.bak"
    echo "Neutering desktop pwrkey handler (acpid is the only handler)..."
    cat > "$PWRKEY_BIN" << 'PWRKEY_EOF'
#!/bin/sh
# Power button handled EXCLUSIVELY by acpid -> /usr/local/bin/powerbtn-deepsleep.sh
# This desktop hook intentionally does nothing to avoid double-toggle races
# and polkit auth popups (which can hang the wayland session).
exit 0
PWRKEY_EOF
    chmod +x "$PWRKEY_BIN"
fi

# Create log file
touch /var/log/pi-deepsleep.log
chmod 644 /var/log/pi-deepsleep.log

# Enable and restart acpid
echo "Enabling acpid service..."
systemctl enable acpid
systemctl restart acpid

echo ""
echo "=== Installation Complete ==="
echo "Power button (key 116) now toggles deep sleep mode."
echo "Log file: /var/log/pi-deepsleep.log"
echo ""
echo "To uninstall, run: sudo ./uninstall.sh"
