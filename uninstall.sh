#!/bin/bash
# uninstall.sh — remove Pi Deep Sleep + Fastboot + PiTerm (restores stock behavior)
# Run with: sudo ./uninstall.sh

TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [ "$EUID" -ne 0 ]; then
    echo "Error: run as root (sudo ./uninstall.sh)"
    exit 1
fi

echo "=== Uninstalling Pi Deep Sleep + Fastboot + PiTerm ==="

# power button daemon
systemctl disable --now powerbtn-daemon.service 2>/dev/null
rm -f /etc/systemd/system/powerbtn-daemon.service
systemctl daemon-reload

# scripts
rm -f /usr/local/bin/powerbtn-deepsleep.sh /usr/local/bin/fastboot-save.sh \
      /usr/local/bin/fastboot-restore.sh /usr/local/bin/tmux-state.py \
      /usr/local/bin/powerbtn-daemon.py /usr/local/bin/fastboot \
      /usr/local/bin/battery-logger.sh

# sudoers
rm -f /etc/sudoers.d/pi-deepsleep /etc/sudoers.d/pi-fastboot

# restore legacy handlers
for f in /etc/acpi/events/powerbtn-custom /etc/acpi/events/powerbtn-acpi-support /etc/acpi/events/powerbtn; do
    [ -f "$f.disabled" ] && mv "$f.disabled" "$f"
done
systemctl restart acpid 2>/dev/null
[ -f /usr/bin/pwrkey.bak ] && mv /usr/bin/pwrkey.bak /usr/bin/pwrkey
[ -f /etc/xdg/autostart/pwrkey.desktop.disabled ] && mv /etc/xdg/autostart/pwrkey.desktop.disabled /etc/xdg/autostart/pwrkey.desktop
sed -i 's/^HandlePowerKey=ignore/#HandlePowerKey=poweroff/' /etc/systemd/logind.conf
systemctl kill -s HUP systemd-logind 2>/dev/null

# piterm (leave foot/tmux packages installed; remove configs)
rm -f "$TARGET_HOME/.local/share/applications/piterm.desktop" \
      "$TARGET_HOME/.local/bin/piterm-attach" \
      "$TARGET_HOME/.tmux-status.sh"
# .tmux.conf and foot.ini left in place (may contain user edits) — remove manually if desired

# labwc hooks
sed -i '/fastboot-restore/d' "$TARGET_HOME/.config/labwc/autostart" 2>/dev/null

# state
rm -rf "$TARGET_HOME/.fastboot-state" "$TARGET_HOME/.fastboot-state.previous" "$TARGET_HOME/.fastboot-state.new"

echo "=== Done. Reboot recommended. ==="
echo "(foot/tmux packages and ~/.tmux.conf, foot.ini kept — remove manually if unwanted)"
